import Foundation
import XCTest
@testable import QuotaCore

final class ResetIntentTests: XCTestCase {
    private var directory: URL!
    private var journalURL: URL {
        directory.appendingPathComponent("journal/pending-reset.json")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexQuota-ResetIntentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func testRoundTripAndRestartPreserveTheExactAttempt() throws {
        let intent = ResetIntent(accountId: "account-for-test", creditId: "credit-for-test",
                                 idempotencyKey: "stable-key", createdAt: Date(timeIntervalSince1970: 1_700_000_000.125))
        let journal = ResetIntentJournal(fileURL: journalURL)
        XCTAssertNil(try journal.load())
        try journal.save(intent)
        XCTAssertEqual(try journal.load(), intent)
        XCTAssertEqual(try journal.load()?.idempotencyKey, "stable-key")
        XCTAssertEqual(try ResetIntentJournal(fileURL: journalURL).load(), intent)
        // Re-persisting a retry preserves the supplied key rather than generating another.
        try journal.save(intent)
        XCTAssertEqual(try journal.load(), intent)
    }

    func testDefaultInitializerCreatesAUUIDAndTimestamp() {
        let before = Date()
        let intent = ResetIntent(accountId: "account-for-test", creditId: "credit-for-test")
        XCTAssertNotNil(UUID(uuidString: intent.idempotencyKey))
        XCTAssertGreaterThanOrEqual(intent.createdAt, before)
        XCTAssertLessThanOrEqual(intent.createdAt, Date())
        XCTAssertNil(intent.outcome)
    }

    func testConfirmedOutcomePersistsAndPreservesAttemptIdentity() throws {
        let original = ResetIntent(accountId: "account-for-test", creditId: "credit-for-test",
                                   idempotencyKey: "stable-key", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let journal = ResetIntentJournal(fileURL: journalURL)
        for outcome in [ResetCreditOutcome.reset, .alreadyRedeemed, .nothingToReset, .noCredit] {
            let confirmed = original.confirmed(outcome)
            XCTAssertEqual(confirmed.accountId, original.accountId)
            XCTAssertEqual(confirmed.creditId, original.creditId)
            XCTAssertEqual(confirmed.idempotencyKey, original.idempotencyKey)
            XCTAssertEqual(confirmed.createdAt, original.createdAt)
            XCTAssertEqual(confirmed.outcome, outcome)
            try journal.save(confirmed)
            XCTAssertEqual(try ResetIntentJournal(fileURL: journalURL).load(), confirmed)
        }
    }

    func testLegacyPendingIntentDecodesWithoutOutcome() throws {
        let legacy = Data(#"{"accountId":"account-for-test","creditId":"credit-for-test","idempotencyKey":"existing-key","createdAt":123456}"#.utf8)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try legacy.write(to: journalURL)
        let restored = try XCTUnwrap(ResetIntentJournal(fileURL: journalURL).load())
        XCTAssertEqual(restored.idempotencyKey, "existing-key")
        XCTAssertEqual(restored.createdAt, Date(timeIntervalSinceReferenceDate: 123456))
        XCTAssertNil(restored.outcome)
    }

    func testCorruptContentsThrowAndRemainAvailableForRecovery() throws {
        let journal = ResetIntentJournal(fileURL: journalURL)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for invalid in ["{truncated", "{}"] {
            let bytes = Data(invalid.utf8)
            try bytes.write(to: journalURL)
            XCTAssertThrowsError(try journal.load())
            XCTAssertEqual(try Data(contentsOf: journalURL), bytes)
        }
    }

    func testClearIsIdempotentAndRemovesOnlyTheJournal() throws {
        let journal = ResetIntentJournal(fileURL: journalURL)
        try journal.clear()
        try journal.save(ResetIntent(accountId: "account-for-test", creditId: "credit-for-test"))
        let sibling = journalURL.deletingLastPathComponent().appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: sibling)
        try journal.clear()
        XCTAssertNil(try journal.load())
        try journal.clear()
        XCTAssertEqual(try String(contentsOf: sibling), "keep")

        try FileManager.default.createDirectory(at: journalURL, withIntermediateDirectories: false)
        let unexpectedChild = journalURL.appendingPathComponent("preserve.txt")
        try Data("preserve".utf8).write(to: unexpectedChild)
        XCTAssertThrowsError(try journal.clear())
        XCTAssertEqual(try String(contentsOf: unexpectedChild), "preserve")
    }

    func testFileAndDirectoryPermissionsAndNoStagingFiles() throws {
        let journal = ResetIntentJournal(fileURL: journalURL)
        try journal.save(ResetIntent(accountId: "account-for-test", creditId: "credit-for-test"))
        let manager = FileManager.default
        let fileAttributes = try manager.attributesOfItem(atPath: journalURL.path)
        let parent = journalURL.deletingLastPathComponent()
        let directoryAttributes = try manager.attributesOfItem(atPath: parent.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: parent.path), ["pending-reset.json"])
    }

    func testUnusableParentPathFailsInsteadOfPretendingToPersist() throws {
        // A regular file cannot become a journal directory, even if tests run as root.
        let parentFile = directory.appendingPathComponent("blocked-parent")
        try Data("existing-data".utf8).write(to: parentFile)
        let journal = ResetIntentJournal(fileURL: parentFile.appendingPathComponent("pending-reset.json"))
        XCTAssertThrowsError(try journal.save(ResetIntent(accountId: "account-for-test", creditId: "credit-for-test")))
        XCTAssertThrowsError(try journal.load())
        XCTAssertEqual(try String(contentsOf: parentFile), "existing-data")
    }
}
