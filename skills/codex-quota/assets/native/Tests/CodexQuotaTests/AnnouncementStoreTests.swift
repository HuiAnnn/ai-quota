import XCTest
import QuotaCore
@testable import CodexQuota

@MainActor
final class AnnouncementStoreTests: XCTestCase {
    private func sample() throws -> [ResetAnnouncement] {
        try ResetAnnouncement.decodeFeed(Data(#"{"data":[{"id":"123","reset_type":"regular","announced_at":"2026-09-12T08:09:17Z","text":"Reset all propagated.","source":{"type":"x_post","author":"thsottiaux","url":"https://x.com/thsottiaux/status/123"}}]}"#.utf8))
    }
    func testFailedRefreshRetainsLastSuccessAndSurvivesRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("announcements.json")
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let loader = FeedSequence(items: try sample())
        let store = AnnouncementStore(cacheURL: cache, start: false, now: { now }, loader: { try await loader.fetch() })
        await store.refresh()
        XCTAssertEqual(store.items.map(\.id), ["123"])
        XCTAssertEqual(store.updatedAt, now)
        let successfulTime = now
        now.addTimeInterval(601)
        await store.refresh()
        XCTAssertEqual(store.items.map(\.id), ["123"])
        XCTAssertEqual(store.updatedAt, successfulTime)
        XCTAssertNotNil(store.errorMessage)
        let restored = AnnouncementStore(cacheURL: cache, start: false, now: { now }, loader: { throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(restored.items.map(\.id), ["123"])
        XCTAssertEqual(restored.updatedAt, successfulTime)
    }
    func testPollingAndManualRefreshAreThrottledWithoutHidingErrors() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let loader = FeedSequence(items: try sample())
        let store = AnnouncementStore(cacheURL: nil, start: false, now: { now }, loader: { try await loader.fetch() })
        await store.refresh()
        now.addTimeInterval(30)
        await store.refresh(force: true)
        XCTAssertNil(store.errorMessage)
        now.addTimeInterval(31)
        await store.refresh()
        XCTAssertNil(store.errorMessage)
        await store.refresh(force: true)
        XCTAssertNotNil(store.errorMessage)
        let count = await loader.count
        XCTAssertEqual(count, 2)
    }
    func testCorruptCacheAndStoppedStoreDoNotProduceAnnouncements() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not json".utf8).write(to: file)
        let loader = FeedSequence(items: try sample())
        let store = AnnouncementStore(cacheURL: file, start: false, loader: { try await loader.fetch() })
        XCTAssertTrue(store.items.isEmpty)
        store.shutdown()
        await store.refresh(force: true)
        XCTAssertTrue(store.items.isEmpty)
        let count = await loader.count
        XCTAssertEqual(count, 0)
    }
}

private actor FeedSequence {
    var count = 0
    let items: [ResetAnnouncement]
    init(items: [ResetAnnouncement]) { self.items = items }
    func fetch() throws -> [ResetAnnouncement] {
        count += 1
        if count > 1 { throw URLError(.notConnectedToInternet) }
        return items
    }
}
