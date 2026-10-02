import Foundation

public struct MuseQuotaProvider: QuotaProvider {
    public let descriptor = ProviderDescriptor(id: "muse", name: "Muse", bundleIdentifier: "com.meta.endo")
    private let credentialsLoader: @Sendable () async throws -> LocalProviderCredential
    private let transport: any QuotaHTTPTransport
    private let disconnectHandler: @Sendable () async -> Void
    private let identityGuard = ProviderIdentityGuard()

    /// The app supplies its own Muse web session. Meta's signed keychain group
    /// is intentionally not opened by this adapter.
    public init(credentialsLoader: @escaping @Sendable () async throws -> LocalProviderCredential = {
        throw QuotaProviderError.authenticationRequired
    }, transport: any QuotaHTTPTransport = URLSessionQuotaTransport(allowedHosts: ["hatch-api.meta.ai"]),
                disconnectHandler: @escaping @Sendable () async -> Void = {}) {
        self.credentialsLoader = credentialsLoader
        self.transport = transport
        self.disconnectHandler = disconnectHandler
    }

    public func fetchQuota() async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        let credentials = try await loadCredentials()
        guard !credentials.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuotaProviderError.authenticationRequired
        }
        try await identityGuard.verify(credentials.accountFingerprint)
        // Verified against the native Muse 5.0 request builder. Omitting
        // include=agreement avoids requesting payment and agreement details.
        let url = URL(string: "https://hatch-api.meta.ai/hatch/subscription")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        do {
            data = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // A failed request may overlap an account switch or logout. Only
            // retain the transport failure after the same identity is confirmed.
            let current = try await loadCredentials()
            try await identityGuard.verify(current.accountFingerprint)
            guard current.accountFingerprint == credentials.accountFingerprint else {
                throw QuotaProviderError.accountChanged
            }
            throw (error as? QuotaProviderError ?? QuotaProviderError.networkUnavailable)
        }
        try Task.checkCancellation()
        let current = try await loadCredentials()
        try await identityGuard.verify(current.accountFingerprint)
        guard current.accountFingerprint == credentials.accountFingerprint else {
            throw QuotaProviderError.accountChanged
        }
        return try MuseQuotaDecoder.decode(data, accountFingerprint: credentials.accountFingerprint)
    }

    public func disconnect() async {
        await disconnectHandler()
    }

    private func loadCredentials() async throws -> LocalProviderCredential {
        do {
            return try await credentialsLoader()
        } catch is CancellationError {
            throw CancellationError()
        } catch QuotaProviderError.invalidResponse {
            // A credential decode failure cannot establish that an old snapshot
            // still belongs to the active account.
            throw QuotaProviderError.authenticationRequired
        } catch let error as QuotaProviderError {
            throw error
        } catch {
            throw QuotaProviderError.authenticationRequired
        }
    }
}
