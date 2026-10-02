import AppKit
import QuotaCore
import WebKit

/// Own WebKit session: never opens Meta's private keychain group or native app cookies.
@MainActor
final class MuseWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    static let shared = MuseWebSession()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()
    private var window: NSWindow?
    private var pageCompletion: CheckedContinuation<Void, Error>?
    private var pageTimeout: Task<Void, Never>?
    private var pageRequestID: UUID?
    private var pageNavigation: WKNavigation?
    private var authRequestID: UUID?
    private var authCompletion: TimedWebCompletion?
    private var onConnected: (@MainActor () -> Void)?
    private var lastVerifiedCredential: LocalProviderCredential?
    private let connectionAttempt = MuseConnectionAttempt()
    private var verificationTask: Task<Void, Never>?
    private var connectionButton: NSButton?
    private var statusLabel: NSTextField?
    private var stopped = false
    private static let home = URL(string: "https://muse.ai/")!

    func credentials() async throws -> LocalProviderCredential {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        if webView.url?.host != "muse.ai" || webView.isLoading {
            // A background read must never interrupt a login in progress.
            guard window == nil else { throw QuotaProviderError.authenticationRequired }
            try await loadHome()
        }
        guard webView.url?.scheme == "https", webView.url?.host == "muse.ai" else {
            lastVerifiedCredential = nil
            throw QuotaProviderError.authenticationRequired
        }
        let result = try await evaluateAuthCheck()
        try Task.checkCancellation()
        guard webView.url?.scheme == "https", webView.url?.host == "muse.ai" else {
            lastVerifiedCredential = nil
            throw MuseWebAuthenticationError.loginRequired
        }
        do {
            let credential = try MuseWebCredential.decodeAuthCheck(result, previous: lastVerifiedCredential)
            lastVerifiedCredential = credential
            return credential
        } catch {
            // A rejected or uncertain identity must never retain a previous token.
            lastVerifiedCredential = nil
            throw error
        }
    }

    func presentLogin(onConnected: @escaping @MainActor () -> Void) {
        stopped = false
        self.onConnected = onConnected
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        finishPage(.failure(CancellationError()))
        cancelAuthCheck(authRequestID)
        connectionAttempt.cancel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "连接 Muse"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView()
        let button = NSButton(title: "验证登录并读取额度", target: self, action: #selector(loginCompleted))
        button.bezelStyle = .rounded
        let hint = NSTextField(wrappingLabelWithString: connectionAttempt.state.message)
        hint.textColor = .secondaryLabelColor
        connectionButton = button
        statusLabel = hint
        connectionAttempt.onStateChange = { [weak self] state in self?.display(state) }
        for child in [webView, button, hint] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -10),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ])
        window.contentView = content
        self.window = window
        if webView.url == nil || webView.url?.host != "muse.ai" {
            webView.load(URLRequest(url: Self.home))
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func loginCompleted() {
        guard verificationTask == nil, let window else { return }
        verificationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let connected = await connectionAttempt.verify(authenticate: {
                _ = try await self.credentials()
            }, fetchQuota: {
                let provider = MuseQuotaProvider(credentialsLoader: { try await self.credentials() })
                _ = try await provider.fetchQuota()
            })
            guard self.window === window else { return }
            verificationTask = nil
            guard connected else { return }
            // Closing and refresh are permitted only after a real quota response
            // passed the provider's decoder and account verification.
            let completion = onConnected
            onConnected = nil
            window.close()
            completion?()
        }
    }

    private func display(_ state: MuseConnectionAttempt.State) {
        statusLabel?.stringValue = state.message
        if case .checking = state {
            connectionButton?.isEnabled = false
            connectionButton?.title = "正在验证…"
        } else {
            connectionButton?.isEnabled = true
            connectionButton?.title = "验证登录并读取额度"
        }
        if case .failed = state { statusLabel?.textColor = .systemRed }
        else { statusLabel?.textColor = .secondaryLabelColor }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        window = nil
        verificationTask?.cancel()
        verificationTask = nil
        connectionAttempt.cancel()
        onConnected = nil
        connectionButton = nil
        statusLabel = nil
    }

    func shutdown() {
        stopped = true
        lastVerifiedCredential = nil
        finishPage(.failure(CancellationError()))
        cancelAuthCheck(authRequestID)
        webView.stopLoading()
        window?.close()
        onConnected = nil
    }

    private func loadHome() async throws {
        guard pageCompletion == nil else { throw QuotaProviderError.networkUnavailable }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pageRequestID = id
                pageCompletion = continuation
                pageTimeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(18)) } catch { return }
                    guard self?.pageRequestID == id else { return }
                    self?.finishPage(.failure(QuotaProviderError.networkUnavailable))
                }
                pageNavigation = webView.load(URLRequest(url: Self.home))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.pageRequestID == id else { return }
                self?.webView.stopLoading()
                self?.finishPage(.failure(CancellationError()))
            }
        }
    }

    private func evaluateAuthCheck() async throws -> Any {
        // Run only on the verified same-origin page; no tokens leave this session
        // except through the quota provider's fixed HTTPS host.
        guard authCompletion == nil else { throw QuotaProviderError.networkUnavailable }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                authRequestID = id
                let completion = TimedWebCompletion(continuation: continuation) { [weak self] in
                    guard self?.authRequestID == id else { return }
                    self?.authRequestID = nil
                    self?.authCompletion = nil
                }
                authCompletion = completion
            webView.callAsyncJavaScript("""
                const controller = new AbortController();
                window.__aiQuotaAuthController = controller;
                const timeout = setTimeout(() => controller.abort(), 10000);
                try {
                    const response = await fetch('/api/auth/check', {
                        method: 'POST', credentials: 'include', cache: 'no-store', signal: controller.signal
                    });
                    let json;
                    try { json = await response.json(); } catch { json = null; }
                    const payload = {};
                    if (json && typeof json === 'object') {
                        for (const key of ['outcome', 'access_token', 'viewer_id', 'session_binding_id', 'type', 'reason', 'status']) {
                            if (Object.prototype.hasOwnProperty.call(json, key)) payload[key] = json[key];
                        }
                    }
                    return {httpStatus: response.status, payload};
                } finally {
                    clearTimeout(timeout);
                    if (window.__aiQuotaAuthController === controller) delete window.__aiQuotaAuthController;
                }
                """, arguments: [:], in: nil, in: .page, completionHandler: { result in
                switch result {
                case .success(let value): completion.finish(.success(value))
                case .failure: completion.finish(.failure(QuotaProviderError.networkUnavailable))
                }
            })
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAuthCheck(id) }
        }
    }

    private func cancelAuthCheck(_ id: UUID?) {
        guard let id, authRequestID == id else { return }
        // Abort the page's fetch as well as resuming Swift's suspended task.
        if webView.url?.scheme == "https", webView.url?.host == "muse.ai" {
            webView.evaluateJavaScript("window.__aiQuotaAuthController?.abort()", completionHandler: nil)
        }
        authCompletion?.finish(.failure(CancellationError()))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigation, pageNavigation === navigation else { return }
        finishPage(webView.url?.scheme == "https" && webView.url?.host == "muse.ai"
                   ? .success(()) : .failure(QuotaProviderError.authenticationRequired))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, pageNavigation === navigation else { return }
        finishPage(.failure(QuotaProviderError.networkUnavailable))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, pageNavigation === navigation else { return }
        finishPage(.failure(QuotaProviderError.networkUnavailable))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, window != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    private func finishPage(_ result: Result<Void, Error>) {
        pageTimeout?.cancel()
        pageTimeout = nil
        let completion = pageCompletion
        pageCompletion = nil
        pageRequestID = nil
        pageNavigation = nil
        completion?.resume(with: result)
    }
}

@MainActor
private final class TimedWebCompletion {
    private var continuation: CheckedContinuation<Any, Error>?
    private var timeout: Task<Void, Never>?
    private let onFinish: () -> Void

    init(continuation: CheckedContinuation<Any, Error>, onFinish: @escaping () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finish(.failure(QuotaProviderError.networkUnavailable))
        }
    }

    func finish(_ result: Result<Any, Error>) {
        guard let continuation else { return }
        timeout?.cancel()
        timeout = nil
        self.continuation = nil
        onFinish()
        continuation.resume(with: result)
    }
}
