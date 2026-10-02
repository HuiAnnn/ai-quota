import QuotaCore
import SwiftUI

struct CodexDetailSections: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var announcements: AnnouncementStore
    let now: Date

    var body: some View {
        if let error = store.errorMessage {
            Section("连接状态") { Text(error).foregroundStyle(.secondary) }
        }
        if let snapshot = store.snapshot {
            if snapshot.orderedBuckets.isEmpty {
                Section("额度") { Text("暂未获取到额度周期信息").foregroundStyle(.secondary) }
            }
            ForEach(snapshot.orderedBuckets.filter { $0.id.lowercased() == "codex" }) { entry in
                QuotaBucketSection(entry: entry, now: now)
            }
            ResetCreditsSection(store: store, credits: snapshot.rateLimitResetCredits, now: now)
            AnnouncementSection(store: announcements)
            ForEach(snapshot.orderedBuckets.filter { $0.id.lowercased() != "codex" }) { entry in
                QuotaBucketSection(entry: entry, now: now)
            }
            if let date = store.updatedAt {
                Section { Text("更新于 \(DisplayFormat.time(date)) · 北京时间").font(.caption).foregroundStyle(.secondary) }
            }
        } else {
            Section("Codex") {
                Text(store.isRefreshing ? "正在读取额度…" : "在 Codex 中登录 ChatGPT 账号后，点击刷新。")
                    .foregroundStyle(.secondary)
                Button("打开 Codex") { store.openCodex() }.buttonStyle(.bordered)
            }
            if store.hasPendingReset || store.resetMessage != nil {
                Section("额度重置") {
                    if let message = store.resetMessage { Text(message).foregroundStyle(.secondary) }
                    if store.hasPendingReset {
                        Button(store.pendingResetActionTitle) { store.retryPendingReset() }
                            .buttonStyle(.bordered).disabled(store.isBusy)
                    }
                }
            }
        }
    }
}
