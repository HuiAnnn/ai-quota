import Foundation

public struct ManusQuotaProvider: QuotaProvider {
    public let descriptor = ProviderDescriptor(id: "manus", name: "Manus", bundleIdentifier: "im.manus.desktop", refreshInterval: 300)
    private let client: ManusRPCQuotaClient

    public init(transport: any QuotaHTTPTransport = URLSessionQuotaTransport(allowedHosts: ["api.manus.im"]),
                credentialsLoader: (@Sendable () async throws -> LocalProviderCredential)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        client = ManusRPCQuotaClient(transport: transport, credentialsLoader: credentialsLoader ?? { try ManusLocalSession.load(.manus) },
                                    product: .manus, now: now)
    }

    public func fetchQuota() async throws -> ProviderSnapshot {
        let result = try await client.fetch()
        return try ManusQuotaMapper.snapshot(from: result.data, accountFingerprint: result.fingerprint, observedAt: result.observedAt)
    }
}

public struct CueQuotaProvider: QuotaProvider {
    public let descriptor = ProviderDescriptor(id: "cue", name: "Cue", bundleIdentifier: "ai.manus.agents", refreshInterval: 300)
    private let client: ManusRPCQuotaClient

    public init(transport: any QuotaHTTPTransport = URLSessionQuotaTransport(allowedHosts: ["api.manus.im"]),
                credentialsLoader: (@Sendable () async throws -> LocalProviderCredential)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        client = ManusRPCQuotaClient(transport: transport, credentialsLoader: credentialsLoader ?? { try ManusLocalSession.load(.cue) },
                                    product: .cue, now: now)
    }

    public func fetchQuota() async throws -> ProviderSnapshot {
        let result = try await client.fetch()
        return try CueQuotaMapper.snapshot(from: result.data, accountFingerprint: result.fingerprint, observedAt: result.observedAt)
    }
}

private enum ManusProduct: Sendable {
    case manus, cue
    var appName: String { self == .manus ? "Manus Studio" : "Cue" }
    var profileName: String { self == .manus ? "Manus" : "Cue" }
    var fallbackVersion: String { self == .manus ? "2.0.3" : "1.0.6" }
    var quotaPath: String {
        self == .manus ? "user.v1.UserService/GetAvailableCredits" : "user.v1.SubscriptionService/GetAgentsMembership"
    }
    var installedURL: URL? {
        let paths = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        return paths.map { $0.appendingPathComponent(appName + ".app", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    var version: String {
        installedURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? fallbackVersion
    }
}

private struct ManusRPCQuotaClient: Sendable {
    let transport: any QuotaHTTPTransport
    let credentialsLoader: @Sendable () async throws -> LocalProviderCredential
    let product: ManusProduct
    let now: @Sendable () -> Date
    let identityGuard = ProviderIdentityGuard()

    func fetch() async throws -> (data: Data, fingerprint: String, observedAt: Date) {
        try Task.checkCancellation()
        let credential = try await loadCredential()
        try await identityGuard.verify(credential.accountFingerprint)
        guard !credential.token.isEmpty, !credential.token.contains(where: { $0.isNewline }) else {
            throw QuotaProviderError.authenticationRequired
        }
        var request = URLRequest(url: URL(string: "https://api.manus.im/" + product.quotaPath)!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("desktop", forHTTPHeaderField: "x-client-type")
        request.setValue(product.version, forHTTPHeaderField: "x-client-version")
        request.setValue("zh-CN", forHTTPHeaderField: "x-client-locale")
        request.setValue("Asia/Shanghai", forHTTPHeaderField: "x-client-timezone")
        request.setValue("-480", forHTTPHeaderField: "x-client-timezone-offset")
        if let deviceID = credential.deviceID, ManusLocalSession.validDeviceID(deviceID) {
            request.setValue(deviceID, forHTTPHeaderField: "x-client-id")
        }
        if product == .cue { request.setValue("manus-agents", forHTTPHeaderField: "x-product-name") }
        let data: Data
        do { data = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let safeError = error as? QuotaProviderError ?? .networkUnavailable
            let current = try await loadCredential()
            try await identityGuard.verify(current.accountFingerprint)
            guard credential.token == current.token, credential.deviceID == current.deviceID,
                  credential.accountFingerprint == current.accountFingerprint else { throw QuotaProviderError.accountChanged }
            throw safeError
        }
        let current = try await loadCredential()
        try await identityGuard.verify(current.accountFingerprint)
        guard credential.token == current.token, credential.deviceID == current.deviceID,
              credential.accountFingerprint == current.accountFingerprint else { throw QuotaProviderError.accountChanged }
        let fingerprint = credential.accountFingerprint
        try Task.checkCancellation()
        return (data, fingerprint, now())
    }

    private func loadCredential() async throws -> LocalProviderCredential {
        do { return try await credentialsLoader() }
        catch is CancellationError { throw CancellationError() }
        catch let error as QuotaProviderError {
            throw error == .invalidResponse ? QuotaProviderError.authenticationRequired : error
        }
        catch { throw QuotaProviderError.accessRequired }
    }
}

private enum ManusLocalSession {
    static func load(_ product: ManusProduct) throws -> LocalProviderCredential {
        guard product.installedURL != nil else { throw QuotaProviderError.notInstalled }
        let profile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(product.profileName, isDirectory: true)
        let cookieFiles = [profile.appendingPathComponent("Cookies"), profile.appendingPathComponent("Network/Cookies")]
        guard let database = cookieFiles.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw QuotaProviderError.authenticationRequired
        }
        let deviceID: String?
        if product == .cue {
            deviceID = (try? String(contentsOf: profile.appendingPathComponent("device-id"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let data = try? Data(contentsOf: profile.appendingPathComponent("localStorage.json")),
                  let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            deviceID = fields["deviceId"] as? String
        } else { deviceID = nil }
        return try ElectronCookieReader(applicationName: product.appName, databaseURL: database)
            .loadSession(host: "api.manus.im", deviceID: deviceID.flatMap { validDeviceID($0) ? $0 : nil })
    }

    static func validDeviceID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9-]{8,64}$", options: .regularExpression) != nil
    }
}
