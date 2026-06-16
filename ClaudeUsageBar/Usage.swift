//
//  Usage.swift
//  ClaudeUsageBar
//
//  The model layer. Plain, typed Swift values + an observable store.
//  This file knows NOTHING about URLs, JSON keys, or cookies — that all
//  lives in ClaudeSession.swift (see CLAUDE_CODE_BRIEF.md §3, invariant 1).
//
//  State flows one way:  ClaudeSession → UsageStore.state (enum) → UI.
//

import Foundation
import Combine
import ServiceManagement

/// One model's slice of usage (e.g. Opus vs Sonnet). Phase 2 / optional.
struct ModelUsage: Identifiable, Equatable {
    /// Stable identity so SwiftUI lists diff cleanly and Equatable is meaningful.
    var id: String { modelName }
    let modelName: String
    /// 0…100, already normalized by ClaudeSession.
    let percent: Int
}

/// Pay-as-you-go "extra usage" credit pool (optional). Amounts are already in
/// currency units (e.g. dollars), converted from the endpoint's minor units by
/// ClaudeSession — the UI just formats them.
struct CreditUsage: Equatable {
    let used: Double
    let limit: Double
    let currency: String   // ISO code, e.g. "USD"
}

/// A single usage sample. Required fields describe the active *session* window;
/// every "extended" field is optional so the UI can hide rows it has no data for
/// (brief §3, invariant 5: graceful degradation).
struct Usage: Equatable {
    /// Session window utilization, 0…100.
    var sessionPercent: Int
    /// When the session window resets, if the endpoint exposes it.
    var sessionReset: Date?

    // --- Extended, optional (Phase 2). Parsing fills only what it finds. ---
    var weeklyPercent: Int?
    var weeklyReset: Date?
    var perModel: [ModelUsage]?
    var credits: CreditUsage?

    /// When this sample was captured locally (for the "last updated" stamp).
    var capturedAt: Date

    init(sessionPercent: Int,
         sessionReset: Date? = nil,
         weeklyPercent: Int? = nil,
         weeklyReset: Date? = nil,
         perModel: [ModelUsage]? = nil,
         credits: CreditUsage? = nil,
         capturedAt: Date = Date()) {
        self.sessionPercent = sessionPercent
        self.sessionReset = sessionReset
        self.weeklyPercent = weeklyPercent
        self.weeklyReset = weeklyReset
        self.perModel = perModel
        self.credits = credits
        self.capturedAt = capturedAt
    }
}

/// Failure is a state, not a crash (brief §3, invariant 6). Everything the UI
/// can be in is one of these cases.
enum UsageState: Equatable {
    case loading
    case needsLogin
    case loaded(Usage)
    case error(String)
}

/// The single source of truth the UI observes. `AppDelegate` pushes new states
/// in; views read `state`. Views never touch the network.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState = .needsLogin

    /// In-memory ring buffer of recent samples (Phase 2 sparkline). Not persisted.
    @Published private(set) var history: [Usage] = []
    private let historyCap = 60

    func setState(_ newState: UsageState) {
        state = newState
        if case .loaded(let usage) = newState {
            history.append(usage)
            if history.count > historyCap {
                history.removeFirst(history.count - historyCap)
            }
        }
    }

    /// Convenience accessor for the most recent successful sample.
    var latest: Usage? {
        if case .loaded(let usage) = state { return usage }
        return history.last
    }
}

/// How the menu-bar status item renders the current session usage.
enum MenuBarMode: String, CaseIterable, Identifiable {
    /// Gauge icon only, no text.
    case iconOnly
    /// Gauge icon + "14%".
    case iconPercent
    /// "14%/3h29m" text, no icon.
    case percentTime

    var id: String { rawValue }
    var label: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .iconPercent: return "Icon + %"
        case .percentTime: return "% / time left"
        }
    }
}

/// Small persisted user settings (UserDefaults). Grown in Phase 4.
@MainActor
final class AppSettings: ObservableObject {
    @Published var menuBarMode: MenuBarMode {
        didSet {
            UserDefaults.standard.set(menuBarMode.rawValue, forKey: Keys.menuBarMode)
            onChange?()
        }
    }

    /// Network refresh cadence, in minutes (see `refreshChoices`).
    @Published var refreshIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(refreshIntervalMinutes, forKey: Keys.refreshIntervalMinutes)
            onChange?()
        }
    }

    /// Session % at/over which the bar + popover tint to a warning color.
    @Published var warnThreshold: Int {
        didSet {
            UserDefaults.standard.set(warnThreshold, forKey: Keys.warnThreshold)
            onChange?()
        }
    }

    /// Mirrors SMAppService registration (which is the real source of truth).
    @Published var launchAtLogin: Bool {
        didSet {
            LaunchAtLogin.set(launchAtLogin)
            onChange?()
        }
    }

    /// Refresh cadences (minutes) offered by the settings UI.
    static let refreshChoices = [1, 5, 15, 30]

    /// Fired after a setting changes (e.g. so AppDelegate can re-render the bar /
    /// restart the timer). Not called during init (didSet skips initial assignment).
    var onChange: (() -> Void)?

    private enum Keys {
        static let menuBarMode = "menuBarMode"
        static let refreshIntervalMinutes = "refreshIntervalMinutes"
        static let warnThreshold = "warnThreshold"
    }

    init() {
        let defaults = UserDefaults.standard

        let rawMode = defaults.string(forKey: Keys.menuBarMode)
        menuBarMode = rawMode.flatMap(MenuBarMode.init(rawValue:)) ?? .iconPercent

        let storedInterval = defaults.integer(forKey: Keys.refreshIntervalMinutes)   // 0 when unset
        refreshIntervalMinutes = Self.refreshChoices.contains(storedInterval) ? storedInterval : 5

        let storedThreshold = defaults.integer(forKey: Keys.warnThreshold)            // 0 when unset
        warnThreshold = (50...95).contains(storedThreshold) ? storedThreshold : 80

        // Launch-at-login's source of truth is SMAppService, not UserDefaults.
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}

/// Thin wrapper over SMAppService for "launch at login" (macOS 13+).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin toggle failed: \(error.localizedDescription)")
        }
    }
}
