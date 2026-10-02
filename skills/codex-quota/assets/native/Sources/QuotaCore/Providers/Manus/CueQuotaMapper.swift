import Foundation

public enum CueQuotaMapper {
    public static func snapshot(from data: Data, accountFingerprint: String?, observedAt: Date) throws -> ProviderSnapshot {
        let credits: CueMembershipResponse
        do { credits = try JSONDecoder().decode(CueMembershipResponse.self, from: data) }
        catch { throw QuotaProviderError.invalidResponse }
        guard let membership = credits.membership else { throw QuotaProviderError.invalidResponse }
        guard membership.accessAllowed == true else { throw QuotaProviderError.authenticationRequired }
        guard let limit = credits.limitCredits?.value, limit > 0,
              let start = credits.windowStartMs?.value, let end = credits.windowEndMs?.value,
              start > 0, Double(start) <= observedAt.timeIntervalSince1970 * 1000,
              Double(end) > observedAt.timeIntervalSince1970 * 1000, end > start,
              end <= 8_640_000_000_000_000 else { throw QuotaProviderError.invalidResponse }
        if let validUntil = membership.validUntilMs?.value, validUntil > 0,
           Double(validUntil) <= observedAt.timeIntervalSince1970 * 1000 {
            throw QuotaProviderError.invalidResponse
        }
        let used = credits.usedCredits?.value ?? 0
        let reserved = credits.reservedCredits?.value ?? 0
        let purchased = credits.purchasedRemainingCredits?.value ?? 0
        let weekly = credits.weeklyRemainingCredits?.value
        guard [used, reserved, purchased, weekly ?? 0].allSatisfy({ $0 >= 0 }),
              [limit, used, reserved, purchased, weekly ?? 0].allSatisfy({ $0 <= 9_007_199_254_740_991 })
        else { throw QuotaProviderError.invalidResponse }
        let available = max(0, Double(limit) - Double(used) - Double(reserved))
        let remainingPercent = max(0, min(100, 100 * (1 - (Double(used) + Double(reserved)) / Double(limit))))
        var metrics = [QuotaMetric(id: "weekly", label: "每周额度", remainingPercent: remainingPercent,
                                   remaining: weekly.map(Double.init) ?? available, limit: Double(limit), unit: "积分",
                                   reset: QuotaReset(date: Date(timeIntervalSince1970: Double(end) / 1000)))]
        if purchased > 0 {
            metrics.append(QuotaMetric(id: "purchased", label: "额外购买积分", kind: .balance,
                                       remaining: Double(purchased), unit: "积分", contributesToSummary: false))
        }
        return ProviderSnapshot(providerID: "cue", accountFingerprint: accountFingerprint, metrics: metrics, observedAt: observedAt)
    }
}

private struct CueMembershipResponse: Decodable {
    struct Membership: Decodable {
        let accessAllowed: Bool?
        let validUntilMs: CueInt64?
    }
    let membership: Membership?
    let windowStartMs: CueInt64?
    let windowEndMs: CueInt64?
    let limitCredits: CueInt64?
    let usedCredits: CueInt64?
    let reservedCredits: CueInt64?
    let weeklyRemainingCredits: CueInt64?
    let purchasedRemainingCredits: CueInt64?
}

/// Protobuf JSON encodes int64 as decimal strings, while accepting integer JSON numbers.
private struct CueInt64: Decodable {
    let value: Int64
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let value = Int64(string) {
            self.value = value
        } else { value = try container.decode(Int64.self) }
    }
}
