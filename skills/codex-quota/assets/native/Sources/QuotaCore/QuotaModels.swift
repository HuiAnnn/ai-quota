import Foundation

/// Read-only account usage returned by the local Codex app-server.
public struct QuotaSnapshot: Codable, Equatable, Sendable {
    public let rateLimits: RateLimitBucket?
    public let rateLimitsByLimitId: [String: RateLimitBucket]?
    public let rateLimitResetCredits: ResetCredits?
    public var accountId: String?

    public init(
        rateLimits: RateLimitBucket? = nil,
        rateLimitsByLimitId: [String: RateLimitBucket]? = nil,
        rateLimitResetCredits: ResetCredits? = nil,
        accountId: String? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
        self.rateLimitResetCredits = rateLimitResetCredits
        self.accountId = accountId
    }

    public var orderedBuckets: [QuotaBucketEntry] {
        if let buckets = rateLimitsByLimitId, !buckets.isEmpty {
            return buckets.map { QuotaBucketEntry(id: $0.key, bucket: $0.value) }
                .sorted { lhs, rhs in
                    let left = lhs.id.lowercased()
                    let right = rhs.id.lowercased()
                    if (left == "codex") != (right == "codex") {
                        return left == "codex"
                    }
                    return left == right ? lhs.id < rhs.id : left < right
                }
        }
        guard let rateLimits else { return [] }
        let id = rateLimits.limitId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [QuotaBucketEntry(id: id.flatMap { $0.isEmpty ? nil : $0 } ?? "codex", bucket: rateLimits)]
    }

    /// Spark and other independently limited products never replace the Codex indicator.
    public var menuBarRemainingPercent: Double? {
        guard let codex = orderedBuckets.first(where: { $0.id.lowercased() == "codex" }) else {
            return nil
        }
        return [codex.bucket.primary, codex.bucket.secondary]
            .compactMap { $0?.remainingPercent }
            .min()
    }
}

public struct QuotaBucketEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let bucket: RateLimitBucket

    public init(id: String, bucket: RateLimitBucket) {
        self.id = id
        self.bucket = bucket
    }

    /// The dictionary key identifies a bucket even when its optional metadata is omitted.
    public var displayName: String {
        let explicitID = bucket.limitId?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RateLimitBucket(
            limitId: explicitID.flatMap { $0.isEmpty ? nil : $0 } ?? id,
            limitName: bucket.limitName
        ).displayName
    }
}

public struct RateLimitBucket: Codable, Equatable, Sendable {
    public let limitId: String?
    public let limitName: String?
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?
    public let planType: String?

    public init(
        limitId: String? = nil,
        limitName: String? = nil,
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil,
        planType: String? = nil
    ) {
        self.limitId = limitId
        self.limitName = limitName
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }

    public var displayName: String {
        if let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        guard let id = limitId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return "Codex"
        }
        if id.lowercased() == "codex" { return "Codex" }
        if id.lowercased().contains("spark") { return "Codex Spark" }
        return id
    }
}

public struct RateLimitWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double?
    public let windowDurationMins: Int?
    public let resetsAt: Double?

    public init(
        usedPercent: Double? = nil,
        windowDurationMins: Int? = nil,
        resetsAt: Double? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double? {
        guard let usedPercent, usedPercent.isFinite else { return nil }
        return min(100, max(0, 100 - usedPercent))
    }

    public var periodLabel: String {
        guard let minutes = windowDurationMins, minutes > 0 else { return "额度" }
        if minutes == 10_080 { return "每周额度" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)天额度" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)小时额度" }
        return "\(minutes)分钟额度"
    }

    public var resetDate: Date? {
        Self.date(from: resetsAt)
    }

    fileprivate static func date(from timestamp: Double?) -> Date? {
        guard let timestamp, timestamp.isFinite else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}

public struct ResetCredits: Codable, Equatable, Sendable {
    public let availableCount: Int?
    public let credits: [ResetCredit]?

    public init(availableCount: Int? = nil, credits: [ResetCredit]? = nil) {
        self.availableCount = availableCount
        self.credits = credits
    }

    /// The authoritative total may exceed the number of details returned by the server.
    public var displayCount: Int? {
        guard let availableCount, availableCount >= 0 else { return nil }
        return availableCount
    }

    /// Preserve server order when dates tie, including entries without a date.
    public var sortedCredits: [ResetCredit] {
        (credits ?? []).enumerated().sorted { lhs, rhs in
            switch (lhs.element.expirationDate, rhs.element.expirationDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}

public struct ResetCredit: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let resetType: String?
    public let status: String?
    public let grantedAt: Double?
    public let expiresAt: Double?
    public let title: String?
    public let description: String?

    public init(
        id: String,
        resetType: String? = nil,
        status: String? = nil,
        grantedAt: Double? = nil,
        expiresAt: Double? = nil,
        title: String? = nil,
        description: String? = nil
    ) {
        self.id = id
        self.resetType = resetType
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
        self.description = description
    }

    public var expirationDate: Date? {
        RateLimitWindow.date(from: expiresAt)
    }
}
