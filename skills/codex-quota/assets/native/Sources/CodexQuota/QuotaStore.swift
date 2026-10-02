import AppKit
import Combine
import Foundation
import QuotaCore
import ServiceManagement

protocol QuotaService: Sendable {
    func fetchSnapshot() async throws -> QuotaSnapshot
    func consumeResetCredit(creditId: String, idempotencyKey: String, expectedAccountId: String) async throws -> ResetCreditOutcome
    func disconnect() async
}

extension CodexClient: QuotaService {}

protocol ResetIntentStoring {
    func load() throws -> ResetIntent?
    func save(_ intent: ResetIntent) throws
    func clear() throws
}

extension ResetIntentJournal: ResetIntentStoring {}

struct ResetAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var canRetry = false
}

@MainActor
final class QuotaStore: ObservableObject {
    static let shared = QuotaStore()

    @Published private(set) var snapshot: QuotaSnapshot?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published var settingsError: String?
    @Published private(set) var isResetting = false
    @Published private(set) var resettingCreditID: String?
    @Published private(set) var resetMessage: String?
    @Published var resetAlert: ResetAlert?
    @Published private(set) var pendingReset: ResetIntent?

    private var client: (any QuotaService)?
    private let journal: any ResetIntentStoring
    private var journalIsBlocked = false
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var fetchTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var failures = 0
    private var isStopped = false
    private var isSleeping = false

