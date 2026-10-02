import Foundation

public enum MuseQuotaDecoder {
    public static func decode(_ data: Data, accountFingerprint: String? = nil,
                              observedAt: Date = Date()) throws -> ProviderSnapshot {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw QuotaProviderError.invalidResponse }
        let response: MuseSubscriptionResponse
        do { response = try JSONDecoder().decode(MuseSubscriptionResponse.self, from: data) }
        catch { throw QuotaProviderError.invalidResponse }
        for value in [response.usage.percentUsed, response.topupBalance, response.topupTotal].compactMap({ $0 }) {
            guard value.isFinite, value >= 0 else { throw QuotaProviderError.invalidResponse }
        }
        let remainingPercent = response.usage.state == "METERED"
            ? response.usage.percentUsed.map { 100 - min(100, $0) } : nil
        var metrics = [QuotaMetric(
            id: "weekly", label: nonempty(response.usageRowLabel) ?? "每周额度",
            remainingPercent: remainingPercent, reset: reset(response.usage.resetsAt)
        )]
        if response.topupBalance != nil || response.topupTotal.map({ $0 > 0 }) == true {
            metrics.append(QuotaMetric(
                id: "additional", label: nonempty(response.topupRowLabel) ?? "额外词元", kind: .balance,
                remaining: response.topupBalance, limit: response.topupTotal,
                unit: "词元", contributesToSummary: false
            ))
        }
        return ProviderSnapshot(providerID: "muse", accountFingerprint: accountFingerprint,
                                metrics: metrics, observedAt: observedAt)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func reset(_ value: MuseResetValue?) -> QuotaReset? {
        guard case let .string(raw)? = value else { return nil }
        if raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let date = formatter.date(from: raw) else { return nil }
            return QuotaReset(date: date, precision: .day)
        }
        // A number has no verified wire unit. A timestamp without an offset has
        // no verified timezone. Neither is turned into an invented reset time.
        guard raw.range(of: #"T.*(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: raw)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: raw) else { return nil }
        return QuotaReset(date: date, precision: .instant)
    }
}

// Only quota fields from Muse's public mapSubscription contract are decoded.
// Agreement, payment data, and credentials never enter a ProviderSnapshot.
private struct MuseSubscriptionResponse: Decodable {
    let usage: MuseUsageResponse
    let usageRowLabel: String?
    let topupBalance: Double?
    let topupTotal: Double?
    let topupRowLabel: String?

    enum CodingKeys: String, CodingKey {
        case usage
        case usageRowLabel = "usage_row_label"
        case topupBalance = "topup_balance"
        case topupTotal = "topup_total"
        case topupRowLabel = "topup_row_label"
    }
}

private struct MuseUsageResponse: Decodable {
    let state: String
    let percentUsed: Double?
    let resetsAt: MuseResetValue?

    enum CodingKeys: String, CodingKey {
        case state
        case percentUsed = "percent_used"
        case resetsAt = "resets_at"
    }
}

private enum MuseResetValue: Decodable {
    case string(String)
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        self = (try? value.decode(String.self)).map(Self.string) ?? .unknown
    }
}
