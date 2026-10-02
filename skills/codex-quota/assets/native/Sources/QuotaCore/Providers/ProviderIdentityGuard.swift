import Foundation

/// Detect an account switch before any request, including requests that later fail.
/// Each provider owns one guard for its lifetime; snapshots are never persisted.
public actor ProviderIdentityGuard {
    private var lastFingerprint: String?

    public init() {}

    public func verify(_ fingerprint: String) throws {
        guard !fingerprint.isEmpty else { throw QuotaProviderError.authenticationRequired }
        let previous = lastFingerprint
        lastFingerprint = fingerprint
        if let previous, previous != fingerprint { throw QuotaProviderError.accountChanged }
    }
}
