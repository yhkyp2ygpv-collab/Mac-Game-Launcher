import SwiftUI
import AppKit
import WebKit

/// Signing in to Epic in Anvil: Epic's own sign-in page, inside Anvil. Once the player has
/// signed in there, Epic hands back a one-time code, which Anvil passes straight to legendary —
/// nothing to copy or paste. The password only ever goes to Epic's page; Anvil sees the code,
/// which works once, for a few minutes, and is written nowhere.
///
/// Epic's web sign-in is remembered by the page (as in a browser), so signing in again later —
/// after a sign-out, or on a new legendary — is a click. Epic's page in the browser, with the code
/// pasted here, is still there for anyone who prefers it.
struct EpicSignInView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        EpicSignInPanel(webHeight: 520, onCancel: { dismiss() }, onDone: { dismiss() })
            .padding(24)
            .frame(width: 560)
    }
}

/// The sign-in itself, in its own window or right on the Epic page. Two ways:
/// - Epic's page, here in Anvil: the code is picked up by itself the moment Epic shows it.
/// - The browser, where saved passwords, passkeys and an Epic sign-in already there work: Epic's
///   page ends on a line of text with the code; copying it and pressing Paste Code & Sign In
///   finishes. The clipboard is read only on that press.
struct EpicSignInPanel: View {
    var webHeight: CGFloat = 480
    var onCancel: (() -> Void)? = nil
    var onDone: () -> Void = {}

    @ObservedObject private var account = EpicAccount.shared
    @State private var code = ""
    @State private var error: String?
    @State private var working = false
    @State private var inBrowser = false
    @State private var pageLoading = true
    @State private var openedSafari = false

    /// legendary's sign-in: Epic's login, then its redirect page with the code for legendary's client.
    static let signInPage = URL(string: "https://legendary.gl/epiclogin")!
    static let epicLogin = URL(string: "https://www.epicgames.com/id/login?redirectUrl=https%3A%2F%2Fwww.epicgames.com%2Fid%2Fapi%2Fredirect%3FclientId%3D34a02cf8f4414e29b15921876da36f9a%26responseType%3Dcode")!

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sign in to Epic Games").font(.title2).bold()
                Spacer()
                if working || account.status != nil {
                    ProgressView().controlSize(.small)
                    Text(account.status ?? "Signing in…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Once, to see and install the games you own and to sign them in as you play. Your password goes only to Epic; Anvil gets a one-time code from Epic's page and hands it to legendary, the open-source Epic client.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("", selection: $inBrowser) {
                Text("Sign in here").tag(false)
                Text("Sign in with your browser — saved passwords work").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if inBrowser {
                browserSteps
            } else {
                ZStack {
                    EpicWebSignIn(start: Self.epicLogin, loading: $pageLoading) { found in
                        finish(with: found)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    if pageLoading && !working {
                        ProgressView("Opening Epic's sign-in…").controlSize(.small)
                    }
                }
                .frame(minHeight: webHeight)
                .disabled(working)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let onCancel {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { onCancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .onChange(of: inBrowser) { _, _ in error = nil }
    }

    private var browserSteps: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                stepNumber(1)
                VStack(alignment: .leading, spacing: 6) {
                    Button(openedSafari ? "Open Epic's Page Again" : "Open Epic's Sign-In in Your Browser") {
                        NSWorkspace.shared.open(Self.signInPage)
                        openedSafari = true
                    }
                    .buttonStyle(.borderedProminent)
                    Text("Sign in there as usual — your browser fills in your saved password or passkey, and if you're already signed in to Epic there it skips straight to the next step.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                stepNumber(2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Epic's page then shows one line of text with “authorizationCode” in it. Press ⌘A, then ⌘C to copy it.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                stepNumber(3)
                VStack(alignment: .leading, spacing: 8) {
                    Button("Paste Code & Sign In") { pasteAndSignIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)
                    HStack {
                        SecureField("or paste it here yourself", text: $code)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { finish(with: code) }
                        Button("Sign In") { finish(with: code) }
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    }
                    Text("Each code works once, for a few minutes. Anvil keeps no password.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func stepNumber(_ n: Int) -> some View {
        Text("\(n)").font(.callout.weight(.bold)).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Color.accentColor, in: Circle())
    }

    /// The clipboard, read on this press only: Epic's code in it, or what it says is missing.
    private func pasteAndSignIn() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else {
            error = "Nothing to paste yet. On Epic's page, press ⌘A then ⌘C, and try again."
            return
        }
        let found = EpicAccount.code(fromRedirect: text)
            ?? (text.contains("authorizationCode") ? EpicAccount.authorizationCode(from: text) : nil)
        guard let found, !found.isEmpty else {
            error = "What's copied isn't Epic's code. On Epic's page — the one that shows “authorizationCode” — press ⌘A then ⌘C, and try again."
            return
        }
        finish(with: found) {
            // A used code is no good to anyone, and isn't left on the clipboard.
            if pasteboard.string(forType: .string) == text { pasteboard.clearContents() }
        }
    }

    private func finish(with entered: String, then: @escaping () -> Void = {}) {
        guard !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await account.signIn(code: entered)
                code = ""
                then()
                onDone()
            } catch {
                self.error = error.localizedDescription
                    + (inBrowser ? " Codes work once, for a few minutes: open Epic's page again for a fresh one." : " Sign in on the page again, or with your browser.")
            }
            working = false
        }
    }
}

/// Epic's sign-in page in a web view, watching for the page Epic ends on: its redirect, which
/// carries the one-time code (as JSON, or as a `code` in a launcher URL). The code goes to
/// `onCode` and the page is left; nothing of it is logged or kept.
struct EpicWebSignIn: NSViewRepresentable {
    let start: URL
    @Binding var loading: Bool
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Anvil's own web data, apart from Safari's: Epic remembers the sign-in here, so the next
        // one is a click.
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: start))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: EpicWebSignIn
        private var delivered = false

        init(_ parent: EpicWebSignIn) { self.parent = parent }

        private func deliver(_ code: String) {
            guard !delivered, !code.isEmpty else { return }
            delivered = true
            DispatchQueue.main.async { self.parent.onCode(code) }
        }

        /// The launcher URL some of Epic's flows end on: …/launcher/authorized?code=…
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let code = Self.launcherCode(in: url) {
                deliver(code)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.loading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.loading = false }
            guard let url = webView.url, Self.isRedirectPage(url) else { return }
            webView.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] result, _ in
                guard let text = result as? String else { return }
                let code = EpicWebSignIn.code(fromRedirect: text)
                if let code { self?.deliver(code) }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.loading = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.loading = false }
        }

        /// "Sign in with Google, Apple, Xbox…" opens a window of its own; it goes in this one,
        /// and comes back to Epic's page when it's done.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, action.request.url != nil { webView.load(action.request) }
            return nil
        }

        static func isRedirectPage(_ url: URL) -> Bool { EpicAccount.isRedirectPage(url) }
        static func launcherCode(in url: URL) -> String? { EpicAccount.launcherCode(in: url) }
    }

    static func code(fromRedirect text: String) -> String? { EpicAccount.code(fromRedirect: text) }
}
