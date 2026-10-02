import Foundation
import QuotaCore

enum ProviderResetSummary {
    struct Summary: Equatable, Sendable {
        let text: String
        let detail: String?
        let metricLabel: String?
        let reset: QuotaReset?
    }

    static func text(for snapshot: ProviderSnapshot?, now: Date = Date()) -> String {
        summary(for: snapshot, now: now).text
    }

    static func summary(for snapshot: ProviderSnapshot?, now: Date = Date()) -> Summary {
        guard let snapshot else {
            return Summary(text: "等待额度数据", detail: nil, metricLabel: nil, reset: nil)
        }
        let primary = snapshot.metrics.filter { $0.kind == .periodic && $0.contributesToSummary }
        let knownPrimary = primary.compactMap { metric -> (metric: QuotaMetric, reset: QuotaReset)? in
            documentedReset(metric).map { (metric, $0) }
        }
        let selected = knownPrimary.min { $0.reset.date < $1.reset.date }
        let primaryDetails = primary.map { metric in
            documentedReset(metric).map { "\(metric.label) · \(resetText($0, now: now, action: "重置"))" }
                ?? "\(metric.label)重置时间未提供"
        }
        let secondaryDetails = snapshot.metrics.filter { $0.kind == .periodic && !$0.contributesToSummary }
            .compactMap { metric -> String? in
                guard let reset = documentedReset(metric) else { return nil }
                let action = snapshot.providerID == "manus" && metric.id == "refresh" ? "刷新" : "重置"
                return "\(metric.label) · \(resetText(reset, now: now, action: action))"
            }
        let details = primaryDetails + secondaryDetails
        let detail = details.isEmpty ? nil : details.joined(separator: "\n")
        guard let selected else {
            let missing = snapshot.providerID == "manus" && primary.contains { $0.id == "monthly" }
                ? "月度重置时间未提供" : "重置时间未提供"
            return Summary(text: missing, detail: detail, metricLabel: nil, reset: nil)
        }
        // This deadline belongs to one documented primary cycle. It does not
        // imply that all simultaneous limits or supplemental pools reset then.
        let label = primary.count > 1 ? captionLabel(selected.metric, providerID: snapshot.providerID) + " · " : ""
        return Summary(text: label + resetText(selected.reset, now: now, action: "重置"),
                       detail: detail, metricLabel: selected.metric.label, reset: selected.reset)
    }

    private static func documentedReset(_ metric: QuotaMetric) -> QuotaReset? {
        guard let reset = metric.reset, reset.date.timeIntervalSince1970.isFinite else { return nil }
        return reset
    }

    private static func captionLabel(_ metric: QuotaMetric, providerID: String) -> String {
        guard providerID == "codex" else { return metric.label }
        return metric.label.components(separatedBy: " · ").last ?? metric.label
    }

    private static func resetText(_ reset: QuotaReset, now: Date, action: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sameYear = calendar.component(.year, from: reset.date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let dayFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        if reset.precision == .day {
            formatter.dateFormat = dayFormat
            let expired = calendar.compare(reset.date, to: now, toGranularity: .day) == .orderedAscending
            let status = expired ? "已到\(action)日期" : action
            return formatter.string(from: reset.date) + status + "（时间未明确）"
        }
        formatter.dateFormat = dayFormat + " HH:mm"
        let status = reset.date <= now ? "已到\(action)时间" : action
        return formatter.string(from: reset.date) + " " + status
    }
}
