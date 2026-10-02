import CryptoKit
import Foundation
import QuotaCore

enum MuseWebCredential {
    static func decodeAuthCheck(_ value: Any, previous: LocalProviderCredential? = nil) throws -> LocalProviderCredential {
        guard let result = value as? [String: Any],
              let status = result["httpStatus"] as? Int,
              let payload = result["payload"] as? [String: Any] else {
            throw MuseWebAuthenticationError.invalidResponse
        }
        if status == 401 { throw MuseWebAuthenticationError.loginRequired }
        if status == 403, payload["type"] as? String == "checkpointRequired" {
            throw MuseWebAuthenticationError.checkpointRequired
        }
        if status == 403, payload["type"] as? String == "hatchAdmissionInvalidated",
           ["entitlement", "activation"].contains(payload["reason"] as? String ?? ""),
           payload["status"] as? Int == 403 {
            throw MuseWebAuthenticationError.accessRestricted
        }
        guard (200..<300).contains(status) else {
            throw MuseWebAuthenticationError.requestRejected(status)
        }
        guard payload["outcome"] as? String == "validated" else {
            throw MuseWebAuthenticationError.loginRequired
        }
        guard let viewer = payload["viewer_id"] as? String, !viewer.isEmpty,
              let bindingValue = payload["session_binding_id"],
              bindingValue is String || bindingValue is NSNull else {
            throw MuseWebAuthenticationError.invalidResponse
        }
        let fingerprint = identityFingerprint(viewer: viewer, binding: bindingValue as? String ?? "")
        if let token = payload["access_token"] as? String,
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LocalProviderCredential(token: token, accountFingerprint: fingerprint)
        }
        // The public frontend treats access_token as optional on revalidation.
        // Reuse only a token previously issued for this exact viewer + binding.
        if let previous, previous.accountFingerprint == fingerprint {
            return previous
        }
        throw MuseWebAuthenticationError.tokenUnavailable
    }
    private static func identityFingerprint(viewer: String, binding: String) -> String {
        let identity = Data((viewer + "\u{0}" + binding).utf8)
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}
