import Foundation

public struct GrokQuotaProvider: QuotaProvider {
    public let descriptor = ProviderDescriptor(id: "grok", name: "Grok Bot", bundleIdentifier: "com.anysphere.sand", refreshInterval: 300)
    private let transport: any QuotaHTTPTransport
    private let credentialsLoader: @Sendable () async throws -> GrokCredential
    private let now: @Sendable () -> Date
    private let identityGuard = ProviderIdentityGuard()

    public init(transport: any QuotaHTTPTransport = URLSessionQuotaTransport(allowedHosts: ["api2.cursor.sh"]),
                credentialsLoader: @escaping @Sendable () async throws -> GrokCredential = { try GrokLocalCredentialReader().load() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.credentialsLoader = credentialsLoader
        self.now = now
    }

    public func fetchQuota() async throws -> ProviderSnapshot {
        do {
            try Task.checkCancellation()
            let credential = try await loadCredentials()
            try await identityGuard.verify(credential.scopeFingerprint)
            do {
                let observedAt = now()
                let usageRequest = request(method: "GetSandUsageStatus", credential: credential, at: observedAt)
                let currentRequest = request(method: "GetCurrentPeriodUsage", credential: credential, at: observedAt)
                async let usage = transport.send(usageRequest)
                async let current = optionalCurrentPeriod(currentRequest)
                let metrics = try await GrokUsageDecoder.decode(usage: usage, currentPeriod: current)
                try await verifyCredentialScope(credential)
                try Task.checkCancellation()
                return ProviderSnapshot(providerID: descriptor.id, accountFingerprint: credential.scopeFingerprint,
                                        metrics: metrics, observedAt: now())
            } catch is CancellationError { throw CancellationError() }
            catch let error as QuotaProviderError where error.invalidatesSnapshot { throw error }
            catch {
                try Task.checkCancellation()
                try await verifyCredentialScope(credential)
                throw error
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as QuotaProviderError { throw error }
        catch { throw QuotaProviderError.requestFailed }
    }

    private func loadCredentials() async throws -> GrokCredential {
        do { return try await credentialsLoader() }
        catch QuotaProviderError.invalidResponse { throw QuotaProviderError.authenticationRequired }
    }

    private func verifyCredentialScope(_ original: GrokCredential) async throws {
        let latest = try await loadCredentials()
        try await identityGuard.verify(latest.scopeFingerprint)
        guard latest.scopeFingerprint == original.scopeFingerprint else { throw QuotaProviderError.accountChanged }
    }

    private func optionalCurrentPeriod(_ request: URLRequest) async throws -> Data? {
        do { return try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as QuotaProviderError where error.invalidatesSnapshot { throw error }
        catch { return nil }
    }

    private func request(method: String, credential: GrokCredential, at date: Date) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/" + method)!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("0.66.0", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("darwin", forHTTPHeaderField: "x-cursor-client-os")
        request.setValue("prod", forHTTPHeaderField: "x-sand-box-namespace")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Sand/0.66.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if let teamID = credential.teamID { request.setValue(String(teamID), forHTTPHeaderField: "x-cursor-team-id") }
        if let machineID = credential.machineID, !machineID.isEmpty {
            request.setValue(checksum(machineID: machineID, at: date), forHTTPHeaderField: "x-cursor-checksum")
        }
        return request
    }

    private func checksum(machineID: String, at date: Date) -> String {
        let time = Int64(floor(date.timeIntervalSince1970 / 1000))
        // JavaScript bit shifts use shift modulo 32 in the original createCursorChecksum.
        let shifts: [Int64] = [8, 0, 24, 16, 8, 0]
        var previous: UInt8 = 165
        let bytes = shifts.enumerated().map { index, shift -> UInt8 in
            let value = (UInt8(truncatingIfNeeded: time >> shift) ^ previous) &+ UInt8(index)
            previous = value
            return value
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + machineID
    }
}
