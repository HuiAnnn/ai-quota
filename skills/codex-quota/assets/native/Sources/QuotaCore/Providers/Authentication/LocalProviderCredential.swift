import Foundation
import CryptoKit

/// Credentials remain in memory and cannot be encoded or printed through this type.
public struct LocalProviderCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let deviceID: String?
    public let accountFingerprint: String

    public init(token: String, deviceID: String? = nil, accountFingerprint: String? = nil) {
        self.token = token
        self.deviceID = deviceID
        self.accountFingerprint = accountFingerprint ?? SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { "LocalProviderCredential(<redacted>)" }
    public var debugDescription: String { description }
}
