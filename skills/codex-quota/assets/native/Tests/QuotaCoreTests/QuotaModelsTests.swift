import Foundation
import XCTest
@testable import QuotaCore

final class QuotaModelsTests: XCTestCase {
    func testWeeklyPrimaryAndTwoSparkWindowsDecodeWithoutAssumingFiveHours() throws {
        let snapshot = try decode(#"""
        {
          "rateLimits": { "primary": { "usedPercent": 99 } },
          "rateLimitsByLimitId": {
            "codex_spark": {
              "limitId": "codex_spark", "limitName": "Codex Spark",
              "primary": { "usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1788595200 },
              "secondary": { "usedPercent": 30, "windowDurationMins": 10080, "resetsAt": 1789200000 }
            },
            "codex": {
              "limitId": "codex", "planType": "pro",
              "primary": { "usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1789200000 },
              "secondary": null
            }
          },
          "rateLimitResetCredits": {
            "availableCount": 3,
            "credits": [{ "id": "credit-1", "expiresAt": 1790000000, "futureField": true }]
          },
          "futureBackendField": { "ignored": true }
        }
        """#)

        XCTAssertEqual(snapshot.orderedBuckets.map(\.id), ["codex", "codex_spark"])
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 60)
        XCTAssertEqual(snapshot.orderedBuckets[0].bucket.primary?.periodLabel, "每周额度")
        XCTAssertNil(snapshot.orderedBuckets[0].bucket.secondary)
        XCTAssertEqual(snapshot.orderedBuckets[1].bucket.primary?.periodLabel, "5小时额度")
        XCTAssertEqual(snapshot.rateLimitResetCredits?.displayCount, 3)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.sortedCredits.count, 1)
        XCTAssertEqual(snapshot.orderedBuckets[0].bucket.primary?.resetDate?.timeIntervalSince1970, 1_789_200_000)
    }

    func testLegacyFallbackAndEmptyDictionary() throws {
        for dictionary in ["null", "{}"] {
            let snapshot = try decode("""
            {"rateLimitsByLimitId": \(dictionary), "rateLimits": {
              "primary": {"usedPercent": 10}, "secondary": {"usedPercent": 70}
            }}
            """)
            XCTAssertEqual(snapshot.orderedBuckets.map(\.id), ["codex"])
            XCTAssertEqual(snapshot.menuBarRemainingPercent, 30)
        }
    }

    func testOtherProductsNeverSupplyMenuValue() {
        let spark = RateLimitBucket(limitId: "codex_spark", primary: .init(usedPercent: 50))
        XCTAssertNil(QuotaSnapshot(rateLimits: spark).menuBarRemainingPercent)
        let snapshot = QuotaSnapshot(
            rateLimits: .init(primary: .init(usedPercent: 0)),
            rateLimitsByLimitId: ["codex_spark": spark]
        )
        XCTAssertEqual(snapshot.orderedBuckets.map(\.id), ["codex_spark"])
        XCTAssertNil(snapshot.menuBarRemainingPercent)
    }

    func testEmptyAndNullFieldsStayUnknown() throws {
        for json in ["{}", #"{"rateLimits":null,"rateLimitsByLimitId":null,"rateLimitResetCredits":null,"accountId":null}"#] {
            let snapshot = try decode(json)
            XCTAssertTrue(snapshot.orderedBuckets.isEmpty)
            XCTAssertNil(snapshot.menuBarRemainingPercent)
            XCTAssertNil(snapshot.rateLimitResetCredits)
        }
        let snapshot = try decode(#"{"rateLimits":{"primary":{}},"rateLimitResetCredits":{"credits":[{"id":"unknown"}]}}"#)
        XCTAssertNil(snapshot.menuBarRemainingPercent)
        XCTAssertNil(snapshot.rateLimits?.primary?.resetDate)
        XCTAssertNil(snapshot.rateLimitResetCredits?.displayCount)
        XCTAssertNil(snapshot.rateLimitResetCredits?.sortedCredits.first?.expirationDate)
    }

    func testPercentBoundsAndInvalidValues() {
        let cases: [(Double, Double)] = [(0, 100), (100, 0), (40.5, 59.5), (-20, 100), (120, 0)]
        for (used, expected) in cases {
            XCTAssertEqual(RateLimitWindow(usedPercent: used).remainingPercent, expected)
        }
        for used in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(RateLimitWindow(usedPercent: used).remainingPercent)
        }
        XCTAssertNil(RateLimitWindow().remainingPercent)
        let partial = QuotaSnapshot(rateLimits: .init(primary: .init(), secondary: .init(usedPercent: 42)))
        XCTAssertEqual(partial.menuBarRemainingPercent, 58)
    }

    func testDurationsUseActualWindowLength() {
        let cases: [(Int?, String)] = [
            (nil, "额度"), (0, "额度"), (-1, "额度"), (15, "15分钟额度"),
            (90, "90分钟额度"), (60, "1小时额度"), (300, "5小时额度"),
            (1440, "1天额度"), (2880, "2天额度"), (10080, "每周额度")
        ]
        for (minutes, label) in cases {
            XCTAssertEqual(RateLimitWindow(windowDurationMins: minutes).periodLabel, label)
        }
    }

    func testPastResetDoesNotInventRefreshedUsage() {
        let window = RateLimitWindow(usedPercent: 100, resetsAt: 1)
        XCTAssertEqual(window.remainingPercent, 0)
        XCTAssertEqual(window.resetDate, Date(timeIntervalSince1970: 1))
        XCTAssertNil(RateLimitWindow(resetsAt: .infinity).resetDate)
        XCTAssertNil(ResetCredit(id: "bad-date", expiresAt: .nan).expirationDate)
    }

    func testAvailableCountNeverComesFromDetailLength() {
        XCTAssertEqual(ResetCredits(availableCount: 0).displayCount, 0)
        XCTAssertEqual(ResetCredits(availableCount: 5, credits: []).displayCount, 5)
        XCTAssertNil(ResetCredits(credits: [.init(id: "only-detail")]).displayCount)
        XCTAssertNil(ResetCredits(availableCount: -1).displayCount)
    }

    func testCreditOrderingKeepsTiesStableAndMissingExpiryLast() {
        let credits = ResetCredits(credits: [
            .init(id: "unknown-1"),
            .init(id: "late", expiresAt: 200),
            .init(id: "early-1", expiresAt: 100),
            .init(id: "early-2", expiresAt: 100),
            .init(id: "unknown-2", expiresAt: .infinity)
        ])
        XCTAssertEqual(credits.sortedCredits.map(\.id), ["early-1", "early-2", "late", "unknown-1", "unknown-2"])
    }

    func testBucketOrderingAndDisplayNames() {
        let snapshot = QuotaSnapshot(rateLimitsByLimitId: [
            "zeta": .init(), "Alpha": .init(), "codex": .init(), "alpha": .init()
        ])
        XCTAssertEqual(snapshot.orderedBuckets.map(\.id), ["codex", "Alpha", "alpha", "zeta"])
        XCTAssertEqual(RateLimitBucket().displayName, "Codex")
        XCTAssertEqual(RateLimitBucket(limitId: "codex_spark").displayName, "Codex Spark")
        XCTAssertEqual(RateLimitBucket(limitId: "custom", limitName: " Custom product ").displayName, "Custom product")
        XCTAssertEqual(RateLimitBucket(limitId: "custom", limitName: " ").displayName, "custom")
    }

    func testCodableRoundTrip() throws {
        let snapshot = QuotaSnapshot(
            rateLimits: .init(limitId: "codex", primary: .init(usedPercent: 17.5, windowDurationMins: 10080, resetsAt: 1_789_200_000)),
            rateLimitResetCredits: .init(availableCount: 1, credits: [.init(id: "credit", resetType: "full", status: "available", grantedAt: 100, expiresAt: 200, title: "完全重置", description: "说明")]),
            accountId: "account"
        )
        XCTAssertEqual(try JSONDecoder().decode(QuotaSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testDictionaryIdentitySuppliesMissingDisplayMetadata() throws {
        let snapshot = try decode(#"{"rateLimitsByLimitId":{"codex_spark":{"primary":{"usedPercent":20}},"codex":{}}}"#)
        XCTAssertEqual(snapshot.orderedBuckets.map(\.displayName), ["Codex", "Codex Spark"])
        XCTAssertEqual(QuotaBucketEntry(id: "codex_spark", bucket: .init(limitName: "Server title")).displayName, "Server title")
        XCTAssertEqual(QuotaBucketEntry(id: "key", bucket: .init(limitId: "server-id")).displayName, "server-id")
        XCTAssertEqual(QuotaBucketEntry(id: "codex_spark", bucket: .init(limitId: " ", limitName: " ")).displayName, "Codex Spark")
        XCTAssertEqual(QuotaBucketEntry(id: "future-product", bucket: .init()).displayName, "future-product")
    }

    private func decode(_ json: String) throws -> QuotaSnapshot {
        try JSONDecoder().decode(QuotaSnapshot.self, from: Data(json.utf8))
    }
}
