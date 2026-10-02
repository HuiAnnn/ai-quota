import AppKit
import QuotaCore

@MainActor
final class ConnectionCoordinator: ObservableObject {
    static let shared = ConnectionCoordinator()
    @Published private(set) var connectingIDs: Set<String> = []
    func connect(_ descriptor: ProviderDescriptor, reason: QuotaProviderError? = nil,
                 onConnected: @escaping @MainActor () -> Void) {
        switch reason {
        case .accountChanged, .networkUnavailable, .requestFailed, .rateLimited, .invalidResponse:
            onConnected()
            return
        case .authenticationRequired, .notInstalled:
            if descriptor.id != "muse" {
                openApplication(descriptor)
                return
            }
        default: break
        }
        if descriptor.id == "muse" {
            MuseWebSession.shared.presentLogin(onConnected: onConnected)
            return
        }
        let applicationNames = ["grok": "Grok Bot", "manus": "Manus Studio", "cue": "Cue"]
        guard let name = applicationNames[descriptor.id] else {
            openApplication(descriptor)
            return
        }
        guard connectingIDs.insert(descriptor.id).inserted else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task {
            defer { connectingIDs.remove(descriptor.id) }
            do {
                // An explicit connect action may show the macOS Keychain consent dialog.
                try await Task.detached(priority: .userInitiated) {
                    try ElectronSafeStorageDecryptor.authorizeAccess(applicationName: name)
                }.value
                onConnected()
            } catch {
                let message: String
                switch error as? QuotaProviderError {
                case .authenticationRequired: message = "未找到 \(descriptor.name) 的登录记录。请先在原应用登录，再回到额度面板刷新。"
                case .accessRequired: message = "macOS 尚未允许读取 \(descriptor.name) 的登录信息。请重试，并在系统钥匙串提示中允许读取。"
                case .invalidResponse: message = "\(descriptor.name) 的本机登录记录无法识别。请在原应用重新登录后重试。"
                default: message = "暂时无法连接 \(descriptor.name)，请稍后重试。"
                }
                showError(message)
            }
        }
    }

    func openApplication(_ descriptor: ProviderDescriptor) {
        guard let bundle = descriptor.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            showError("未找到 \(descriptor.name)，请先安装并登录。")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func showError(_ message: String) {
        // MenuBarExtra may close while a login or consent window opens. A native
        // application alert remains visible independently of that transient panel.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "连接提示"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
