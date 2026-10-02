import QuotaCore
import SwiftUI

struct ProviderDetailSection: View {
    let descriptor: ProviderDescriptor
    let state: ProviderState?
    let now: Date
    let isConnecting: Bool
    let connect: () -> Void
    let open: () -> Void

    var body: some View {
        if let error = state?.errorMessage {
            Section("\(descriptor.name) · 连接状态") {
                Text(error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !descriptor.id.hasPrefix("custom.") {
                    HStack {
                        Button(isConnecting ? "连接中…" : ProviderRecoveryAction.title(for: state?.error)) { connect() }
                            .buttonStyle(.bordered)
                            .disabled(isConnecting || state?.isRefreshing == true)
                        Button("打开 \(descriptor.name)") { open() }.buttonStyle(.bordered)
                    }
                }
                if state?.isStale == true { Text("当前显示上次数据").font(.caption).foregroundStyle(.secondary) }
            }
        }
        if let snapshot = state?.snapshot {
            ForEach(snapshot.metrics) { metric in
                Section(metric.id == snapshot.metrics.first?.id ? "\(descriptor.name) · \(metric.label)" : metric.label) {
                    if let percent = metric.remainingPercent, metric.kind == .periodic {
                        LabeledContent("剩余", value: DisplayFormat.percent(percent))
                        ProgressView(value: percent, total: 100)
                    }
                    if let remaining = metric.remaining {
                        LabeledContent(metric.kind == .balance ? "余额" : "可用额度", value: Self.amount(remaining, unit: metric.unit))
                    }
                    if let limit = metric.limit {
                        LabeledContent(metric.kind == .balance ? "总额度" : "周期总量", value: Self.amount(limit, unit: metric.unit))
                    }
                    if metric.kind == .periodic {
                        LabeledContent("自动重置") {
                            if let reset = metric.reset {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(reset.precision == .day ? DisplayFormat.day(reset.date) + "（时间未明确）" : DisplayFormat.date(reset.date))
                                    if reset.precision == .instant {
                                        Text(reset.date > now ? DisplayFormat.countdown(to: reset.date, now: now) + "后" : "等待更新")
                                    }
                                }
                            } else { Text("来源未提供") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if metric.kind == .balance {
                        Text("额外额度，独立于周期百分比").font(.caption).foregroundStyle(.secondary)
                    } else if !metric.contributesToSummary {
                        Text("此周期单列显示，菜单栏使用主要周期").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
            }
        } else if state?.errorMessage == nil {
            Section(descriptor.name) {
                Text(state?.isRefreshing == true ? "正在读取额度…" : "等待同步").foregroundStyle(.secondary)
            }
        }
        if let date = state?.updatedAt {
            Section { Text("\(state?.isStale == true ? "上次更新" : "更新于") \(DisplayFormat.time(date)) · 北京时间")
                .font(.caption).foregroundStyle(.secondary) }
        }
    }

    private static func amount(_ value: Double, unit: String?) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + (unit.map { " \($0)" } ?? "")
    }
}
