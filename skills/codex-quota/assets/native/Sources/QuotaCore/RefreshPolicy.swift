import Foundation

/// All countdowns are local. Network reads run at most once per interval, or once
/// when a newly observed future reset/expiry is reached.
public enum RefreshPolicy {
    public static func delay(now: Date, snapshot: QuotaSnapshot?, failures: Int) -> TimeInterval {
        if failures > 0 {
            return min(300, 60 * pow(2, Double(min(failures - 1, 3))))
        }
        let resetDates = snapshot?.orderedBuckets.flatMap { entry in
            [entry.bucket.primary?.resetDate, entry.bucket.secondary?.resetDate].compactMap { $0 }
        } ?? []
        let expirationDates = snapshot?.rateLimitResetCredits?.credits?.compactMap(\.expirationDate) ?? []
        let nextEvent = (resetDates + expirationDates)
            .map { $0.timeIntervalSince(now) }
            .filter { $0 > 0 }
            .min()
        // One extra second lets the backend cross the boundary before querying.
        return min(60, max(1, (nextEvent ?? 59) + 1))
    }
}
