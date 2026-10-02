import Foundation

public enum ManusQuotaMapper {
    public static func snapshot(from data: Data, accountFingerprint: String?, observedAt: Date) throws -> ProviderSnapshot {
        let credits: ManusCreditsResponse
        do { credits = try JSONDecoder().decode(ManusCreditsResponse.self, from: data) }
        catch { throw QuotaProviderError.invalidResponse }
        guard credits.hasQuotaFields else { throw QuotaProviderError.invalidResponse }
        let values = [credits.periodicCredits, credits.proMonthlyCredits, credits.freeCredits,
                      credits.addonCredits, credits.eventCredits, credits.refreshCredits, credits.maxRefreshCredits]
        guard values.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw QuotaProviderError.invalidResponse }

        var metrics: [QuotaMetric] = []
        if credits.periodicCredits != nil || credits.proMonthlyCredits != nil {
            metrics.append(QuotaMetric(id: "monthly", label: "每月积分", remaining: Double(credits.periodicCredits ?? 0),
                                       limit: credits.proMonthlyCredits.flatMap { $0 > 0 ? Double($0) : nil }, unit: "积分"))
        }
        if let interval = credits.refreshInterval, !interval.isEmpty {
            guard ["daily", "weekly"].contains(interval) else { throw QuotaProviderError.invalidResponse }
            let reset: QuotaReset?
            if let timestamp = credits.nextRefreshTime {
                guard let date = ManusQuotaDates.timestamp(timestamp) else { throw QuotaProviderError.invalidResponse }
                reset = QuotaReset(date: date)
            } else { reset = nil }
            metrics.append(QuotaMetric(id: "refresh", label: interval == "daily" ? "每日刷新积分" : "每周刷新积分",
                                       remaining: Double(credits.refreshCredits ?? 0),
                                       limit: credits.maxRefreshCredits.flatMap { $0 > 0 ? Double($0) : nil },
                                       unit: "积分", reset: reset, contributesToSummary: false))
        }
        for (id, label, amount) in [("free", "免费积分", credits.freeCredits),
                                    ("addon", "额外购买积分", credits.addonCredits),
                                    ("event", "活动积分", credits.eventCredits)] {
            if let amount {
                metrics.append(QuotaMetric(id: id, label: label, kind: .balance,
                                           remaining: Double(amount), unit: "积分", contributesToSummary: false))
            }
        }
        guard !metrics.isEmpty else { throw QuotaProviderError.invalidResponse }
        return ProviderSnapshot(providerID: "manus", accountFingerprint: accountFingerprint, metrics: metrics, observedAt: observedAt)
    }
}

/// Only the credit fields used by the quota display are decoded. Notices and user flags are ignored.
private struct ManusCreditsResponse: Decodable {
    let periodicCredits: Int32?
    let proMonthlyCredits: Int32?
    let freeCredits: Int32?
    let addonCredits: Int32?
    let eventCredits: Int32?
    let refreshCredits: Int32?
    let maxRefreshCredits: Int32?
    let refreshInterval: String?
    let nextRefreshTime: String?

    var hasQuotaFields: Bool {
        [periodicCredits, proMonthlyCredits, freeCredits, addonCredits, eventCredits,
         refreshCredits, maxRefreshCredits].contains { $0 != nil }
    }
}

internal enum ManusQuotaDates {
    static func timestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
