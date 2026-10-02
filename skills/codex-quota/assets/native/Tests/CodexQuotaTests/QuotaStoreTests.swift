import Foundation
import XCTest
import QuotaCore
@testable import CodexQuota

@MainActor
final class QuotaStoreTests: XCTestCase {
    private func sample(account: String = "test-account", credits: Bool = true, used: Double = 50) -> QuotaSnapshot {
        QuotaSnapshot(rateLimits: RateLimitBucket(limitId: "codex", primary: RateLimitWindow(usedPercent: used)),
            rateLimitResetCredits: ResetCredits(availableCount: credits ? 1 : 0, credits: credits ? [
                ResetCredit(id: "selected-credit", resetType: "codexRateLimits", status: "available", expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970)
            ] : []), accountId: account)
    }

    private func journal() throws -> (ResetIntentJournal, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quota-store-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (ResetIntentJournal(fileURL: directory.appendingPathComponent("pending.json")), directory)
    }

    func testClickResetsSelectedCreditOnceAndRefreshesAfterSuccess() async throws {
        let before = sample()
        let after = sample(credits: false, used: 0)
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeQuotaService(reads: [.success(before), .success(after)], outcomes: [.success(.reset)])
        let store = QuotaStore(snapshot: before, updatedAt: Date(), start: false, service: service, journal: journal)
        let credit = try XCTUnwrap(before.rateLimitResetCredits?.credits?.first)
        let operation = try XCTUnwrap(store.resetCredit(credit))
        XCTAssertTrue(store.isResetting)
        XCTAssertNil(store.resetCredit(credit), "Repeated clicks must not submit another operation")
        await operation.value
        let calls = await service.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.credit, credit.id)
        XCTAssertEqual(calls.first?.account, before.accountId)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(calls.first?.key)))
        XCTAssertEqual(store.snapshot, after)
        XCTAssertEqual(store.resetMessage, "额度已重置。")
        XCTAssertNil(try journal.load())
        XCTAssertFalse(store.hasPendingReset)
        await store.shutdown()
    }

    func testUnknownOutcomeSurvivesRestartAndRetryKeepsExactlySameKey() async throws {
        let before = sample()
        let after = sample(credits: false, used: 0)
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstService = FakeQuotaService(reads: [.success(before)], outcomes: [.failure(.requestTimedOut)])
        let first = QuotaStore(snapshot: before, start: false, service: firstService, journal: journal)
        await first.resetCredit(try XCTUnwrap(before.rateLimitResetCredits?.credits?.first))?.value
        let saved = try XCTUnwrap(journal.load())
        XCTAssertTrue(first.hasPendingReset)
        XCTAssertEqual(first.resetAlert?.canRetry, true)
        await first.shutdown()

        // The selected credit can disappear because the first request succeeded.
        let retryService = FakeQuotaService(reads: [.success(after), .success(after)], outcomes: [.success(.alreadyRedeemed)])
        let restarted = QuotaStore(snapshot: after, start: false, service: retryService, journal: journal)
        await restarted.retryPendingReset()?.value
        let retryCalls = await retryService.calls
        XCTAssertEqual(retryCalls.count, 1)
        XCTAssertEqual(retryCalls.first?.key, saved.idempotencyKey)
        XCTAssertEqual(retryCalls.first?.credit, saved.creditId)
        XCTAssertNil(try journal.load())
        XCTAssertEqual(restarted.resetMessage, "额度已重置。")
        await restarted.shutdown()
    }

    func testAccountSwitchBeforeClickCannotResetAnotherAccount() async throws {
        let before = sample()
        let changed = sample(account: "different-account")
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeQuotaService(reads: [.success(changed)], outcomes: [])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        await store.resetCredit(try XCTUnwrap(before.rateLimitResetCredits?.credits?.first))?.value
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(try journal.load())
        XCTAssertNotNil(store.resetAlert)
        await store.shutdown()
    }

    func testConsumedOpportunityFoundDuringPreflightDoesNotSubmit() async throws {
        let before = sample()
        let unavailable = sample(credits: false)
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeQuotaService(reads: [.success(unavailable)], outcomes: [])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        await store.resetCredit(try XCTUnwrap(before.rateLimitResetCredits?.credits?.first))?.value
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.snapshot, unavailable)
        XCTAssertNil(try journal.load())
        await store.shutdown()
    }

    func testSuccessfulResetWithReadFailureRemainsConfirmed() async throws {
        let before = sample()
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeQuotaService(reads: [.success(before), .failure(.connectionClosed)], outcomes: [.success(.reset)])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        let credit = try XCTUnwrap(before.rateLimitResetCredits?.credits?.first)
        await store.resetCredit(credit)?.value
        XCTAssertEqual(store.resetMessage, "额度已重置。")
        XCTAssertNil(try journal.load())
        XCTAssertFalse(store.hasPendingReset)
        XCTAssertEqual(store.resetAlert?.canRetry, false)
        XCTAssertFalse(store.canReset(credit, now: Date()))
        await store.shutdown()
    }

    func testNonConsumingOutcomesClearIntentAndSync() async throws {
        for outcome in [ResetCreditOutcome.nothingToReset, .noCredit] {
            let before = sample()
            let (journal, directory) = try journal()
            defer { try? FileManager.default.removeItem(at: directory) }
            let service = FakeQuotaService(reads: [.success(before), .success(before)], outcomes: [.success(outcome)])
            let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
            await store.resetCredit(try XCTUnwrap(before.rateLimitResetCredits?.credits?.first))?.value
            XCTAssertNil(try journal.load())
            XCTAssertNil(store.resetAlert)
            XCTAssertNotEqual(store.resetMessage, "额度已重置。")
            await store.shutdown()
        }
    }

    func testCorruptRecoveryRecordDisablesReset() async throws {
        let before = sample()
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("invalid-record".utf8).write(to: directory.appendingPathComponent("pending.json"))
        let service = FakeQuotaService(reads: [], outcomes: [])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        let credit = try XCTUnwrap(before.rateLimitResetCredits?.credits?.first)
        XCTAssertFalse(store.canReset(credit, now: Date()))
        XCTAssertNil(store.resetCredit(credit))
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
        await store.shutdown()
    }

    func testConfirmedOutcomeWithCleanupFailureNeverConsumesAgainAfterRestart() async throws {
        let before = sample()
        let journal = FailFirstClearJournal()
        let service = FakeQuotaService(reads: [.success(before), .success(before)], outcomes: [.success(.nothingToReset)])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        await store.resetCredit(try XCTUnwrap(before.rateLimitResetCredits?.credits?.first))?.value
        XCTAssertEqual(try journal.load()?.outcome, .nothingToReset)
        XCTAssertEqual(store.pendingResetActionTitle, "完成上次操作")
        await store.shutdown()

        let restartedService = FakeQuotaService(reads: [.failure(.connectionClosed)], outcomes: [])
        let restarted = QuotaStore(snapshot: before, start: false, service: restartedService, journal: journal)
        await restarted.retryPendingReset()?.value
        let calls = await restartedService.calls
        XCTAssertTrue(calls.isEmpty, "A confirmed terminal outcome must never resend consume")
        XCTAssertNil(try journal.load())
        XCTAssertEqual(restarted.resetMessage, "当前没有需要重置的额度，未使用重置机会。")
        XCTAssertFalse(restarted.hasPendingReset)
        await restarted.shutdown()
    }

    func testExpiredOpportunityCannotBeSubmitted() async throws {
        let before = sample()
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeQuotaService(reads: [], outcomes: [])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        let credit = try XCTUnwrap(before.rateLimitResetCredits?.credits?.first)
        XCTAssertFalse(store.canReset(credit, now: Date().addingTimeInterval(7200)))
        await store.shutdown()
    }

    func testFailedIntentPersistenceNeverSendsConsume() async throws {
        let before = sample()
        let (journal, directory) = try journal()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeQuotaService(reads: [.success(before)], outcomes: [])
        let store = QuotaStore(snapshot: before, start: false, service: service, journal: journal)
        // Make the journal path a directory only after initial load.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("pending.json"), withIntermediateDirectories: false)
        await store.resetCredit(try XCTUnwrap(before.rateLimitResetCredits?.credits?.first))?.value
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNotNil(store.resetAlert)
        await store.shutdown()
    }
}

