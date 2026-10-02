import QuotaCore
import SwiftUI

/// Actions belong to the selected detail, independently of the menu-bar default.
struct ProviderActionsBar: View {
    let descriptor: ProviderDescriptor
    let state: ProviderState?
    let isDefault: Bool
    let isConnecting: Bool
    let setDefault: () -> Void
    let connect: () -> Void
    let refresh: () -> Void
    let open: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(isDefault ? "菜单栏默认" : "设为菜单栏默认", action: setDefault)
                .disabled(isDefault)
                .help("在菜单栏显示 \(descriptor.name) 的剩余额度")
            if descriptor.bundleIdentifier != nil {
                Button("打开 \(descriptor.name)", action: open)
            }
            if descriptor.id != "codex" && !descriptor.id.hasPrefix("custom.") {
                Button(action: connect) {
                    HStack(spacing: 4) {
                        if isConnecting { ProgressView().controlSize(.mini) }
                        Text(isConnecting ? "连接中…" : (descriptor.id == "muse" ? "登录 Muse" : "读取本机登录"))
                    }
                }
                .disabled(isConnecting || state?.isRefreshing == true)
                .help(descriptor.id == "muse" ? "在独立登录窗口连接 Muse" : "允许读取 \(descriptor.name) 的本机登录信息")
            }
            if descriptor.id.hasPrefix("custom.") {
                if state?.error != nil {
                    Button("重试", action: refresh).disabled(state?.isRefreshing == true)
                }
                Button("移除此扩展", role: .destructive, action: remove)
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(descriptor.name) 的操作")
    }
}
