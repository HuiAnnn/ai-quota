import XCTest
@testable import QuotaCore

final class ResetAnnouncementTests: XCTestCase {
    private func row(_ id: String, text: String = "Reset all propagated. Sweet dreams.", type: String = "regular", source: String = "x_post", date: String = "2026-09-12T08:09:17.000Z", url: String? = nil) -> [String: Any] {
        ["id": id, "text": text, "reset_type": type, "announced_at": date,
         "source": ["type": source, "author": "thsottiaux", "url": url ?? "https://x.com/thsottiaux/status/2098685367058612394"]]
    }
    private func feed(_ rows: [[String: Any]]) throws -> [ResetAnnouncement] {
        try ResetAnnouncement.decodeFeed(JSONSerialization.data(withJSONObject: ["data": rows, "pagination": ["has_more": false], "meta": ["api_version": "v1"]]))
    }
    func testRealSchemaSortsDeduplicatesAndRejectsUntrustedLinks() throws {
        let rows = try feed([
            row("old",date:"2026-09-03T23:12:09Z"), row("new"), row("new"),
            row("evil",url:"https://x.com.evil.example/thsottiaux/status/123"),
            row("other",url:"https://x.com/someone/status/123"),
            row("bad-date",date:"tomorrow")
        ])
        XCTAssertEqual(rows.map(\.id), ["new", "old"])
        XCTAssertEqual(rows.first?.phase, .announcedComplete)
        XCTAssertEqual(rows.first?.date.timeIntervalSince1970, 1789200557)
    }
    func testFutureAndNegatedResetsAreNeverCompleted() throws {
        let cases: [(String, AnnouncementPhase)] = [
            ("We will reset usage limits tonight.", .upcoming),
            ("A reset is landing by midnight today.", .upcoming),
            ("We have not reset usage limits.", .unconfirmed),
            ("We haven't reset usage limits.", .unconfirmed),
            ("Don't just reset Codex rate limits for fun.", .unconfirmed),
            ("Tomorrow? Maybe a reset.", .unconfirmed),
            ("We would have reset usage limits if capacity allowed.", .unconfirmed),
            ("We have added better reset documentation.", .unconfirmed),
            ("By tomorrow we will have reset all Codex usage limits.", .upcoming),
            ("Once we have reset limits, I'll post an update.", .unconfirmed),
            ("I have reset usage limits for Codex.", .announcedComplete),
            ("Hi. It is done.", .unconfirmed)
        ]
        for (text, phase) in cases {
            XCTAssertEqual(try feed([row("one",text:text)]).first?.phase, phase, text)
        }
    }
    func testBankedCreditsAndObservationsStayDistinct() throws {
        let banked = try XCTUnwrap(feed([row("b",text:"We will give one banked reset. First one will land in ~ 3 hours.",type:"banked")]).first)
        XCTAssertEqual(banked.kind, .banked)
        XCTAssertEqual(banked.phase, .upcoming)
        XCTAssertEqual(try feed([row("o",source:"observed")]).first?.phase, .observed)
    }
    func testInvalidPayloadDoesNotMasqueradeAsEmptyFeed() throws {
        XCTAssertThrowsError(try ResetAnnouncement.decodeFeed(Data("{}".utf8)))
        XCTAssertThrowsError(try feed([row("bad",url:"javascript:alert(1)")]))
        XCTAssertEqual(try feed([]).count, 0)
        XCTAssertEqual(try feed((0..<25).map { row(String($0)) }).count, 10)
    }
}
