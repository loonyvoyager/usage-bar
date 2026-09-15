//
//  AppDelegate.swift
//  UsageBar
//
//  The orchestrator. Owns the NSStatusItem, the dropdown panel, the login
//  window, and the refresh timer. It is the ONLY place that wires the network
//  (UsageSession) to the observable store (UsageStore) and down to the UI via
//  closures. UI never calls the network directly (brief §3, invariant 2).
//
//  The dropdown is a borderless panel (not an NSPopover) so it has no arrow and
//  is pinned under the status item's right edge. That decouples it from the
//  status item's width, which is therefore free to be minimal (variable length)
//  without the dropdown shifting when the display mode or value changes.
//
//  Sizing note: the panel is sized MANUALLY (to the hosting view's fittingSize)
//  on discrete state/settings changes — NOT via NSHostingController's
//  preferredContentSize auto-sizing, which feeds back into a window resize loop
//  (synchronous recursion → stack overflow).
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = UsageStore()
    private let session = UsageSession()

    private let settings = AppSettings()

    private var statusItem: NSStatusItem!
    private var panel: KeyPanel!
    private var contentView: NSView!            // the NSHostingView; read its fittingSize
    private var loginWindow: NSWindow?
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var clickMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?

    /// Refresh coalescing: UsageSession's web-view load must not run re-entrantly
    /// (its single load continuation would be clobbered), so overlapping refresh
    /// requests (timer + manual + post-login) queue at most one follow-up.
    private var isRefreshing = false
    private var refreshQueued = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent by default (LSUIElement); "Show in Dock" flips the
        // activation policy at runtime, no relaunch needed.
        applyDockPresence()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.updateDockIcon() }   // repaint the ring for light/dark
        }

        setupStatusItem()
        setupPanel()
        settings.onChange = { [weak self] in self?.applySettings() }
        startRefreshTimer()
        startDisplayTimer()

        // Bounded launch-time session check (the only allowed blocking-ish wait).
        store.setState(.loading)
        updateButton()
        Task {
            if await session.hasSession() {
                refresh()
            } else {
                store.setState(.needsLogin)
                updateButton()
            }
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        // Variable length: the item hugs its content (minimal menu-bar footprint).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.medium",
                                   accessibilityDescription: "claude.ai usage")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    // MARK: - Dropdown panel

    private func setupPanel() {
        let root = UsagePopoverView(
            store: store,
            settings: settings,
            onRefresh: { [weak self] in self?.refresh() },
            onLogin:   { [weak self] in self?.showLogin() },
            onSignOut: { [weak self] in self?.signOut() },
            onQuit:    { [weak self] in self?.quit() }
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        let hostingView = NSHostingView(rootView: root)
        contentView = hostingView

        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        self.panel = panel

        // Re-fit the panel when the content's height can change (state transitions,
        // settings panel expand/collapse). Deferred to the next main-actor tick so
        // SwiftUI has applied the change before we measure fittingSize.
        store.$state
            .sink { [weak self] _ in Task { @MainActor in self?.resizePanelIfVisible() } }
            .store(in: &cancellables)
        settings.$settingsExpanded
            .sink { [weak self] _ in Task { @MainActor in self?.resizePanelIfVisible() } }
            .store(in: &cancellables)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        installClickMonitors()
    }

    private func hidePanel() {
        removeClickMonitors()
        settings.settingsExpanded = false   // always reopen collapsed
        panel.orderOut(nil)
    }

    private func resizePanelIfVisible() {
        guard panel.isVisible else { return }
        positionPanel()
    }

    /// Size the panel to its content and pin its top-right corner just below the
    /// status item's right edge. Clamped to the screen's visible frame.
    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let fitting = contentView.fittingSize
        let size = (fitting.width > 1 && fitting.height > 1) ? fitting : panel.frame.size
        guard size.width > 1, size.height > 1 else { return }

        let onScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let gap: CGFloat = 6
        var x = onScreen.maxX - size.width                 // right-align to the item's right edge
        let y = onScreen.minY - gap - size.height          // hang just below the menu bar

        if let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: - Click-outside dismissal

    private func installClickMonitors() {
        removeClickMonitors()
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Status-item clicks are handled by the button action (toggle); clicks
            // inside the panel pass through; anything else dismisses.
            if event.window == self.statusItem.button?.window { return event }
            if event.window != self.panel { self.hidePanel() }
            return event
        }
        clickMonitors = [global, local].compactMap { $0 }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach { NSEvent.removeMonitor($0) }
        clickMonitors.removeAll()
    }

    // MARK: - Refresh

    @objc private func timerFired() { refresh() }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let interval = TimeInterval(max(1, settings.refreshIntervalMinutes) * 60)
        let timer = Timer(timeInterval: interval,
                          target: self,
                          selector: #selector(timerFired),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = interval * 0.1        // let the system coalesce wakeups
        RunLoop.main.add(timer, forMode: .common)  // keep firing during event tracking
        refreshTimer = timer
    }

    /// React to a settings change: pick up a new interval and re-render the bar.
    /// The timer is only restarted when the cadence actually changed, so unrelated
    /// tweaks (display mode, threshold) don't postpone the next scheduled fetch.
    private func applySettings() {
        let interval = TimeInterval(max(1, settings.refreshIntervalMinutes) * 60)
        if refreshTimer?.timeInterval != interval {
            startRefreshTimer()
        }
        applyDockPresence()
        updateButton()
    }

    /// Re-render the menu-bar label every minute so the "% / time left" mode's
    /// countdown stays current between (5-min) network refreshes. No network.
    @objc private func displayTick() { updateButton() }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        let timer = Timer(timeInterval: 60,
                          target: self,
                          selector: #selector(displayTick),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func refresh() {
        // Coalesce overlapping refreshes; see isRefreshing/refreshQueued above.
        guard !isRefreshing else {
            refreshQueued = true
            return
        }
        isRefreshing = true

        // Don't flash a spinner over good data on periodic refreshes.
        if store.latest == nil {
            store.setState(.loading)
            updateButton()
        }
        Task {
            defer {
                isRefreshing = false
                if refreshQueued {
                    refreshQueued = false
                    refresh()
                }
            }
            do {
                let usage = try await session.fetchUsage()
                store.setState(.loaded(usage))
            } catch SessionError.needsLogin {
                store.setState(.needsLogin)
            } catch {
                store.setState(.error(message(for: error)))
            }
            updateButton()
        }
    }

    private func message(for error: Error) -> String {
        switch error {
        case SessionError.noData:
            return "Signed in, but couldn't read a usage value from claude.ai. "
                 + "Its internal usage endpoint may have changed."
        case SessionError.network(let detail):
            return detail
        default:
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - Login

    private func showLogin() {
        if panel.isVisible { hidePanel() }

        if let existing = loginWindow {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let view = LoginView(onAuthenticated: { [weak self] in
            self?.finishLogin()
        })
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Sign in to claude.ai"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 460, height: 660))
        window.isReleasedWhenClosed = false
        window.center()
        loginWindow = window

        NSApp.activate(ignoringOtherApps: true)   // accessory app must activate to accept typing
        window.makeKeyAndOrderFront(nil)
    }

    private func finishLogin() {
        loginWindow?.close()
        loginWindow = nil
        store.setState(.loading)
        updateButton()
        refresh()
    }

    // MARK: - Sign out

    private func signOut() {
        if panel.isVisible { hidePanel() }
        Task {
            await session.clearSession()
            store.setState(.needsLogin)
            updateButton()
        }
    }

    // MARK: - Quit

    private func quit() { NSApp.terminate(nil) }

    // MARK: - Menu bar button rendering

    private func updateButton() {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil               // reset; renderLoaded re-applies if over threshold
        switch store.state {
        case .loaded(let usage):
            renderLoaded(button, usage)
        case .loading:
            button.imagePosition = .imageOnly
            button.title = ""
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Loading")
        case .needsLogin:
            button.imagePosition = .imageOnly
            button.title = ""
            button.image = NSImage(systemSymbolName: "person.crop.circle.badge.questionmark",
                                   accessibilityDescription: "Sign in")
        case .error:
            button.imagePosition = .imageOnly
            button.title = ""
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                   accessibilityDescription: "Error")
        }
        updateDockIcon()
    }

    /// Render the loaded state per the user's chosen menu-bar mode.
    private func renderLoaded(_ button: NSStatusBarButton, _ usage: Usage) {
        button.contentTintColor = usage.sessionPercent >= settings.warnThreshold ? .systemOrange : nil
        switch settings.menuBarMode {
        case .meters:
            button.image = meterImage(for: usage)
            button.imagePosition = .imageOnly
            button.title = ""
        case .percentTime:
            button.image = nil
            button.imagePosition = .noImage
            if let left = timeLeft(usage.sessionReset) {
                button.title = "\(usage.sessionPercent)%/\(left)"
            } else {
                button.title = "\(usage.sessionPercent)%"
            }
        }
    }

    /// Compact "time until session reset", e.g. "3h29m", "29m", "1d3h".
    private func timeLeft(_ reset: Date?) -> String? {
        guard let reset, reset > Date() else { return nil }
        let total = Int(reset.timeIntervalSinceNow)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }

    // MARK: - Dock

    /// Show or hide the app in the Dock per settings. Changing the activation
    /// policy at runtime overrides the bundle's LSUIElement default, so no
    /// relaunch is needed; the menu-bar item stays either way.
    private func applyDockPresence() {
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Paint the Dock icon as a live usage ring (only while shown in the Dock);
    /// fall back to the bundle's static icon whenever there's no usage to show.
    private func updateDockIcon() {
        guard settings.showInDock else { return }
        if case .loaded(let usage) = store.state {
            NSApp.applicationIconImage = dockIcon(for: usage)
        } else {
            NSApp.applicationIconImage = nil
        }
    }

    /// A click on the Dock icon opens the dropdown — the app has no windows of
    /// its own to bring forward (except the login window, which AppKit raises).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }
        togglePanel()
        return false
    }

    /// The Dock icon: a ring showing session usage with the number inside, on a
    /// transparent background — the Dock supplies the tile, which keeps it as
    /// compact as it gets. Colors resolve against the current appearance and the
    /// icon is repainted on light/dark changes, so the number always reads.
    private func dockIcon(for usage: Usage) -> NSImage {
        let percent = min(100, max(0, usage.sessionPercent))
        let ringColor: NSColor = percent >= settings.warnThreshold ? .systemOrange : .systemBlue
        let appearance = NSApp.effectiveAppearance
        let side: CGFloat = 256
        let center = NSPoint(x: side / 2, y: side / 2)
        let stroke = side * 0.105
        let radius = side / 2 - stroke / 2 - side * 0.05

        // "71" over a small "%". Lay out on the *visible* glyph block (cap
        // heights), not the line boxes, so the pair sits optically centered.
        let numberFont = Self.roundedFont(size: side * 0.30, weight: .bold)
        let unitFont = Self.roundedFont(size: side * 0.12, weight: .semibold)
        let number = NSAttributedString(string: "\(percent)", attributes: [
            .font: numberFont, .foregroundColor: NSColor.labelColor])
        let unit = NSAttributedString(string: "%", attributes: [
            .font: unitFont, .foregroundColor: NSColor.secondaryLabelColor])
        let gap = side * 0.03
        let blockTop = center.y + (numberFont.capHeight + gap + unitFont.capHeight) / 2
        let numberBaseline = blockTop - numberFont.capHeight
        let unitBaseline = numberBaseline - gap - unitFont.capHeight
        let numberOrigin = NSPoint(x: center.x - number.size().width / 2,
                                   y: numberBaseline + numberFont.descender)
        let unitOrigin = NSPoint(x: center.x - unit.size().width / 2,
                                 y: unitBaseline + unitFont.descender)

        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                // Track, then the progress arc sweeping clockwise from 12 o'clock.
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = stroke
                NSColor.quaternaryLabelColor.setStroke()
                track.stroke()

                if percent > 0 {
                    let arc = NSBezierPath()
                    arc.appendArc(withCenter: center, radius: radius,
                                  startAngle: 90, endAngle: 90 - 360 * CGFloat(percent) / 100,
                                  clockwise: true)
                    arc.lineWidth = stroke
                    arc.lineCapStyle = .round
                    ringColor.setStroke()
                    arc.stroke()
                }

                number.draw(at: numberOrigin)
                unit.draw(at: unitOrigin)
            }
            return true
        }
    }

    private static func roundedFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else { return base }
        return rounded
    }

    // MARK: - Meter rendering

    /// Segments per meter bar. A FIXED count (and a column sized to the widest
    /// possible label, "100%") keeps the status item's width constant as values
    /// change — a menu-bar item that resizes as numbers tick is distracting.
    private static let meterSegments = 7

    /// Draw the compact indicator: each window's percentage sitting above a small
    /// segmented bar — session first, weekly appended when the endpoint has it.
    ///
    /// Drawn as a *template* image, so AppKit inverts it for light/dark menu bars
    /// automatically and the over-threshold `contentTintColor` still applies.
    private func meterImage(for usage: Usage) -> NSImage {
        var percents = [usage.sessionPercent]
        if let weekly = usage.weeklyPercent { percents.append(weekly) }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            // Template rendering keys off alpha, not hue; black = fully opaque.
            .foregroundColor: NSColor.black
        ]
        let labels = percents.map { NSAttributedString(string: "\($0)%", attributes: attrs) }
        let lit = percents.map { Self.litSegments($0, of: Self.meterSegments) }

        let segments = Self.meterSegments
        let dot = CGSize(width: 2, height: 2)
        let dotGap: CGFloat = 1
        let columnGap: CGFloat = 7
        let textGap: CGFloat = 2
        let meterWidth = CGFloat(segments) * dot.width + CGFloat(segments - 1) * dotGap
        // Size every column to "100%" so the width never changes with the value.
        let widest = NSAttributedString(string: "100%", attributes: attrs).size().width
        let columnWidth = max(widest, meterWidth).rounded(.up)
        let textHeight = (labels.map { $0.size().height }.max() ?? 11).rounded(.up)

        let count = CGFloat(labels.count)
        let size = NSSize(width: columnWidth * count + columnGap * max(0, count - 1),
                          height: textHeight + textGap + dot.height)

        let image = NSImage(size: size, flipped: false) { _ in
            for (index, label) in labels.enumerated() {
                let originX = CGFloat(index) * (columnWidth + columnGap)

                let labelSize = label.size()
                label.draw(at: NSPoint(x: originX + (columnWidth - labelSize.width) / 2,
                                       y: dot.height + textGap))

                var dotX = originX + (columnWidth - meterWidth) / 2
                for segment in 0..<segments {
                    NSColor.black.withAlphaComponent(segment < lit[index] ? 1.0 : 0.25).setFill()
                    NSBezierPath(roundedRect: NSRect(x: dotX, y: 0,
                                                     width: dot.width, height: dot.height),
                                 xRadius: dot.width / 2,
                                 yRadius: dot.height / 2).fill()
                    dotX += dot.width + dotGap
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = Self.meterAccessibilityText(for: usage)
        return image
    }

    /// Segments lit for `percent`. Any non-zero usage lights at least one, so
    /// "barely used" never reads as "nothing here".
    private static func litSegments(_ percent: Int, of total: Int) -> Int {
        guard percent > 0 else { return 0 }
        return min(total, max(1, Int((Double(percent) / 100 * Double(total)).rounded())))
    }

    private static func meterAccessibilityText(for usage: Usage) -> String {
        var parts = ["session \(usage.sessionPercent)%"]
        if let weekly = usage.weeklyPercent { parts.append("weekly \(weekly)%") }
        return "claude.ai usage — " + parts.joined(separator: ", ")
    }
}

/// A borderless panel that can still become key — so it receives clicks and we
/// can dismiss on outside clicks. Borderless windows can't become key by default.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
