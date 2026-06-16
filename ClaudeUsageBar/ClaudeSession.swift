//
//  ClaudeSession.swift
//  ClaudeUsageBar
//
//  ⚠️  THE QUARANTINE FILE  ⚠️
//  This is the ONLY file that may know about URLs, request paths, JSON keys,
//  or cookie names (brief §3, invariant 1). Everything claude.ai-specific and
//  fragile lives here. The rest of the app consumes typed `Usage` values only.
//
//  Strategy:
//    • Login happens in a WKWebView using the shared, persistent default
//      WKWebsiteDataStore (see LoginView.swift).
//    • Fetching happens inside a hidden WKWebView loaded on the claude.ai
//      origin, by running `fetch()` in the page's own JS context via
//      callAsyncJavaScript. The request therefore carries exactly the cookies,
//      origin, and credentials the real web app uses — no header guessing,
//      no httpOnly-cookie copying, no CORS.
//
//  ENDPOINT (verified 2026-06-16 via DevTools/Chrome — see ENDPOINT_NOTES.md):
//    GET /api/organizations/{org}/usage  →
//      {
//        "five_hour":  { "utilization": <0-100>, "resets_at": <ISO-8601 | null> },  // session window
//        "seven_day":  { "utilization": <0-100>, "resets_at": <ISO-8601 | null> },  // weekly window
//        "seven_day_opus":   { "utilization": .., "resets_at": .. } | null,         // per-model (weekly)
//        "seven_day_sonnet": { ... } | null,
//        "extra_usage": { "utilization": <0-100>, "used_credits": .., ... },        // pay-as-you-go credits
//        ... (other internal buckets, mostly null)
//      }
//    Note: `utilization` is on a 0–100 scale (e.g. 3 == 3%); timestamps carry
//    MICROSECOND fractional precision + a numeric offset, which trips up
//    ISO8601DateFormatter — parseDate handles that explicitly.
//    Org UUID is discovered from GET /api/organizations (array; top-level uuid).
//

import Foundation
import WebKit

/// Typed failures so the caller can distinguish "log back in" from "broke".
enum SessionError: Error {
    case needsLogin
    case noData
    case network(String)
}

@MainActor
final class ClaudeSession: NSObject {

    // MARK: - Quarantined constants (the only place these may appear)

    private let origin = "https://claude.ai"

    /// Authoritative source of the organization UUID: an array of orgs, each
    /// with a top-level `uuid`. (`/api/bootstrap`'s `account.uuid` is the
    /// *account* id, not the org — don't use it.)
    private let orgListPath = "/api/organizations"
    /// Fallback only: scrape any uuid (usage simply 404s for wrong ids).
    private let bootstrapPath = "/api/bootstrap"

    /// Verified usage endpoint. `{org}` is substituted with each discovered UUID.
    private let usageCandidates = [
        "/api/organizations/{org}/usage",
    ]

    /// Known per-model weekly buckets we surface, mapped to display names.
    /// (Other internal buckets like cowork/omelette/tangelo are intentionally
    /// ignored.)
    private let perModelKeys: [(key: String, label: String)] = [
        ("seven_day_opus", "Opus"),
        ("seven_day_sonnet", "Sonnet"),
    ]

    // Hints for the defensive fallback path only (if the known shape changes).
    private let percentKeyHints = ["utilization", "percent", "pct", "usage_ratio", "ratio"]
    private let resetKeyHints   = ["resets_at", "reset_at", "reset", "window_end", "expires"]

