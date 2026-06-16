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

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var loginWindow: NSWindow?
    private var refreshTimer: Timer?

    // Phase 4 will make these settings; sensible Phase 0 defaults.
    private let refreshInterval: TimeInterval = 300   // 5 min
    private let showLabel = true

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-suspenders with LSUIElement: no Dock icon, menu-bar agent.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        startRefreshTimer()

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
        refreshTimer = Timer.scheduledTimer(timeInterval: refreshInterval,
                                            target: self,
                                            selector: #selector(timerFired),
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
        switch store.state {
        case .loaded(let usage):
            button.title = showLabel ? " \(usage.sessionPercent)%" : ""
            button.image = NSImage(systemSymbolName: symbolName(for: usage.sessionPercent),
                                   accessibilityDescription: "Claude usage \(usage.sessionPercent)%")
        case .loading:
            button.title = ""
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Loading")
        case .needsLogin:
            button.title = ""
            button.image = NSImage(systemSymbolName: "person.crop.circle.badge.questionmark",
                                   accessibilityDescription: "Sign in")
        case .error:
            button.title = ""
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                   accessibilityDescription: "Error")
        }
    }

    private func symbolName(for percent: Int) -> String {
        switch percent {
        case ..<34:  return "gauge.low"
        case 34..<67: return "gauge.medium"
        default:      return "gauge.high"
        }
    }
}
