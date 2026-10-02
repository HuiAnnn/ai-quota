import QuotaCore
import SwiftUI

struct ProviderOverviewItem: View {
    let descriptor: ProviderDescriptor
    let state: ProviderState?
    let selected: Bool
    let isDefault: Bool
    let select: () -> Void
    let isConnecting: Bool

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                ProviderAppIcon(descriptor: descriptor)
                    .overlay(alignment: .bottomTrailing) {
                        if isDefault {
                            Image(systemName: "pin.fill").font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .help("菜单栏默认额度")
                        }
                    }
                HStack(spacing: 3) {
                    Text(state?.remainingPercent.map(DisplayFormat.percent) ?? "—")
                        .font(.callout).fontWeight(.semibold).monospacedDigit()
                    if state?.isStale == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                            .help("当前显示上次数据，请刷新")
                    }
                }
                Text(isConnecting ? "正在连接…" : (state?.isRefreshing == true && state?.snapshot == nil ? "正在同步…" : resetCaption))
                    .font(.caption2).foregroundStyle(resetSummary.text.contains("已到") ? Color.orange : Color.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                    .frame(height: 26)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4).padding(6).frame(width: 72)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(descriptor.name + "\n" + resetHelp)
        .accessibilityLabel("\(descriptor.name)，剩余\(state?.remainingPercent.map(DisplayFormat.percent) ?? "未知")\(isDefault ? "，菜单栏默认" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(isConnecting ? "正在连接" : (state?.isStale == true ? "上次数据" : ""))
        .accessibilityHint("显示此应用的额度详情")
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var resetSummary: ProviderResetSummary.Summary {
        ProviderResetSummary.summary(for: state?.snapshot)
    }

    private var resetCaption: String {
        guard state?.snapshot != nil else { return statusText }
        let summary = resetSummary
        guard let reset = summary.reset else {
            return descriptor.id == "manus" ? "月度重置\n时间未提供" : "重置时间\n未提供"
        }
        if summary.text.contains("已到") { return "已到重置\n等待刷新" }
        if reset.precision == .day {
            return summary.text.replacingOccurrences(of: "重置（时间未明确）", with: "\n时间未明确")
        }
        return DisplayFormat.date(reset.date).replacingOccurrences(of: " ", with: "\n") + " 重置"
    }

    private var resetHelp: String {
        var lines = [resetSummary.detail].compactMap { $0 }
        if state?.isStale == true { lines.append("当前显示上次数据") }
        if let date = state?.updatedAt { lines.append("最近同步：\(AnnouncementSection.beijingTime(date))") }
        return lines.joined(separator: "\n")
    }

    private var statusText: String {
        switch state?.error {
        case .accessRequired: return "钥匙串待授权"
        case .authenticationRequired: return "请先登录"
        case .accountChanged: return "账号已变化"
        case .notInstalled: return "未找到应用"
        case .networkUnavailable: return "网络连接失败"
        case .invalidResponse: return "无法识别额度"
        case .requestFailed: return "额度查询失败"
        case .rateLimited: return "稍后重试"
        case nil: return "暂无周期百分比"
        }
    }

}
