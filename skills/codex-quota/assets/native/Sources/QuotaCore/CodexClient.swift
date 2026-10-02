import Darwin
import Foundation

public enum ResetCreditOutcome: String, Codable, Sendable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
}

public enum CodexClientError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case unsupportedAuthentication
    case accountChanged
    case launchFailed
    case connectionClosed
    case requestTimedOut
    case invalidResponse
    case invalidResetRequest
    case serverError(code: Int)

    public var invalidatesSnapshot: Bool {
        switch self {
        case .notLoggedIn, .unsupportedAuthentication, .accountChanged: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "请先在 Codex 中登录 ChatGPT 账号，然后刷新。"
        case .unsupportedAuthentication: return "当前使用 API 密钥登录，请在 Codex 中切换到 ChatGPT 账号。"
        case .accountChanged: return "Codex 账号已切换，请刷新以查看新账号额度。"
        case .launchFailed: return "无法启动 Codex 额度连接，请确认 Codex 已正确安装。"
        case .connectionClosed: return "Codex 额度连接已断开，请稍后刷新。"
        case .requestTimedOut: return "Codex 请求超时，请检查网络后重试。"
        case .invalidResponse: return "无法读取 Codex 返回的数据，请更新 Codex 后重试。"
        case .invalidResetRequest: return "重置参数不完整，请刷新后重试。"
        case .serverError: return "Codex 暂时无法完成请求，请稍后重试。"
        }
    }
}

public enum CodexExecutableLocator {
    public static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return locate(applicationRoots: [
            "/Applications/ChatGPT.app", "/Applications/Codex.app",
            home + "/Applications/ChatGPT.app", home + "/Applications/Codex.app"
        ], searchPath: ProcessInfo.processInfo.environment["PATH"] ?? "",
           fallbackPaths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"])
    }

    static func locate(applicationRoots: [String], searchPath: String, fallbackPaths: [String] = []) -> URL? {
        let layouts = [
            "/Contents/Resources/codex-cli/bin/codex",
            "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Contents/Resources/codex"
        ]
        var candidates = applicationRoots.flatMap { root in layouts.map { root + $0 } }
        candidates += searchPath
            .split(separator: ":").map { String($0) + "/codex" }
        candidates += fallbackPaths
        return candidates.first { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0) }
    }

    /// Skip the embedded CodexCLI.app when opening the surrounding desktop application.
    public static func desktopApplication(containing executable: URL) -> URL? {
        var ancestor = executable.deletingLastPathComponent()
        var result: URL?
        while ancestor.path != "/" {
            if ancestor.pathExtension == "app", ancestor.lastPathComponent != "CodexCLI.app" {
                result = ancestor
            }
            ancestor.deleteLastPathComponent()
        }
        return result
    }
}

