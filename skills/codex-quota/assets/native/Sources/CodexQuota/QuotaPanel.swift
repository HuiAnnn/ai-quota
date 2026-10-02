import AppKit
import QuotaCore
import SwiftUI

struct QuotaBucketSection: View {
    let entry: QuotaBucketEntry
    let now: Date

    var body: some View {
        Section {
            if let primary = entry.bucket.primary {
                QuotaWindowRow(window: primary, now: now)
            }
            if let secondary = entry.bucket.secondary {
                QuotaWindowRow(window: secondary, now: now)
            }
            if entry.bucket.primary == nil && entry.bucket.secondary == nil {
                Text("暂未提供周期额度").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(entry.displayName)
                Spacer()
                if entry.id.lowercased() == "codex", let plan = entry.bucket.planType {
                    Text(plan.capitalized).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct QuotaWindowRow: View {
    let window: RateLimitWindow
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            LabeledContent(window.periodLabel) {
                Text(window.remainingPercent.map { "剩余 \(QuotaStore.percentText($0))" } ?? "暂不可获取")
                    .monospacedDigit()
            }
            if let remaining = window.remainingPercent {
                ProgressView(value: remaining, total: 100)
                    .accessibilityLabel("\(window.periodLabel)剩余额度")
                    .accessibilityValue(QuotaStore.percentText(remaining))
            }
            LabeledContent("自动重置") {
                VStack(alignment: .trailing, spacing: 2) {
                    if let date = window.resetDate {
                        Text(DisplayFormat.date(date))
                        Text(date > now ? DisplayFormat.countdown(to: date, now: now) + "后" : "等待更新")
                    } else {
                        Text("时间暂不可获取")
                    }
                }
                .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct ResetCreditsSection: View {
    @ObservedObject var store: QuotaStore
    let credits: ResetCredits?
    let now: Date

    var body: some View {
        Section {
            LabeledContent("可用次数", value: credits?.displayCount.map { "\($0) 次" } ?? "暂不可获取")
            if let message = store.resetMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.hasPendingReset {
                Button(store.pendingResetActionTitle) { store.retryPendingReset() }
                    .buttonStyle(.bordered)
                    .disabled(store.isBusy)
            }
            if let credits {
                let rows = credits.sortedCredits
                if rows.isEmpty {
                    Text(credits.displayCount == 0 ? "暂无可用的额外重置机会" : "暂未提供每次机会的到期明细")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rows) { credit in
                        creditRow(credit)
                    }
                    if let count = credits.displayCount, count > rows.count {
                        Text("还有 \(count - rows.count) 次机会未提供明细")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("暂未获取到重置机会信息").foregroundStyle(.secondary)
            }
        } header: {
            Text("完全重置机会")
        } footer: {
            Text("点击“重置”会立即使用 1 次机会。到期时间指这次机会的有效期。")
        }
    }

    private func creditRow(_ credit: ResetCredit) -> some View {
        let isSelected = store.isResetting && store.resettingCreditID == credit.id
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(credit.resetType == "codexRateLimits" ? "完全重置" : (credit.title ?? "额度重置"))
                if let expiry = credit.expirationDate {
                    Text("有效至 \(DisplayFormat.date(expiry))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(expiry > now ? DisplayFormat.countdown(to: expiry, now: now) + "后到期" : "已到期")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("未提供到期时间").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { store.resetCredit(credit) } label: {
                HStack {
                    if isSelected { ProgressView().controlSize(.mini) }
                    Text(isSelected ? "重置中…" : "重置")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isBusy || store.hasPendingReset || !store.canReset(credit, now: now))
            .help("使用这次机会立即重置 Codex 额度")
        }
        .padding(.vertical, 4)
    }
}

enum DisplayFormat {
    private static var beijingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    static func date(_ value: Date) -> String {
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dateFormatter.dateFormat = beijingCalendar.component(.year, from: value)
            == beijingCalendar.component(.year, from: Date()) ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return dateFormatter.string(from: value)
    }

    static func time(_ value: Date) -> String {
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dateFormatter.dateFormat = beijingCalendar.isDateInToday(value) ? "HH:mm:ss" : "M/d HH:mm"
        return dateFormatter.string(from: value)
    }

    static var timeZoneLabel: String {
        "北京时间 GMT+8"
    }

    static func day(_ value: Date) -> String {
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        dateFormatter.dateFormat = "yyyy年M月d日"
        return dateFormatter.string(from: value)
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }

    static func countdown(to date: Date, now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        let days = seconds / 86_400
        let hours = seconds % 86_400 / 3_600
        let minutes = seconds % 3_600 / 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(seconds % 60)秒" }
        return "\(seconds)秒"
    }
}
