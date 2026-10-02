import Foundation

public struct ProviderDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let refreshInterval: TimeInterval

    public init(id: String, name: String, bundleIdentifier: String? = nil,
                refreshInterval: TimeInterval = 300) {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.refreshInterval = max(60, refreshInterval)
    }
}

public struct QuotaReset: Equatable, Sendable {
    public enum Precision: String, Codable, Sendable { case instant, day }
    public let date: Date
    public let precision: Precision

    public init(date: Date, precision: Precision = .instant) {
        self.date = date
        self.precision = precision
    }
}

public struct QuotaMetric: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case periodic, balance }
    public let id: String
    public let label: String
    public let kind: Kind
    private let reportedRemainingPercent: Double?
    public let remaining: Double?
    public let limit: Double?
    public let unit: String?
    public let reset: QuotaReset?
    public let contributesToSummary: Bool

    public init(id: String, label: String, kind: Kind = .periodic,
                remainingPercent: Double? = nil, remaining: Double? = nil,
                limit: Double? = nil, unit: String? = nil, reset: QuotaReset? = nil,
                contributesToSummary: Bool = true) {
        self.id = id
        self.label = label
        self.kind = kind
        self.reportedRemainingPercent = remainingPercent
        self.remaining = remaining
        self.limit = limit
        self.unit = unit
        self.reset = reset
        self.contributesToSummary = contributesToSummary
    }

    public var remainingPercent: Double? {
        if let value = reportedRemainingPercent {
            return value.isFinite ? min(100, max(0, value)) : nil
        }
        guard let remaining, remaining.isFinite, let limit, limit.isFinite, limit > 0 else { return nil }
        let percent = remaining / limit * 100
        return percent.isFinite ? min(100, max(0, percent)) : nil
    }
}

/// Account identity is memory-only and intentionally cannot be encoded into exported quota files.
public struct ProviderSnapshot: Equatable, Sendable {
    public let providerID: String
    public let accountFingerprint: String?
    public let metrics: [QuotaMetric]
    public let observedAt: Date

    public init(providerID: String, accountFingerprint: String? = nil,
                metrics: [QuotaMetric], observedAt: Date = Date()) {
        self.providerID = providerID
        self.accountFingerprint = accountFingerprint
        self.metrics = metrics
        self.observedAt = observedAt
    }

    public var menuBarRemainingPercent: Double? {
        metrics.filter { $0.kind == .periodic && $0.contributesToSummary }
            .compactMap(\.remainingPercent).min()
    }
}
