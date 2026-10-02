import Foundation
import CommonCrypto
import Security
import LocalAuthentication

/// Chromium's macOS v10 format, verified against Electron 42.1.0 / Chromium 148.
public struct ElectronSafeStorageDecryptor: Sendable {
    static let supportedApplications: Set<String> = ["Grok Bot", "Cue", "Manus Studio"]
    private let applicationName: String
    private let passwordLoader: @Sendable () throws -> Data

    public init(applicationName: String) {
        self.init(applicationName: applicationName, passwordLoader: {
            try Self.keychainPassword(applicationName: applicationName, allowInteraction: false)
        })
    }

    init(applicationName: String, passwordLoader: @escaping @Sendable () throws -> Data) {
        self.applicationName = applicationName
        self.passwordLoader = passwordLoader
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard Self.supportedApplications.contains(applicationName) else { throw QuotaProviderError.accessRequired }
        guard ciphertext.count >= 19, ciphertext.count <= 131_072,
              ciphertext.prefix(3) == Data("v10".utf8), (ciphertext.count - 3) % 16 == 0 else {
            throw QuotaProviderError.invalidResponse
        }
        var password = try passwordLoader()
        defer { password.resetBytes(in: 0..<password.count) }
        guard !password.isEmpty else { throw QuotaProviderError.accessRequired }
        var key = [UInt8](repeating: 0, count: 16)
        defer { _ = key.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let salt = Data("saltysalt".utf8)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                    passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                                    saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        guard status == kCCSuccess else { throw QuotaProviderError.invalidResponse }
        let body = Data(ciphertext.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: body.count + 16)
        var written = 0
        let cryptoStatus = body.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, bytes.baseAddress, body.count, &output, output.count, &written)
        }
        guard cryptoStatus == kCCSuccess else { throw QuotaProviderError.invalidResponse }
        return Data(output.prefix(written))
    }

    /// Call only from an explicit user action. Background decryption always fails without prompting.
    public static func authorizeAccess(applicationName: String) throws {
        var password = try keychainPassword(applicationName: applicationName, allowInteraction: true)
        password.resetBytes(in: 0..<password.count)
    }

    private static func keychainPassword(applicationName: String, allowInteraction: Bool) throws -> Data {
        guard supportedApplications.contains(applicationName) else { throw QuotaProviderError.accessRequired }
        // Inspect only this application's encryption-key metadata first. Some
        // Electron builds retain the older "<app> Key" account naming convention.
        let metadata = try keychainMetadata(applicationName: applicationName)
        let account = try keychainAccount(applicationName: applicationName, accounts: metadata)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: applicationName + " Safe Storage",
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        if !allowInteraction {
            // Keep this explicit legacy-ACL guard: LAContext alone blocked in a
            // real macOS safe-storage lookup despite interactionNotAllowed=true.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw keychainError(status: status) }
        guard let data = result as? Data, !data.isEmpty else { throw QuotaProviderError.invalidResponse }
        return data
    }

    private static func keychainMetadata(applicationName: String) throws -> [String] {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: applicationName + " Safe Storage",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw keychainError(status: status) }
        guard let rows = result as? [[String: Any]] else { throw QuotaProviderError.invalidResponse }
        return try rows.map { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  row[kSecAttrService as String] as? String == applicationName + " Safe Storage" else {
                throw QuotaProviderError.invalidResponse
            }
            return account
        }
    }

    static func keychainAccount(applicationName: String, accounts: [String]) throws -> String {
        guard supportedApplications.contains(applicationName) else { throw QuotaProviderError.accessRequired }
        guard !accounts.isEmpty else { throw QuotaProviderError.authenticationRequired }
        guard accounts.count == 1, let account = accounts.first,
              [applicationName, applicationName + " Key"].contains(account) else { throw QuotaProviderError.invalidResponse }
        return account
    }

    static func keychainError(status: OSStatus) -> QuotaProviderError {
        status == errSecItemNotFound ? .authenticationRequired : .accessRequired
    }
}

public func authorizeAccess(applicationName: String) throws {
    try ElectronSafeStorageDecryptor.authorizeAccess(applicationName: applicationName)
}
