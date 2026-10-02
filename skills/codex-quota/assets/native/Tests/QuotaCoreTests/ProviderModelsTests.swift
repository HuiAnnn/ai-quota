import Foundation
import XCTest
@testable import QuotaCore

final class ProviderModelsTests: XCTestCase {
    // Quota amounts are fictional test inputs, independent of live accounts.
    func testCreditsUseTheirOwnCycleLimitAndExcludeAdditionalBalances() {
        let monthly = QuotaMetric(id: "monthly", label: "每月", remaining: 4000, limit: 10000)
        let extra = QuotaMetric(id: "extra", label: "额外", kind: .balance,
                               remainingPercent: 100, remaining: 1000, contributesToSummary: false)
        let snapshot = ProviderSnapshot(providerID: "manus", metrics: [monthly, extra])
        XCTAssertEqual(snapshot.menuBarRemainingPercent!, 40, accuracy: 0.0001)
    }

    func testMissingOrNonFiniteDenominatorRemainsUnknown() {
        XCTAssertNil(QuotaMetric(id: "credits", label: "积分", remaining: 3000).remainingPercent)
        XCTAssertNil(QuotaMetric(id: "credits", label: "积分", remaining: 30, limit: 0).remainingPercent)
        XCTAssertNil(QuotaMetric(id: "credits", label: "积分", remainingPercent: .infinity).remainingPercent)
    }

    func testSimultaneousLimitsUseSmallestRemainingButClampOveruse() {
        let snapshot = ProviderSnapshot(providerID: "sample", metrics: [
            QuotaMetric(id: "short", label: "短周期", remainingPercent: 12),
            QuotaMetric(id: "week", label: "每周", remainingPercent: 72)
        ])
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 12)
        XCTAssertEqual(QuotaMetric(id: "over", label: "超额", remainingPercent: -2).remainingPercent, 0)
    }

    func testCodexProjectionKeepsSparkOutOfMenuSummary() {
        let original = QuotaSnapshot(rateLimitsByLimitId: [
            "codex": RateLimitBucket(primary: RateLimitWindow(usedPercent: 36, windowDurationMins: 10080)),
            "spark": RateLimitBucket(primary: RateLimitWindow(usedPercent: 99))
        ])
        let projection = ProviderSnapshot.codex(original, observedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(projection.menuBarRemainingPercent, 64)
        XCTAssertEqual(projection.metrics.count, 2)
        XCTAssertEqual(projection.observedAt, Date(timeIntervalSince1970: 100))
    }
}
