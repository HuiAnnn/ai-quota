import Combine
import Foundation
import XCTest
import QuotaCore
@testable import CodexQuota

@MainActor
final class ProviderStoreTests: XCTestCase {
    private func snapshot(_ id: String = "test", account: String = "account", remaining: Double = 80) -> ProviderSnapshot {
        ProviderSnapshot(providerID: id, accountFingerprint: account,
                         metrics: [QuotaMetric(id: "weekly", label: "每周", remainingPercent: remaining)])
    }

    func testRepeatedRefreshDoesNotSendAnotherRequestAndStopDiscardsLateResult() async throws {
        let provider = ControlledDashboardProvider(id: "test")
        let store = ProviderStore(provider: provider, start: false)
        let operation = try XCTUnwrap(store.requestRefresh())
        XCTAssertTrue(store.isRefreshing)
        XCTAssertNil(store.requestRefresh())
        await provider.waitForRequestCount(1)
        await store.stop()
        await provider.completeRequest(0, with: .success(snapshot()))
        await operation.value
        XCTAssertNil(store.snapshot)
        XCTAssertFalse(store.isRefreshing)
        let count = await provider.requestCount
        XCTAssertEqual(count, 1)
    }

    func testNetworkFailurePreservesSnapshotButMarksItStale() async throws {
        let provider = DashboardSequenceProvider(id: "test", results: [.success(snapshot()), .failure(.networkUnavailable)])
        let store = ProviderStore(provider: provider, start: false)
        await store.requestRefresh()?.value
        await store.requestRefresh()?.value
        XCTAssertEqual(store.snapshot?.menuBarRemainingPercent, 80)
        XCTAssertTrue(store.state.isStale)
        XCTAssertEqual(store.error, .networkUnavailable)
        await store.stop()
    }

    func testAuthenticationAccountAndAccessFailuresClearOldSnapshot() async {
        for error in [QuotaProviderError.authenticationRequired, .accountChanged, .accessRequired] {
            let provider = DashboardSequenceProvider(id: "test", results: [.success(snapshot()), .failure(error)])
            let store = ProviderStore(provider: provider, start: false)
            await store.requestRefresh()?.value
            await store.requestRefresh()?.value
            XCTAssertNil(store.snapshot)
            XCTAssertNil(store.updatedAt)
            XCTAssertEqual(store.error, error)
            await store.stop()
        }
    }

