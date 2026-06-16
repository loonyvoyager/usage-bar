//
//  ClaudeUsageBarApp.swift
//  ClaudeUsageBar
//
//  App entry point. This is a menu-bar-only agent (LSUIElement = true), so
//  there is no main window scene. All real work happens in AppDelegate; the
//  `Settings` scene below is an invisible, valid App body that never opens on
//  its own.
//

import SwiftUI

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No WindowGroup: a menu-bar agent shows nothing at launch.
        Settings {
            EmptyView()
        }
    }
}