/// Owns one app-server session. Reads and explicit credit resets are serialized.
public actor CodexClient {
    private var executableURL: URL
    private let executableResolver: (@Sendable () -> URL?)?
    private let codexHome: URL?
    private let requestTimeout: TimeInterval
    private var transport: AppServerTransport?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var generation = 0
    private var lastAccountIdentity: String?
    private var lastAuthFingerprint: AuthFingerprint?

    private struct AuthFingerprint: Equatable {
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }

    public init(executableURL: URL, codexHome: URL? = nil, requestTimeout: TimeInterval = 15,
                executableResolver: (@Sendable () -> URL?)? = nil) {
        self.executableURL = executableURL
        self.executableResolver = executableResolver
        self.codexHome = codexHome
        self.requestTimeout = max(0.01, requestTimeout)
    }

    deinit { transport?.stop() }

    public func fetchSnapshot() async throws -> QuotaSnapshot {
        let requestedGeneration = generation
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CodexClientError.connectionClosed }

        do {
            let connection = try await prepareConnection()
            return try await readSnapshot(using: connection)
        } catch {
            await transport?.close()
            transport = nil
            throw error
        }
    }

    /// Performs one explicit attempt. The caller retains the same credit and key
    /// for retries after uncertain responses, including across app restarts.
    public func consumeResetCredit(
        creditId: String,
        idempotencyKey: String,
        expectedAccountId: String
    ) async throws -> ResetCreditOutcome {
        guard [creditId, idempotencyKey, expectedAccountId].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { throw CodexClientError.invalidResetRequest }

        let requestedGeneration = generation
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        guard generation == requestedGeneration else { throw CodexClientError.connectionClosed }

        do {
            let connection = try await prepareConnection()
            let snapshot = try await readSnapshot(using: connection)
            guard snapshot.accountId == expectedAccountId,
                  currentAuthFingerprint() == lastAuthFingerprint else {
                throw CodexClientError.accountChanged
            }
            try Task.checkCancellation()
            // Do not require the credit in this snapshot: a successful earlier
            // attempt may already have consumed it while its response was lost.
            let data = try await connection.request(method: "account/rateLimitResetCredit/consume", params: [
                "creditId": creditId,
                "idempotencyKey": idempotencyKey
            ])
            struct Response: Decodable { let outcome: ResetCreditOutcome }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw CodexClientError.invalidResponse
            }
            return response.outcome
        } catch {
            await transport?.close()
            transport = nil
            throw error
        }
    }

    public func disconnect() async {
        generation += 1
        let previous = transport
        transport = nil
        await previous?.close()
    }

    private func acquireOperation() async {
        if operationInProgress {
            await withCheckedContinuation { operationWaiters.append($0) }
        } else {
            operationInProgress = true
        }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty { operationInProgress = false }
        else { operationWaiters.removeFirst().resume() }
    }

    private func prepareConnection() async throws -> AppServerTransport {
        if let resolved = executableResolver?(), resolved != executableURL {
            await transport?.close()
            transport = nil
            executableURL = resolved
        }
        let authFingerprint = currentAuthFingerprint()
        // app-server caches authentication. Restart only our child if another
        // Codex instance changes the auth file; never read its token contents.
        if transport != nil, authFingerprint != lastAuthFingerprint {
            await transport?.close()
            transport = nil
        }
        lastAuthFingerprint = authFingerprint
        if let current = transport { return current }
        let connection = AppServerTransport(executableURL: executableURL,
            codexHome: codexHome, timeout: requestTimeout)
        transport = connection
        try await connection.start()
        _ = try await connection.request(method: "initialize", params: [
            "clientInfo": ["name": "codex_quota_menu", "title": "Codex Quota", "version": "0.2.0"]
        ])
        try await connection.notify(method: "initialized")
        return connection
    }

    private func readSnapshot(using connection: AppServerTransport) async throws -> QuotaSnapshot {
        let accountData = try await connection.request(method: "account/read", params: ["refreshToken": false])
        let account = try Self.readAccount(accountData)
        let previousAccount = lastAccountIdentity
        lastAccountIdentity = account
        if let previousAccount, let account, previousAccount != account {
            throw CodexClientError.accountChanged
        }
        let data = try await connection.request(method: "account/rateLimits/read")
        var snapshot: QuotaSnapshot
        do { snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: data) }
        catch { throw CodexClientError.invalidResponse }
        snapshot.accountId = snapshot.accountId ?? account
        return snapshot
    }

    private func currentAuthFingerprint() -> AuthFingerprint {
        let directory = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("auth.json").path)
        return AuthFingerprint(modified: attributes?[.modificationDate] as? Date,
            size: (attributes?[.size] as? NSNumber)?.uint64Value,
            inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func readAccount(_ data: Data) throws -> String? {
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              result.keys.contains("account") else { throw CodexClientError.invalidResponse }
        guard let account = result["account"] as? [String: Any] else { throw CodexClientError.notLoggedIn }
        guard let type = account["type"] as? String else { throw CodexClientError.invalidResponse }
        guard type == "chatgpt" else { throw CodexClientError.unsupportedAuthentication }
        // The identity stays in memory. It is never displayed, logged, or persisted.
        return (account["accountId"] as? String) ?? (account["id"] as? String) ?? (account["email"] as? String)
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// All process, framing, and continuation state belongs to this serial queue.
private final class AppServerTransport: @unchecked Sendable {
    private struct Pending {
        let token: UUID
        let continuation: CheckedContinuation<Data, Error>
        let timeout: DispatchWorkItem
    }

    private let queue = DispatchQueue(label: "app.codex-quota.app-server")
    private let executableURL: URL
    private let codexHome: URL?
    private let timeout: TimeInterval
    private var process: Process?
    private var closingProcess: Process?
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var input: FileHandle?
    private var output: FileHandle?
    private var stderr: FileHandle?
    private var outputSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var buffer = Data()
    private var pending: [Int: Pending] = [:]
    private var nextID = 1
    private var closed = false
    private let maximumFrameBytes = 2 * 1024 * 1024

    init(executableURL: URL, codexHome: URL?, timeout: TimeInterval) {
        self.executableURL = executableURL
        self.codexHome = codexHome
        self.timeout = timeout
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else { continuation.resume(throwing: CodexClientError.connectionClosed); return }
                let process = Process()
                let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
                process.executableURL = self.executableURL
                process.arguments = ["app-server", "--listen", "stdio://"]
                var environment = ProcessInfo.processInfo.environment
                if let codexHome = self.codexHome { environment["CODEX_HOME"] = codexHome.path }
                process.environment = environment
                process.standardInput = stdinPipe.fileHandleForReading
                process.standardOutput = stdoutPipe.fileHandleForWriting
                process.standardError = stderrPipe.fileHandleForWriting
                process.terminationHandler = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async {
                        self.finish(with: CodexClientError.connectionClosed)
                        self.completeShutdown()
                    }
                }
                self.process = process
                self.input = stdinPipe.fileHandleForWriting
                self.output = stdoutPipe.fileHandleForReading
                self.stderr = stderrPipe.fileHandleForReading
                do {
                    try process.run()
                    try? stdinPipe.fileHandleForReading.close()
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    for handle in [self.input, self.output, self.stderr].compactMap({ $0 }) {
                        let flags = fcntl(handle.fileDescriptor, F_GETFL)
                        guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                            throw CodexClientError.launchFailed
                        }
                    }
                    // A child closing stdin must become an error, never a SIGPIPE crash.
                    guard fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) >= 0 else {
                        throw CodexClientError.launchFailed
                    }
                    self.outputSource = self.makeSource(stdoutPipe.fileHandleForReading, parsesJSON: true)
                    self.stderrSource = self.makeSource(stderrPipe.fileHandleForReading, parsesJSON: false)
                    continuation.resume()
                } catch {
                    self.finish(with: CodexClientError.launchFailed)
                    continuation.resume(throwing: CodexClientError.launchFailed)
                }
            }
        }
    }

    func request(method: String, params: [String: Any] = [:]) async throws -> Data {
        let token = UUID()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    guard !self.closed else { continuation.resume(throwing: CodexClientError.connectionClosed); return }
                    let id = self.nextID
                    self.nextID += 1
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.pending[id] != nil else { return }
                        self.finish(with: CodexClientError.requestTimedOut)
                    }
                    self.pending[id] = Pending(token: token, continuation: continuation, timeout: timeout)
                    self.queue.asyncAfter(deadline: .now() + self.timeout, execute: timeout)
                    do { try self.write(["id": id, "method": method, "params": params]) }
                    catch { self.finish(with: CodexClientError.connectionClosed) }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async {
                if self.pending.values.contains(where: { $0.token == token }) {
                    self.finish(with: CancellationError())
                }
            }
        }
    }

    func notify(method: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else { continuation.resume(throwing: CodexClientError.connectionClosed); return }
                do {
                    try self.write(["method": method])
                    continuation.resume()
                } catch {
                    self.finish(with: CodexClientError.connectionClosed)
                    continuation.resume(throwing: CodexClientError.connectionClosed)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finish(with: CodexClientError.connectionClosed)
                if self.closingProcess?.isRunning == true {
                    self.shutdownWaiters.append(continuation)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func stop() { queue.async { self.finish(with: CodexClientError.connectionClosed) } }

    private func write(_ object: [String: Any]) throws {
        guard let input else { throw CodexClientError.connectionClosed }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(input.fileDescriptor, base.advanced(by: written), raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CodexClientError.connectionClosed }
                written += count
            }
        }
    }

    private func makeSource(_ handle: FileHandle, parsesJSON: Bool) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: handle.fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable(handle, parsesJSON: parsesJSON) }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        return source
    }

    private func readAvailable(_ handle: FileHandle, parsesJSON: Bool) {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: 65_536)
        // Bound each event so a noisy stderr cannot starve timeouts or shutdown.
        for _ in 0..<16 {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                if parsesJSON {
                    buffer.append(contentsOf: bytes.prefix(count))
                    consumeFrames()
                    guard !closed else { return }
                }
            } else if count == 0 {
                if parsesJSON { finish(with: CodexClientError.connectionClosed) }
                else { stderrSource?.cancel(); stderrSource = nil; stderr = nil }
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finish(with: CodexClientError.connectionClosed)
                return
            }
        }
    }

    private func consumeFrames() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[..<newline]
            guard frame.count <= maximumFrameBytes else { finish(with: CodexClientError.invalidResponse); return }
            let frameData = Data(frame)
            buffer.removeSubrange(...newline)
            if frameData.allSatisfy({ $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) { continue }
            guard let message = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any] else {
                finish(with: CodexClientError.invalidResponse); return
            }
            // Notifications have no request id and never alter locally fetched state.
            guard let id = (message["id"] as? Int) ?? (message["id"] as? String).flatMap(Int.init),
                  let request = pending.removeValue(forKey: id) else { continue }
            request.timeout.cancel()
            if let error = message["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                request.continuation.resume(throwing: code == 401 || code == 403
                    ? CodexClientError.notLoggedIn : CodexClientError.serverError(code: code))
            } else if let result = message["result"],
                      let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                request.continuation.resume(returning: data)
            } else {
                request.continuation.resume(throwing: CodexClientError.invalidResponse)
            }
        }
        if buffer.count > maximumFrameBytes { finish(with: CodexClientError.invalidResponse) }
    }

    private func finish(with error: Error) {
        guard !closed else { return }
        closed = true
        let outstanding = pending.values
        pending.removeAll()
        for request in outstanding {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        buffer.removeAll()
        try? input?.close()
        input = nil
        if let outputSource { outputSource.cancel() } else { try? output?.close() }
        if let stderrSource { stderrSource.cancel() } else { try? stderr?.close() }
        outputSource = nil
        stderrSource = nil
        output = nil
        stderr = nil
        if let child = process, child.isRunning {
            closingProcess = child
            child.terminate()
            // Closing stdin lets a healthy app-server exit naturally. A wedged child
            // cannot remain behind indefinitely after timeout or app termination.
            queue.asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
    }

    private func completeShutdown() {
        closingProcess = nil
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