    func testSleepCancellationCannotOverwriteNewWakeResult() async throws {
        let provider = ControlledDashboardProvider(id: "test")
        let store = ProviderStore(provider: provider, start: false)
        let first = try XCTUnwrap(store.requestRefresh())
        await provider.waitForRequestCount(1)
        store.pauseForSleep()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNil(store.requestRefresh())
        store.wake()
        await Task.yield()
        let countWhileCancelledRequestIsRunning = await provider.requestCount
        XCTAssertEqual(countWhileCancelledRequestIsRunning, 1)
        await provider.completeRequest(0, with: .success(snapshot(remaining: 90)))
        await first.value
        await provider.waitForRequestCount(2)
        XCTAssertNil(store.snapshot)
        let applied = expectation(description: "Only the new wake result applies")
        let observation = store.$snapshot.compactMap { $0 }.first { $0.menuBarRemainingPercent == 60 }
            .sink { _ in applied.fulfill() }
        await provider.completeRequest(1, with: .success(snapshot(remaining: 60)))
        await fulfillment(of: [applied], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(store.snapshot?.menuBarRemainingPercent, 60)
        let maximumConcurrentRequests = await provider.maximumConcurrentRequests
        XCTAssertEqual(maximumConcurrentRequests, 1)
        await store.stop()
    }

    func testDisableAndEnableWaitsForCancelledRequestBeforeRefreshing() async throws {
        let provider = ControlledDashboardProvider(id: "test")
        let store = ProviderStore(provider: provider, start: false)
        let first = try XCTUnwrap(store.requestRefresh())
        await provider.waitForRequestCount(1)
        store.suspend()
        store.activate(automaticRefresh: true)
        await Task.yield()
        let countWhileCancelledRequestIsRunning = await provider.requestCount
        XCTAssertEqual(countWhileCancelledRequestIsRunning, 1)
        await provider.completeRequest(0, with: .success(snapshot(remaining: 90)))
        await first.value
        await provider.waitForRequestCount(2)
        XCTAssertNil(store.snapshot)
        let applied = expectation(description: "Only the result after enabling applies")
        let observation = store.$snapshot.compactMap { $0 }.first { $0.menuBarRemainingPercent == 60 }
            .sink { _ in applied.fulfill() }
        await provider.completeRequest(1, with: .success(snapshot(remaining: 60)))
        await fulfillment(of: [applied], timeout: 2)
        withExtendedLifetime(observation) {}
        let maximumConcurrentRequests = await provider.maximumConcurrentRequests
        XCTAssertEqual(maximumConcurrentRequests, 1)
        await store.stop()
    }

    func testOneProviderFailureDoesNotPreventAnotherProviderRefresh() async throws {
        let failing = DashboardSequenceProvider(id: "muse", results: [.failure(.authenticationRequired)])
        let successful = DashboardSequenceProvider(id: "cue", results: [.success(snapshot("cue", remaining: 99))])
        let (defaults, suite) = try isolatedDashboardDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let codex = QuotaStore(start: false, service: DashboardCodexUnavailableService(), journal: DashboardEmptyJournal())
        let store = AIQuotaStore(codex: codex, providers: [failing, successful], preferences: ProviderPreferences(defaults: defaults), start: false)
        await store.refresh()
        XCTAssertEqual(store.state(for: "cue")?.remainingPercent, 99)
        XCTAssertNil(store.state(for: "muse")?.snapshot)
        XCTAssertEqual(store.state(for: "muse")?.error, .authenticationRequired)
        await store.shutdown()
    }

    func testDetailSelectionDoesNotChangeSavedDefault() throws {
        let (defaults, suite) = try isolatedDashboardDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let codex = QuotaStore(start: false, service: DashboardCodexUnavailableService(), journal: DashboardEmptyJournal())
        let providers = [DashboardSequenceProvider(id: "cue", results: [])]
        let store = AIQuotaStore(codex: codex, providers: providers, preferences: ProviderPreferences(defaults: defaults), start: false)
        store.selectDetail("cue")
        XCTAssertEqual(store.selectedProviderID, "cue")
        XCTAssertEqual(store.defaultProviderID, "codex")
        store.setDefault("cue")
        XCTAssertEqual(store.defaultProviderID, "cue")
        store.selectDetail("codex")
        XCTAssertEqual(store.defaultProviderID, "cue")
    }

    func testDisabledProviderCanRefreshWhenEnabledAfterWake() async throws {
        let provider = ControlledDashboardProvider(id: "cue")
        let (defaults, suite) = try isolatedDashboardDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let codex = QuotaStore(start: false, service: DashboardCodexUnavailableService(), journal: DashboardEmptyJournal())
        let store = AIQuotaStore(codex: codex, providers: [provider], preferences: ProviderPreferences(defaults: defaults), start: false)
        store.setEnabled("cue", enabled: false)
        store.pauseForSleep()
        store.wake()
        store.setEnabled("cue", enabled: true)
        store.requestRefresh("cue")
        XCTAssertTrue(store.state(for: "cue")?.isRefreshing == true)
        guard store.state(for: "cue")?.isRefreshing == true else {
            await store.shutdown()
            return
        }
        await provider.waitForRequestCount(1)
        await store.shutdown()
        await provider.completeRequest(0, with: .success(snapshot("cue", remaining: 75)))
    }
}

private actor DashboardSequenceProvider: QuotaProvider {
    nonisolated let descriptor: ProviderDescriptor
    private var results: [Result<ProviderSnapshot, QuotaProviderError>]
    init(id: String, results: [Result<ProviderSnapshot, QuotaProviderError>]) {
        descriptor = ProviderDescriptor(id: id, name: id)
        self.results = results
    }
    func fetchQuota() async throws -> ProviderSnapshot {
        guard !results.isEmpty else { throw QuotaProviderError.networkUnavailable }
        return try results.removeFirst().get()
    }
}

private actor ControlledDashboardProvider: QuotaProvider {
    nonisolated let descriptor: ProviderDescriptor
    private var requests: [Int: CheckedContinuation<ProviderSnapshot, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var requestCount = 0
    private var activeRequests = 0
    private(set) var maximumConcurrentRequests = 0
    init(id: String) { descriptor = ProviderDescriptor(id: id, name: id) }
    func fetchQuota() async throws -> ProviderSnapshot {
        let index = requestCount
        requestCount += 1
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        defer { activeRequests -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            requests[index] = continuation
            let ready = waiters.filter { $0.0 <= requestCount }
            waiters.removeAll { $0.0 <= requestCount }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequestCount(_ target: Int) async {
        if requestCount >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
    func completeRequest(_ index: Int, with result: Result<ProviderSnapshot, QuotaProviderError>) {
        guard let request = requests.removeValue(forKey: index) else { return }
        switch result {
        case .success(let snapshot): request.resume(returning: snapshot)
        case .failure(let error): request.resume(throwing: error)
        }
    }
}

private struct DashboardEmptyJournal: ResetIntentStoring {
    func load() throws -> ResetIntent? { nil }
    func save(_ intent: ResetIntent) throws {}
    func clear() throws {}
}

private func isolatedDashboardDefaults() throws -> (UserDefaults, String) {
    let suite = "DashboardTests." + UUID().uuidString
    return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
}

private actor DashboardCodexUnavailableService: QuotaService {
    func fetchSnapshot() async throws -> QuotaSnapshot { throw CodexClientError.notLoggedIn }
    func consumeResetCredit(creditId: String, idempotencyKey: String, expectedAccountId: String) async throws -> ResetCreditOutcome {
        throw CodexClientError.invalidResetRequest
    }
    func disconnect() async {}
}
