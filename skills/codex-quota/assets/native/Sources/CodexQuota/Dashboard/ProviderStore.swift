import Combine
import Foundation
import QuotaCore

struct ProviderState: Equatable, Sendable {
    let descriptor: ProviderDescriptor
    let snapshot: ProviderSnapshot?
    let isRefreshing: Bool
    let error: QuotaProviderError?
    let errorMessage: String?
    let updatedAt: Date?
    let isStale: Bool

    var remainingPercent: Double? { snapshot?.menuBarRemainingPercent }
    var needsConnection: Bool {
        error == .authenticationRequired || error == .accessRequired || error == .accountChanged
    }
}

@MainActor
final class ProviderStore: ObservableObject {
    let descriptor: ProviderDescriptor
    @Published private(set) var snapshot: ProviderSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var error: QuotaProviderError?
    @Published private(set) var updatedAt: Date?

    private let provider: any QuotaProvider
    private let now: () -> Date
    private var fetchTask: Task<Void, Never>?
    private var fetchGeneration: Int?
    private var needsRefresh = false
    private var timer: Timer?
    private var generation = 0
    private var failures = 0
    private var isStopped = false
    private var isSleeping = false
    private var automaticallyRefreshes = false

    init(provider: any QuotaProvider, start: Bool = true, now: @escaping () -> Date = { Date() }) {
        self.provider = provider
        descriptor = provider.descriptor
        self.now = now
        if start { self.start() }
    }

    var state: ProviderState {
        ProviderState(descriptor: descriptor, snapshot: snapshot, isRefreshing: isRefreshing,
                      error: error, errorMessage: error?.localizedDescription, updatedAt: updatedAt,
                      isStale: snapshot != nil && (error != nil || now().timeIntervalSince(snapshot!.observedAt) >= max(600, descriptor.refreshInterval * 2)))
    }

    func start() {
        activate(automaticRefresh: true)
    }

    func activate(automaticRefresh: Bool, isSleeping: Bool = false) {
        isStopped = false
        self.isSleeping = isSleeping
        automaticallyRefreshes = automaticRefresh
        if automaticRefresh { requestRefresh() }
    }

    /// Disable synchronously, so an immediate enable cannot be overtaken by an old stop task.
    func suspend() {
        isStopped = true
        automaticallyRefreshes = false
        cancelCurrentGeneration()
    }

    @discardableResult
    func requestRefresh() -> Task<Void, Never>? {
        guard !isStopped, !isSleeping else { return nil }
        if fetchTask != nil {
            if fetchGeneration != generation {
                needsRefresh = true
                isRefreshing = true
            }
            return nil
        }
        timer?.invalidate()
        timer = nil
        let requestGeneration = generation
        fetchGeneration = requestGeneration
        isRefreshing = true
        let operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finishRefresh(requestGeneration) }
            do {
                try Task.checkCancellation()
                let next = try await provider.fetchQuota()
                try Task.checkCancellation()
                guard self.generation == requestGeneration, !self.isStopped, !self.isSleeping else { return }
                guard next.providerID == self.descriptor.id else { throw QuotaProviderError.invalidResponse }
                self.snapshot = next
                self.updatedAt = next.observedAt
                self.error = nil
                self.failures = 0
            } catch is CancellationError {
                // A cancelled generation cannot update data or clear a newer request's loading state.
            } catch {
                guard self.generation == requestGeneration, !self.isStopped, !self.isSleeping, !Task.isCancelled else { return }
                let safeError = error as? QuotaProviderError ?? .requestFailed
                if safeError.invalidatesSnapshot {
                    self.snapshot = nil
                    self.updatedAt = nil
                }
                self.error = safeError
                self.failures = min(6, self.failures + 1)
            }
        }
        fetchTask = operation
        return operation
    }

    /// A caller may await either the running query or a newly requested manual refresh.
    func refresh() async {
        guard !isStopped, !isSleeping else { return }
        requestRefresh()
        while let operation = fetchTask {
            await operation.value
            guard !Task.isCancelled, !isStopped, !isSleeping else { return }
        }
    }

    func pauseForSleep() {
        isSleeping = true
        cancelCurrentGeneration()
    }

    func wake() {
        guard !isStopped else { return }
        isSleeping = false
        requestRefresh()
    }

    func stop() async {
        suspend()
        await provider.disconnect()
    }

    private func cancelCurrentGeneration() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        fetchTask?.cancel()
        needsRefresh = false
        isRefreshing = false
    }

    private func finishRefresh(_ requestGeneration: Int) {
        guard fetchGeneration == requestGeneration else { return }
        fetchTask = nil
        fetchGeneration = nil
        isRefreshing = false
        let pendingRefresh = needsRefresh
        needsRefresh = false
        if pendingRefresh, !isStopped, !isSleeping { requestRefresh() }
        else { scheduleNextRefresh() }
    }

    private func scheduleNextRefresh() {
        guard automaticallyRefreshes, !isStopped, !isSleeping else { return }
        let delay = min(3600, descriptor.refreshInterval * pow(2, Double(failures)))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
}
