//
//  AppDelegate.swift
//  ClaudeUsageBar
//
//  The orchestrator. Owns the NSStatusItem, the NSPopover, the login window,
//  and the refresh timer. It is the ONLY place that wires the network
//  (ClaudeSession) to the observable store (UsageStore) and down to the UI via
//  closures. UI never calls the network directly (brief §3, invariant 2).
//

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = UsageStore()
    private let session = ClaudeSession()

    private let settings = AppSettings()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var loginWindow: NSWindow?
    private var refreshTimer: Timer?
    private var displayTimer: Timer?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with LSUIElement: no Dock icon, menu-bar agent.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
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

    // MARK: - Status item & popover

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.medium",
                                   accessibilityDescription: "Claude usage")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        let root = UsagePopoverView(
            store: store,
            settings: settings,
            onRefresh: { [weak self] in self?.refresh() },
            onLogin:   { [weak self] in self?.showLogin() },
            onQuit:    { [weak self] in self?.quit() }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]   // popover tracks SwiftUI content height
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
                 + "The internal endpoint may have changed — see Phase 1 in the brief."
        case SessionError.network(let detail):
            return detail
        default:
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - Login

    private func showLogin() {
        if popover.isShown { popover.performClose(nil) }

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