private final class FailFirstClearJournal: ResetIntentStoring {
    var intent: ResetIntent?
    var shouldFail = true
    func load() throws -> ResetIntent? { intent }
    func save(_ intent: ResetIntent) throws { self.intent = intent }
    func clear() throws {
        if shouldFail {
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        intent = nil
    }
}

private actor FakeQuotaService: QuotaService {
    struct Call: Sendable { let credit: String; let key: String; let account: String }
    private var reads: [Result<QuotaSnapshot, CodexClientError>]
    private var outcomes: [Result<ResetCreditOutcome, CodexClientError>]
    private(set) var calls: [Call] = []
    init(reads: [Result<QuotaSnapshot, CodexClientError>], outcomes: [Result<ResetCreditOutcome, CodexClientError>]) {
        self.reads = reads
        self.outcomes = outcomes
    }
    func fetchSnapshot() async throws -> QuotaSnapshot {
        guard !reads.isEmpty else { throw CodexClientError.connectionClosed }
        return try reads.removeFirst().get()
    }
    func consumeResetCredit(creditId: String, idempotencyKey: String, expectedAccountId: String) async throws -> ResetCreditOutcome {
        calls.append(Call(credit: creditId, key: idempotencyKey, account: expectedAccountId))
        guard !outcomes.isEmpty else { throw CodexClientError.connectionClosed }
        return try outcomes.removeFirst().get()
    }
    func disconnect() async {}
}
