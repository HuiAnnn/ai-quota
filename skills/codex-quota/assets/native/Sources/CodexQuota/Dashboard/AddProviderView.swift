import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AddProviderView: View {
    @Environment(\.dismiss) private var dismiss
    let importFile: (URL) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加 AI 应用").font(.headline)
            Text("导入本机额度 JSON 文件。其他应用或脚本更新这个文件后，面板会每分钟重新读取。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("文件只包含额度、周期和更新时间；无需填写密码或 API Key。")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("选择额度文件…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    panel.canChooseDirectories = false
                    panel.message = "选择由应用或脚本生成的额度 JSON 文件"
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try importFile(url); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 380)
    }
}
