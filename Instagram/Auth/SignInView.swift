import SwiftUI
import WebKit
import OSLog

/// Instagram's own login page in an isolated web view, shown once. When the page has set the
/// session cookies (`sessionid`, `csrftoken`, `ds_user_id`), they become an `IGSession` and the web view goes
/// away for good: everything after this is native.
struct SignInView: View {
    var onComplete: ([StoredCookie]) -> Void
    var onCancel: () -> Void

    @State private var hasLoaded = false
    @State private var signedIn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(signedIn ? "Signed in" : "Sign in to Instagram")
                        .font(.system(size: 15, weight: .semibold))
                    Text("On Instagram's own page. The session stays on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !hasLoaded { Spinner(size: 14) }
                Button("Cancel", action: onCancel)
                    .buttonStyle(.secondaryPill)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 60)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            SignInWebView(
                onLoaded: { hasLoaded = true },
                onCaptured: { cookies in
                    signedIn = true
                    onComplete(cookies)
                }
            )
            // Until the login page first draws, a blank white page looks broken.
            .overlay {
                if !hasLoaded || signedIn {
                    VStack(spacing: 12) {
                        Spinner(size: 20)
                        Text(signedIn ? "Signing in…" : "Opening the Instagram sign-in page…")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                }
            }
        }
        .frame(width: 520, height: 700)
        .background(Theme.background)
    }
}

private struct SignInWebView: NSViewRepresentable {
    var onLoaded: () -> Void
    var onCaptured: ([StoredCookie]) -> Void

    static let loginURL = URL(string: "https://www.instagram.com/accounts/login/")!

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Throwaway store: nothing from this login lingers in WebKit afterwards.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        // The same identity the API requests use, so Instagram sees one consistent client.
        web.customUserAgent = IGClient.userAgent
        web.navigationDelegate = context.coordinator
        config.websiteDataStore.httpCookieStore.add(context.coordinator)
        context.coordinator.startPolling(config.websiteDataStore.httpCookieStore)
        web.load(URLRequest(url: Self.loginURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.websiteDataStore.httpCookieStore.remove(coordinator)
        coordinator.stopPolling()
        nsView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        var parent: SignInWebView
        private var captured = false
        private var pending: Task<Void, Never>?
        private var poll: Task<Void, Never>?
        private let log = Logger(subsystem: "com.subhash.Matte", category: "SignIn")

        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoaded()
            check(webView.configuration.websiteDataStore.httpCookieStore)
        }

        /// Cookie-change notifications don't arrive from every WebKit (macOS 15's, for one,
        /// can stay silent for a non-persistent store), so look every second as well.
        func startPolling(_ store: WKHTTPCookieStore) {
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !self.captured else { return }
                    if self.pending == nil { self.check(store) }
                }
            }
        }

        func stopPolling() { poll?.cancel() }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Keep the sheet on the login: links to help pages and the like open in the browser.
            if let url = action.request.url, action.navigationType == .linkActivated,
               let host = url.host(), !(host.hasSuffix("instagram.com") || host.hasSuffix("facebook.com") || host.hasSuffix("meta.com")) {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }

        // Instagram's login is a single-page app: signing in sets cookies without a page load, so
        // watch the cookie store itself.
        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in self.check(cookieStore) }
        }

        private func check(_ store: WKHTTPCookieStore) {
            guard !captured else { return }
            pending?.cancel()
            pending = Task {
                defer { if !Task.isCancelled { pending = nil } }
                let all = await store.allCookies()
                let stored = all.filter { $0.domain.hasSuffix("instagram.com") }.map(StoredCookie.init)
                guard IGSession.isSignedIn(stored) else { return }
                // Instagram can rotate csrftoken just after login; give it a moment to settle.
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, !captured else { return }
                let final = await store.allCookies().filter { $0.domain.hasSuffix("instagram.com") }.map(StoredCookie.init)
                guard IGSession.isSignedIn(final) else { return }
                captured = true
                log.info("Captured \(final.count) cookies")
                parent.onCaptured(final)
            }
        }
    }
}
