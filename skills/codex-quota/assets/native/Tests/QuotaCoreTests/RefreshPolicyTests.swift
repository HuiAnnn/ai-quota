import Foundation
import XCTest
@testable import QuotaCore

final class RefreshPolicyTests: XCTestCase {
    func testOrdinaryPollingAndBoundedFailureBackoff() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(RefreshPolicy.delay(now: now, snapshot: nil, failures: 0), 60)
        XCTAssertEqual(RefreshPolicy.delay(now: now, snapshot: nil, failures: 1), 60)
        XCTAssertEqual(RefreshPolicy.delay(now: now, snapshot: nil, failures: 2), 120)
        XCTAssertEqual(RefreshPolicy.delay(now: now, snapshot: nil, failures: 20), 300)
    }

    func testFutureBoundaryRequestsOnceAndPastBoundaryDoesNotSpin() throws {
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data("""
        {"rateLimits":{"primary":{"usedPercent":9,"resetsAt":1020}}}
        """.utf8))
        XCTAssertEqual(RefreshPolicy.delay(now: Date(timeIntervalSince1970: 1000), snapshot: snapshot, failures: 0), 21)
        XCTAssertEqual(RefreshPolicy.delay(now: Date(timeIntervalSince1970: 1021), snapshot: snapshot, failures: 0), 60)
    }

    func testResetCreditExpiryAlsoRefreshesWithoutInferringUsage() throws {
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data("""
        {"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"test","expiresAt":1010}]}}
        """.utf8))
        XCTAssertEqual(RefreshPolicy.delay(now: Date(timeIntervalSince1970: 1000), snapshot: snapshot, failures: 0), 11)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.displayCount, 2)
    }
}
