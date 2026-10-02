import Foundation

public extension ProviderSnapshot {
    static func codex(_ snapshot: QuotaSnapshot, observedAt: Date) -> ProviderSnapshot {
        let metrics = snapshot.orderedBuckets.flatMap { entry in
            [entry.bucket.primary, entry.bucket.secondary].enumerated().compactMap { index, window -> QuotaMetric? in
                guard let window else { return nil }
                return QuotaMetric(id: "\(entry.id)-\(index)",
                                   label: "\(entry.displayName) · \(window.periodLabel)",
                                   remainingPercent: window.remainingPercent,
                                   reset: window.resetDate.map { QuotaReset(date: $0) },
                                   contributesToSummary: entry.id.lowercased() == "codex")
            }
        }
        return ProviderSnapshot(providerID: "codex", accountFingerprint: snapshot.accountId,
                                metrics: metrics, observedAt: observedAt)
    }
}
