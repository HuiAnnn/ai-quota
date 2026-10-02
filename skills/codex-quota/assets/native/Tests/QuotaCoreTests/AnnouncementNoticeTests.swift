import XCTest
@testable import QuotaCore

final class AnnouncementNoticeTests: XCTestCase {
    private let published = ISO8601DateFormatter().date(from: "2026-09-21T16:00:00Z")!
    private func announcement(_ text: String, id: String = "1", kind: String = "regular", offset: TimeInterval = 0, observed: Bool = false) throws -> ResetAnnouncement {
        let row: [String: Any] = ["id": id, "text": text, "reset_type": kind,
            "announced_at": ISO8601DateFormatter().string(from: published.addingTimeInterval(offset)),
            "source": ["type": observed ? "observed" : "x_post", "author": "thsottiaux", "url": "https://x.com/thsottiaux/status/123"]]
        return try XCTUnwrap(ResetAnnouncement.decodeFeed(JSONSerialization.data(withJSONObject: ["data": [row]])).first)
    }
    func testRelativeResetTimesCrossBeijingMidnightWithoutUsingPublicationTime() throws {
        let item = try announcement("We will reset usage limits in the next hour.")
        let timing = try XCTUnwrap(item.resetTiming)
        XCTAssertEqual(timing.date, published.addingTimeInterval(3600))
        XCTAssertTrue(timing.isDeadline)
        XCTAssertEqual(timing.beijingText, "预计 9月22日 01:00 前（北京时间）")
        let banked = try announcement("We will give one banked reset. First one will land in ~ 3 hours.", kind: "banked")
        XCTAssertEqual(banked.resetTiming?.beijingText, "预计 9月22日 03:00 左右（北京时间）")
    }
    func testExplicitPacificTimeUsesDaylightSavingAndDoesNotStealUpgradeDeadline() throws {
        let item = try announcement("We will reset usage limits tomorrow at 8pm PT.")
        XCTAssertEqual(item.resetTiming?.beijingText, "预计 9月23日 11:00（北京时间）")
        let winter = try announcement("We will reset usage limits tomorrow at 8pm PST.")
        XCTAssertEqual(winter.resetTiming?.beijingText, "预计 9月23日 12:00（北京时间）")
        let noTimezone = try announcement("We will reset usage limits by midnight today.")
        XCTAssertNil(noTimezone.resetTiming)
        let cutoff = try announcement("We will do a banked reset today. If you upgrade before 8pm PT you will get it too.", kind: "banked")
        XCTAssertNil(cutoff.resetTiming)
    }
    func testUnrelatedNegationDoesNotHideDefiniteResetPromise() throws {
        let item = try announcement("We will give one banked reset. First one will land in ~ 3 hours. If you don't have an account, there is still time.", kind: "banked")
        XCTAssertEqual(item.phase, .upcoming)
        XCTAssertNotNil(item.resetTiming)
        let maybe = try announcement("We might reset usage in one hour.")
        XCTAssertTrue(AnnouncementNotice.active(in: [maybe], now: published).isEmpty)
    }
    func testOldObservedAndSupersededAnnouncementsNeverBecomeUpcomingBanners() throws {
        let plan = try announcement("We will reset usage limits in the next hour.")
        XCTAssertEqual(AnnouncementNotice.active(in: [plan], now: published).count, 1)
        XCTAssertEqual(AnnouncementNotice.active(in: [plan], now: published.addingTimeInterval(3601)).first?.isOverdue, true)
        XCTAssertTrue(AnnouncementNotice.active(in: [plan], now: published.addingTimeInterval(86401)).isEmpty)
        let complete = try announcement("We have reset usage limits.", id: "2", offset: 1800)
        XCTAssertTrue(AnnouncementNotice.active(in: [plan, complete], now: published.addingTimeInterval(2000)).isEmpty)
        let canceled = try announcement("The reset is delayed.", id: "3", offset: 1800)
        XCTAssertTrue(AnnouncementNotice.active(in: [plan, canceled], now: published.addingTimeInterval(2000)).isEmpty)
        let observed = try announcement("We will reset usage limits in the next hour.", observed: true)
        XCTAssertTrue(AnnouncementNotice.active(in: [observed], now: published).isEmpty)
    }
    func testSeparateKindsAndExpiryOfTimeUnknownPromises() throws {
        let regular = try announcement("We will reset usage limits tonight.")
        let banked = try announcement("We will give a banked reset tomorrow.", id: "2", kind: "banked", offset: 30)
        XCTAssertEqual(AnnouncementNotice.active(in: [regular,banked], now: published.addingTimeInterval(60)).count, 2)
        XCTAssertNil(regular.resetTiming)
        XCTAssertTrue(AnnouncementNotice.active(in: [regular], now: published.addingTimeInterval(86401)).isEmpty)
    }
    func testAlternativesEligibilityAndContradictionsCannotProducePrecisePromises() throws {
        let alternatives = try announcement("We will reset usage limits in 1 hour or in 3 hours.")
        XCTAssertNil(alternatives.resetTiming)
        let eligibility = try announcement("We will reset usage limits tomorrow, and you can upgrade before 8pm PT today to qualify.")
        XCTAssertNil(eligibility.resetTiming)
        let contradiction = try announcement("We will reset usage limits in one hour. Actually, we won't reset usage limits today.")
        XCTAssertTrue(AnnouncementNotice.active(in: [contradiction], now: published).isEmpty)
        let conditional = try announcement("We will reset usage limits in one hour if capacity allows.")
        XCTAssertTrue(AnnouncementNotice.active(in: [conditional], now: published).isEmpty)
    }
}
