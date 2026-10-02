import Foundation

enum GrokUsageDecoder {
    static func decode(usage: Data, currentPeriod: Data?) throws -> [QuotaMetric] {
        do {
            let status = try JSONDecoder().decode(UsageStatus.self, from: usage)
            let shared = status.usesPooledEnterpriseAllowance ?? false
            let remaining = shared ? nil : status.usagePercent.map { 100 - max(0, $0) }
            guard status.usagePercent?.isFinite != false else { throw QuotaProviderError.invalidResponse }
            let reset = try status.nextResetTimestampUtc.map { value -> QuotaReset in
                let date = timestamp(value)
                guard let date, date.timeIntervalSince1970 > 0 else { throw QuotaProviderError.invalidResponse }
                return QuotaReset(date: date, precision: .instant)
            }
            var metrics = [QuotaMetric(id: "weekly", label: shared ? "企业共享额度" : "每周", remainingPercent: remaining, reset: reset)]
            if status.hasNonZeroIncludedLimit == true, let currentPeriod,
               let current = try? JSONDecoder().decode(CurrentPeriod.self, from: currentPeriod),
               let spend = current.spendLimitUsage, let limit = spend.individualLimit,
               case let used = spend.individualUsed ?? 0,
               limit.isFinite, used.isFinite, limit > 0, limit < 2_147_483_647, used >= 0 {
                metrics.append(QuotaMetric(id: "on-demand", label: "按量剩余上限", kind: .balance,
                                           remaining: max(0, limit - used) / 100, limit: limit / 100,
                                           unit: "美元", contributesToSummary: false))
            }
            return metrics
        } catch let error as QuotaProviderError { throw error }
        catch { throw QuotaProviderError.invalidResponse }
    }

    private static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private struct UsageStatus: Decodable {
        let usagePercent: Double?
        let nextResetTimestampUtc: String?
        let usesPooledEnterpriseAllowance: Bool?
        let hasNonZeroIncludedLimit: Bool?
    }

    private struct CurrentPeriod: Decodable {
        let spendLimitUsage: SpendLimitUsage?
    }

    private struct SpendLimitUsage: Decodable {
        let individualLimit: Double?
        let individualUsed: Double?
    }
}