    // MARK: - WebView plumbing

    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Lazily build a hidden WKWebView bound to the shared persistent cookie jar.
    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        // CRITICAL: same data store as the login view so cookies are shared.
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        wv.navigationDelegate = self
        return wv
    }

    // MARK: - Public API (typed; no leakage)

    /// Cheap, bounded launch-time check: do we have *any* persistent cookie for
    /// claude.ai? This only decides the optimistic initial state; the real
    /// authority on "logged in" is whether `fetchUsage()` gets data vs a login
    /// redirect (brief §3, invariant 4: this is the only bounded wait, 2s cap).
    func hasSession() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let store = WKWebsiteDataStore.default().httpCookieStore
            var resumed = false
            // Both callbacks run on the main thread, so `resumed` needs no lock.
            store.getAllCookies { cookies in
                guard !resumed else { return }
                resumed = true
                let present = cookies.contains { cookie in
                    cookie.domain.contains("claude.ai") && !cookie.isSessionOnly
                }
                cont.resume(returning: present)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: false)
            }
        }
    }

    /// Fetch + parse current usage. Throws `SessionError.needsLogin` if the
    /// endpoints bounce us to login, `.noData` if nothing parseable came back.
    func fetchUsage() async throws -> Usage {
        try await ensureLoaded()

        let orgIDs = await discoverOrgIDs()
        guard !orgIDs.isEmpty else {
            // Couldn't even discover the org — most likely not logged in.
            if await sawLogin(at: orgListPath) { throw SessionError.needsLogin }
            throw SessionError.noData
        }

        var sawLoginRedirect = false
        for template in usageCandidates {
            for org in orgIDs {
                let path = template.replacingOccurrences(of: "{org}", with: org)
                let result = await runFetch(path)
                switch result.kind {
                case .login:
                    sawLoginRedirect = true
                case .json(let json):
                    if let usage = parseUsage(json) { return usage }
                case .miss:
                    break
                }
            }
        }

        if sawLoginRedirect { throw SessionError.needsLogin }
        throw SessionError.noData
    }

    /// Wipe the shared session (Phase 4 sign-out). Cheap to provide now.
    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {
                cont.resume()
            }
        }
    }

    // MARK: - WebView load / fetch internals

    private func ensureLoaded() async throws {
        if webView == nil {
            webView = makeWebView()
        }
        guard let webView else { throw SessionError.network("no web view") }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            var request = URLRequest(url: URL(string: origin + "/")!)
            request.timeoutInterval = 15
            webView.load(request)
            // Safety timeout so a hung navigation can't wedge the app.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, let c = self.loadContinuation else { return }
                self.loadContinuation = nil
                c.resume()                       // proceed; the fetch step will surface real failures
            }
        }
    }

    private enum FetchKind {
        case json(Any)
        case login
        case miss
    }
    private struct FetchResult { let kind: FetchKind }

    /// Run a same-origin `fetch()` in the page context and classify the result.
    private func runFetch(_ path: String) async -> FetchResult {
        guard let webView else { return FetchResult(kind: .miss) }

        let js = """
        const res = await fetch(path, { credentials: 'include', headers: { 'accept': 'application/json' } });
        const body = await res.text();
        return { ok: res.ok, status: res.status, url: res.url, redirected: res.redirected, body: body };
        """

        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(
                js,
                arguments: ["path": path],
                contentWorld: .page
            )
        } catch {
            return FetchResult(kind: .miss)
        }

        guard let dict = raw as? [String: Any] else { return FetchResult(kind: .miss) }
        let status = (dict["status"] as? Int) ?? -1
        let url = (dict["url"] as? String) ?? ""
        let body = (dict["body"] as? String) ?? ""

        if status == 401 || status == 403 || url.contains("/login") {
            return FetchResult(kind: .login)
        }
        guard status >= 200, status < 300, !body.isEmpty else {
            return FetchResult(kind: .miss)
        }
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return FetchResult(kind: .miss)   // login pages return 200 HTML, not JSON
        }
        return FetchResult(kind: .json(json))
    }

    /// True if hitting `path` bounced us to login / returned unauthorized.
    private func sawLogin(at path: String) async -> Bool {
        if case .login = await runFetch(path).kind { return true }
        return false
    }

    /// Discover organization UUID(s). Primary source: `/api/organizations`
    /// (array of orgs, each with a top-level `uuid`). The first org whose
    /// `/usage` parses wins back in `fetchUsage`.
    private func discoverOrgIDs() async -> [String] {
        if case .json(let json) = await runFetch(orgListPath).kind,
           let array = json as? [[String: Any]] {
            let ids = array.compactMap { $0["uuid"] as? String }.filter(looksLikeUUID)
            if !ids.isEmpty { return dedupe(ids) }
        }
        // Fallback: scrape any uuid from bootstrap (wrong ids just 404 on usage).
        if case .json(let json) = await runFetch(bootstrapPath).kind {
            let ids = collectValues(forKeyMatching: { $0 == "uuid" }, in: json)
                .compactMap { $0 as? String }.filter(looksLikeUUID)
            if !ids.isEmpty { return dedupe(ids) }
        }
        return []
    }

    // MARK: - Parsing (brief §3, invariant 3: defensive, optional, never throws)

    /// A `{ utilization, resets_at }` window.
    private struct Window { let percent: Int; let reset: Date? }

    /// Extract a `Usage` from the usage payload. Parses the known shape exactly
    /// (so we never grab the wrong window out of an unordered dict), and falls
    /// back to a loose scrape if the shape has changed.
    func parseUsage(_ json: Any) -> Usage? {
        guard let root = json as? [String: Any] else { return parseUsageLoose(json) }

        guard let session = window(from: root["five_hour"]) else {
            return parseUsageLoose(json)   // known key gone — degrade, don't fail
        }
        let weekly = window(from: root["seven_day"])

        var models: [ModelUsage] = []
        for entry in perModelKeys {
            if let w = window(from: root[entry.key]) {
                models.append(ModelUsage(modelName: entry.label, percent: w.percent))
            }
        }

        return Usage(
            sessionPercent: session.percent,
            sessionReset: session.reset,
            weeklyPercent: weekly?.percent,
            weeklyReset: weekly?.reset,
            perModel: models.isEmpty ? nil : models,
            capturedAt: Date()
        )
    }

    /// Parse a `{ utilization, resets_at }` node (nil if absent/null/malformed).
    private func window(from node: Any?) -> Window? {
        guard let dict = node as? [String: Any] else { return nil }
        guard let pct = clampPercent(dict["utilization"]) else { return nil }
        return Window(percent: pct, reset: parseDate(dict["resets_at"] as Any))
    }

    /// Clamp/round a value KNOWN to be on a 0–100 scale. No fraction scaling
    /// here (utilization of 0.5 means 0.5%, not 50%).
    private func clampPercent(_ value: Any?) -> Int? {
        guard let d = asDouble(value), d.isFinite, d >= 0 else { return nil }
        return Int(min(100.0, d.rounded()))
    }

    // MARK: Defensive fallback (only if the documented shape changes)

    /// Best-effort recovery: first object anywhere that has a percent-ish value.
    /// Uses the 0–1→0–100 heuristic since the scale is unknown in this path.
    private func parseUsageLoose(_ json: Any) -> Usage? {
        let percents = collectValues(forKeyMatching: { key in
            percentKeyHints.contains { key.contains($0) }
        }, in: json).compactMap(normalizePercentLoose)
        guard let sessionPercent = percents.first else { return nil }

        let reset = collectValues(forKeyMatching: { key in
            resetKeyHints.contains { key.contains($0) }
        }, in: json).compactMap { parseDate($0) }.first

        return Usage(sessionPercent: sessionPercent, sessionReset: reset, capturedAt: Date())
    }

    private func normalizePercentLoose(_ value: Any) -> Int? {
        guard let d = asDouble(value), d.isFinite, d >= 0 else { return nil }
        let scaled = d <= 1.0 ? d * 100.0 : d     // unknown scale: treat ≤1 as a fraction
        return Int(min(100.0, scaled.rounded()))
    }

    // MARK: - Value helpers

    private func asDouble(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Parse ISO-8601 (incl. microsecond fractions + numeric offsets) or epoch.
    private func parseDate(_ value: Any) -> Date? {
        if let s = value as? String, !s.isEmpty {
            if let d = Self.iso.date(from: s) { return d }
            if let d = Self.isoNoFrac.date(from: s) { return d }
            // ISO8601DateFormatter only handles millisecond fractions; claude.ai
            // sends microseconds (e.g. ".853052"). Strip the fraction and retry.
            let stripped = s.replacingOccurrences(of: #"\.\d+"#, with: "",
                                                  options: .regularExpression)
            if let d = Self.isoNoFrac.date(from: stripped) { return d }
            if let n = Double(s) { return dateFromEpoch(n) }
            return nil
        }
        if let n = asDouble(value) { return dateFromEpoch(n) }
        return nil
    }

    private func dateFromEpoch(_ n: Double) -> Date? {
        guard n > 0 else { return nil }
        let seconds = n > 1_000_000_000_000 ? n / 1000.0 : n   // >10^12 ⇒ milliseconds
        return Date(timeIntervalSince1970: seconds)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func looksLikeUUID(_ s: String) -> Bool {
        s.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                options: .regularExpression) != nil
    }

    private func dedupe(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Recursively collect all values whose key matches `predicate`.
    private func collectValues(forKeyMatching predicate: (String) -> Bool, in json: Any) -> [Any] {
        var out: [Any] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (k, v) in dict {
                    if predicate(k.lowercased()) { out.append(v) }
                    walk(v)
                }
            } else if let arr = node as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(json)
        return out
    }
}

// MARK: - WKNavigationDelegate

extension ClaudeSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume()      // proceed; runFetch will report the real outcome
        loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume()
        loadContinuation = nil
    }
}
