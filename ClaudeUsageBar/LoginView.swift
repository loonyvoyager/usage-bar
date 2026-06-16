//
//  LoginView.swift
//  ClaudeUsageBar
//
//  Embedded WKWebView login. The user signs in to claude.ai once; cookies
//  persist in the shared default WKWebsiteDataStore (the same store
//  ClaudeSession reads). No cookie scraping, no token paste (brief §2).
//
//  Authentication is detected purely by navigation: once the web view lands
//  back on a claude.ai page that isn't the login/auth flow, we call
//  `onAuthenticated`. Claudesession's actual fetch is the final authority.
//

import SwiftUI
import WebKit

struct LoginView: NSViewRepresentable {
    /// Called once when the web view appears to have completed login.
    var onAuthenticated: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAuthenticated: onAuthenticated)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Shared, persistent cookie jar — must match ClaudeSession.makeWebView().
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onAuthenticated: () -> Void
        private var fired = false

        init(onAuthenticated: @escaping () -> Void) {
            self.onAuthenticated = onAuthenticated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !fired, let url = webView.url else { return }
            let host = url.host ?? ""
            let path = url.path.lowercased()
            // Back on a claude.ai page that isn't login/auth ⇒ treat as signed in.
            if host.contains("claude.ai"), !path.contains("login"), !path.contains("/auth") {
                fired = true
                onAuthenticated()
            }
        }
    }
}