    init(snapshot: QuotaSnapshot? = nil, updatedAt: Date? = nil, start: Bool = true,
         service: (any QuotaService)? = nil, journal: any ResetIntentStoring = ResetIntentJournal()) {
        self.snapshot = snapshot
        self.updatedAt = updatedAt
        self.client = service
        self.journal = journal
        do {
            pendingReset = try journal.load()
            if let pendingReset {
                resetMessage = pendingReset.outcome == nil
                    ? "上次重置的结果尚未确认，可以继续重试同一次操作。"
                    : "上次操作结果已确认，可以继续完成本地记录清理。"
            }
        } catch {
            journalIsBlocked = true
            resetMessage = "无法读取上次重置记录，重置按钮暂不可用。额度查询不受影响。"
        }
        if start {
            updateLoginItemState()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isSleeping = false
                    self?.requestRefresh()
                }
            }
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.isSleeping = true
                    self?.timer?.invalidate()
                }
            }
            requestRefresh()
        }
    }

    var menuTitle: String {
        guard let percent = snapshot?.menuBarRemainingPercent else {
            return isRefreshing ? "···" : "—"
        }
        return Self.percentText(percent)
    }

    var isBusy: Bool { isRefreshing || isResetting }
    var hasPendingReset: Bool { pendingReset != nil }
    var pendingResetActionTitle: String {
        pendingReset?.outcome == nil ? "重试上次重置" : "完成上次操作"
    }

    func canReset(_ credit: ResetCredit, now: Date) -> Bool {
        guard !isStopped, !isBusy, !hasPendingReset, !journalIsBlocked,
              errorMessage == nil,
              let accountID = snapshot?.accountId, !accountID.isEmpty,
              (snapshot?.rateLimitResetCredits?.displayCount ?? 0) > 0,
              credit.status == "available", !credit.id.isEmpty,
              snapshot?.rateLimitResetCredits?.credits?.contains(where: { $0.id == credit.id }) == true
        else { return false }
        return credit.expirationDate.map { $0 > now } ?? true
    }

    static func percentText(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1%" }
        return "\(Int(value.rounded(.down)))%"
    }

    func requestRefresh() {
        guard !isStopped, !isBusy, !isSleeping else { return }
        timer?.invalidate()
        isRefreshing = true
        fetchTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
        }
    }

    private func refresh() async {
        defer {
            isRefreshing = false
            if !isStopped && !isSleeping { scheduleNextRefresh() }
        }
        guard !Task.isCancelled else { return }
        if client == nil {
            guard let executable = CodexExecutableLocator.locate() else {
                errorMessage = "未找到 Codex，请先安装并登录 Codex 桌面应用或 CLI。"
                failures += 1
                return
            }
            client = CodexClient(executableURL: executable,
                                 executableResolver: { CodexExecutableLocator.locate() })
        }
        do {
            guard let client else { return }
            let next = try await client.fetchSnapshot()
            guard !isStopped, !Task.isCancelled else { return }
            // Replace the entire snapshot, including reset credits, on every read.
            // No old-account fields are merged into the new account response.
            applySnapshot(next)
        } catch {
            guard !isStopped, !Task.isCancelled else { return }
            if let error = error as? CodexClientError, error.invalidatesSnapshot {
                snapshot = nil
                updatedAt = nil
            }
            errorMessage = error.localizedDescription
            failures += 1
        }
    }

    private func applySnapshot(_ next: QuotaSnapshot) {
        snapshot = next
        updatedAt = Date()
        errorMessage = nil
        failures = 0
    }

    @discardableResult
    func resetCredit(_ credit: ResetCredit) -> Task<Void, Never>? {
        guard canReset(credit, now: Date()), let accountID = snapshot?.accountId else { return nil }
        let intent = ResetIntent(accountId: accountID, creditId: credit.id)
        return startReset(intent, retry: false)
    }

    @discardableResult
    func retryPendingReset() -> Task<Void, Never>? {
        guard !isBusy, !isStopped, !journalIsBlocked, let pendingReset else { return nil }
        return startReset(pendingReset, retry: true)
    }

    private func startReset(_ intent: ResetIntent, retry: Bool) -> Task<Void, Never> {
        timer?.invalidate()
        isResetting = true
        resettingCreditID = intent.creditId
        resetAlert = nil
        resetMessage = nil
        let operation = Task { [weak self] in
            guard let self else { return }
            await self.performReset(intent, retry: retry)
        }
        resetTask = operation
        return operation
    }

    private func performReset(_ intent: ResetIntent, retry: Bool) async {
        defer {
            isResetting = false
            resettingCreditID = nil
            if !isStopped && !isSleeping { scheduleNextRefresh() }
        }
        if client == nil, let executable = CodexExecutableLocator.locate() {
            client = CodexClient(executableURL: executable,
                                 executableResolver: { CodexExecutableLocator.locate() })
        }
        guard let client else {
            resetAlert = ResetAlert(title: "无法重置", message: "未找到 Codex，请先安装并登录 Codex。", canRetry: retry)
            return
        }
        if let outcome = intent.outcome {
            await finishConfirmedReset(intent, outcome: outcome, client: client)
            return
        }
        do {
            // Validate the selected opportunity and account afresh before the first
            // mutation. A retry is allowed even if the already-used credit vanished.
            let current = try await client.fetchSnapshot()
            guard !isStopped, !Task.isCancelled else { return }
            applySnapshot(current)
            guard current.accountId == intent.accountId else { throw CodexClientError.accountChanged }
            if !retry {
                guard (current.rateLimitResetCredits?.displayCount ?? 0) > 0,
                      let credit = current.rateLimitResetCredits?.credits?.first(where: { $0.id == intent.creditId }),
                      credit.status == "available", credit.expirationDate.map({ $0 > Date() }) ?? true else {
                    resetAlert = ResetAlert(title: "这次重置机会已不可用", message: "已同步最新额度，请查看当前可用的重置机会。")
                    return
                }
                do { try journal.save(intent) }
                catch {
                    resetAlert = ResetAlert(title: "暂时无法重置", message: "无法保存这次操作的恢复记录，请检查本机存储后重试。")
                    return
                }
                pendingReset = intent
            }
            guard !isStopped, !Task.isCancelled else { return }
            let outcome = try await client.consumeResetCredit(
                creditId: intent.creditId, idempotencyKey: intent.idempotencyKey,
                expectedAccountId: intent.accountId
            )
            guard !isStopped, !Task.isCancelled else { return }
            await finishConfirmedReset(intent, outcome: outcome, client: client)
        } catch {
            guard !isStopped, !Task.isCancelled else { return }
            if let error = error as? CodexClientError, error.invalidatesSnapshot {
                handleReadError(error)
                resetAlert = ResetAlert(title: "无法重置", message: error.localizedDescription, canRetry: false)
            } else if pendingReset != nil {
                resetMessage = "重置结果尚未确认，请重试同一次操作。"
                resetAlert = ResetAlert(title: "重置结果尚未确认", message: "连接未能返回确定结果。点击“重试”会继续同一次操作，不会发起另一笔重置。", canRetry: true)
            } else {
                handleReadError(error)
                resetAlert = ResetAlert(title: "无法重置", message: error.localizedDescription)
            }
        }
    }

    private func finishConfirmedReset(_ intent: ResetIntent, outcome: ResetCreditOutcome,
                                      client: any QuotaService) async {
        let completed = intent.confirmed(outcome)
        pendingReset = completed
        switch outcome {
        case .reset, .alreadyRedeemed: resetMessage = "额度已重置。"
        case .nothingToReset: resetMessage = "当前没有需要重置的额度，未使用重置机会。"
        case .noCredit: resetMessage = "没有可用的重置机会，已请求同步最新额度。"
        }
        // Record the terminal result before clearing. If cleanup fails, a later
        // retry (also after restart) only cleans up and reads; it never consumes.
        try? journal.save(completed)
        do {
            try journal.clear()
            pendingReset = nil
        } catch {
            resetAlert = ResetAlert(title: "操作结果已确认", message: "本地恢复记录暂时无法清理。点击“完成上次操作”只会清理记录并同步额度。", canRetry: true)
        }
        do {
            let next = try await client.fetchSnapshot()
            guard !isStopped, !Task.isCancelled else { return }
            applySnapshot(next)
        } catch {
            guard !isStopped, !Task.isCancelled else { return }
            handleReadError(error)
            if resetAlert == nil {
                resetAlert = ResetAlert(title: "操作结果已确认", message: "最新额度暂时无法同步，稍后会自动刷新。")
            }
        }
    }

    private func handleReadError(_ error: Error) {
        if let error = error as? CodexClientError, error.invalidatesSnapshot {
            snapshot = nil
            updatedAt = nil
        }
        errorMessage = error.localizedDescription
        failures += 1
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        let seconds = RefreshPolicy.delay(now: Date(), snapshot: snapshot, failures: failures)
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func panelDidOpen() {
        updateLoginItemState()
        if updatedAt == nil || Date().timeIntervalSince(updatedAt!) >= 60 {
            requestRefresh()
        }
    }

    func updateLoginItemState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginItemNeedsApproval = status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateLoginItemState()
            if loginItemNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
            settingsError = nil
        } catch {
            updateLoginItemState()
            settingsError = "无法更改登录启动设置，请将应用放入“应用程序”文件夹后重试。"
        }
    }

    func openCodex() {
        if let executable = CodexExecutableLocator.locate(),
           let application = CodexExecutableLocator.desktopApplication(containing: executable) {
            NSWorkspace.shared.open(application)
            return
        }
        if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(application)
            return
        }
        settingsError = "未找到 Codex 桌面应用。你仍可通过 Codex CLI 登录并查询额度。"
    }

    func shutdown() async {
        isStopped = true
        timer?.invalidate()
        timer = nil
        fetchTask?.cancel()
        resetTask?.cancel()
        for observer in [wakeObserver, sleepObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        await client?.disconnect()
        client = nil
    }
}
