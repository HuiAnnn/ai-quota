import AppKit
import Combine
import Foundation
import QuotaCore

@MainActor
final class AnnouncementStore: ObservableObject {
    static let shared = AnnouncementStore()
    nonisolated static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexQuota/announcements-v1.json")
    }

    @Published private(set) var items: [ResetAnnouncement] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    private let cacheURL: URL?
    private let now: () -> Date
    private let loader: @Sendable () async throws -> [ResetAnnouncement]
    private var lastAttempt: Date?
    private var stopped = false
    private var sleeping = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var task: Task<Void, Never>?

    private struct Cache: Codable {
        let version: Int
        let updatedAt: Date
        let items: [ResetAnnouncement]
    }

    init(cacheURL: URL? = AnnouncementStore.defaultCacheURL, start: Bool = true,
         now: @escaping () -> Date = Date.init,
         loader: @escaping @Sendable () async throws -> [ResetAnnouncement] = { try await AnnouncementClient().fetch() }) {
        self.cacheURL = cacheURL
        self.now = now
        self.loader = loader
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), data.count <= 1_048_576,
           let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 1,
           cache.updatedAt <= now().addingTimeInterval(60), cache.items.count <= 10,
           cache.items.allSatisfy({ ResetAnnouncement.validatedSourceURL($0.sourceURL) != nil }) {
            items = cache.items
            updatedAt = cache.updatedAt
            lastAttempt = cache.updatedAt
        }
        if start {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sleeping = false
                    self?.requestRefresh()
                    self?.startTimer()
                }
            })
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sleeping = true
                    self?.timer?.invalidate()
                }
            })
            requestRefresh()
            startTimer()
        }
    }

    func requestRefresh(force: Bool = false) {
        guard task == nil, !stopped, !sleeping else { return }
        task = Task { [weak self] in
            await self?.refresh(force: force)
            self?.task = nil
        }
    }

    func refresh(force: Bool = false) async {
        guard !stopped, !sleeping, !isRefreshing else { return }
        let current = now()
        if let lastAttempt {
            let elapsed = current.timeIntervalSince(lastAttempt)
            if elapsed >= 0 && elapsed < (force ? 60 : 600) { return }
        }
        lastAttempt = current
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await loader()
            guard !stopped, !Task.isCancelled else { return }
            items = fresh
            updatedAt = now()
            errorMessage = nil
            if let cacheURL, let updatedAt {
                do {
                    try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try JSONEncoder().encode(Cache(version: 1, updatedAt: updatedAt, items: fresh))
                    try data.write(to: cacheURL, options: .atomic)
                } catch {
                    errorMessage = "公告已同步，但本地缓存暂时无法保存"
                }
            }
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            errorMessage = "\(error.localizedDescription)。稍后自动重试。"
        }
    }

    private func startTimer() {
        timer?.invalidate()
        guard !stopped, !sleeping else { return }
        // A short timer checks eligibility; the network request remains limited to ten minutes.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func shutdown() {
        stopped = true
        task?.cancel()
        task = nil
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
