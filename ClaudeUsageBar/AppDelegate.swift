//
//  AppDelegate.swift
//  ClaudeUsageBar
//
//  The orchestrator. Owns the NSStatusItem, the dropdown panel, the login
//  window, and the refresh timer. It is the ONLY place that wires the network
//  (ClaudeSession) to the observable store (UsageStore) and down to the UI via
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
    private let session = ClaudeSession()

    private let settings = AppSettings()

    private var statusItem: NSStatusItem!
    private var panel: KeyPanel!
    private var contentView: NSView!            // the NSHostingView; read its fittingSize
    private var loginWindow: NSWindow?
    private var refreshTimer: Timer?
    private var displayTimer: Timer?
    private var clickMonitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with LSUIElement: no Dock icon, menu-bar agent.
        NSApp.setActivationPolicy(.accessory)

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
                                   accessibilityDescription: "Claude usage")
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
        refreshTimer = Timer.scheduledTimer(timeInterval: interval,
                                            target: self,
                                            selector: #selector(timerFired),
                                            userInfo: nil,
                                            repeats: true)
    }

    /// React to a settings change: pick up a new interval and re-render the bar.
    private func applySettings() {
        startRefreshTimer()
        updateButton()
    }

    /// Re-render the menu-bar label every minute so the "% / time left" mode's
    /// countdown stays current between (5-min) network refreshes. No network.
    @objc private func displayTick() { updateButton() }

    private func startDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(timeInterval: 60,
                                            target: self,
                                            selector: #selector(displayTick),
                                            userInfo: nil,
                                            repeats: true)
    }

    private func refresh() {
        // Don't flash a spinner over good data on periodic refreshes.
        if store.latest == nil {
            store.setState(.loading)
            updateButton()
        }
        Task {
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
        window.title = "Sign in to Claude"
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
    }

    /// Render the loaded state per the user's chosen menu-bar mode.
    private func renderLoaded(_ button: NSStatusBarButton, _ usage: Usage) {
        button.contentTintColor = usage.sessionPercent >= settings.warnThreshold ? .systemOrange : nil
        switch settings.menuBarMode {
        case .iconOnly:
            button.image = NSImage(systemSymbolName: symbolName(for: usage.sessionPercent),
                                   accessibilityDescription: "Claude usage \(usage.sessionPercent)%")
            button.imagePosition = .imageOnly
            button.title = ""
        case .iconPercent:
            button.image = NSImage(systemSymbolName: symbolName(for: usage.sessionPercent),
                                   accessibilityDescription: "Claude usage \(usage.sessionPercent)%")
            button.imagePosition = .imageLeading
            button.title = " \(usage.sessionPercent)%"
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

    private func symbolName(for percent: Int) -> String {
        switch percent {
        case ..<34:  return "gauge.low"
        case 34..<67: return "gauge.medium"
        default:      return "gauge.high"
        }
    }
}

/// A borderless panel that can still become key — so it receives clicks and we
/// can dismiss on outside clicks. Borderless windows can't become key by default.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
