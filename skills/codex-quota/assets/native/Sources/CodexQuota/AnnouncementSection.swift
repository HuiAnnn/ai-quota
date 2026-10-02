import QuotaCore
import SwiftUI

struct AnnouncementSection: View {
    @ObservedObject var store: AnnouncementStore
    @State private var expanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                if store.items.isEmpty {
                    if store.isRefreshing {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在同步重置动态…").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(store.updatedAt == nil ? "暂无已同步公告" : "来源暂未收录公告")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(store.items) { announcement in
                    AnnouncementRow(announcement: announcement)
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let date = store.updatedAt {
                        Text("上次成功同步：\(Self.beijingTime(date))")
                    }
                    Text("运行时每 10 分钟检查；公告可能延迟或遗漏，实际到账以账号额度为准。")
                    Link("数据来源：Codex Resets（第三方）", destination: URL(string: "https://codex-resets.com")!)
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } label: {
                HStack {
                    Text("Codex 重置动态\(store.items.isEmpty ? "" : "（\(store.items.count)）")")
                    Spacer()
                    if store.isRefreshing { ProgressView().controlSize(.mini) }
                }
            }
        }
    }

    static func beijingTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm '北京时间'"
        return formatter.string(from: date)
    }
}

private struct AnnouncementRow: View {
    let announcement: ResetAnnouncement

    private var kind: String {
        switch announcement.kind {
        case .regular: return "额度重置"
        case .banked: return "赠送重置机会"
        case .unknown: return "重置相关消息"
        }
    }
    private var phase: String {
        switch announcement.currentPhase {
        case .upcoming: return "预告"
        case .announcedComplete: return "原文称已完成"
        case .unconfirmed: return "状态待确认"
        case .observed: return "第三方观察"
        }
    }

    var body: some View {
        DisclosureGroup {
            Text(announcement.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Link(announcement.phase == .observed ? "查看观察所引用的原帖 ↗" : "查看 Tibo 原帖 ↗", destination: announcement.sourceURL)
                .font(.callout)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(kind) · \(phase)").font(.callout).fontWeight(.medium)
                if let timing = announcement.resetTiming {
                    Text(timing.beijingText)
                        .font(.caption).foregroundStyle(Color.accentColor)
                }
                Text("发布于 \(AnnouncementSection.beijingTime(announcement.date))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(announcement.text)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 3)
        }
    }
}
