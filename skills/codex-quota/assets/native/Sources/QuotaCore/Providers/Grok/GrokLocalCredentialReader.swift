import Foundation
import CryptoKit

public struct GrokCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: String
    public let machineID: String?
    public let accountFingerprint: String
    public let teamID: Int?

    public init(token: String, machineID: String? = nil, accountFingerprint: String? = nil, teamID: Int? = nil) {
        self.token = token
        self.machineID = machineID
        self.accountFingerprint = accountFingerprint ?? Self.fingerprint(token)
        self.teamID = teamID
    }

    public var description: String { "GrokCredential(<redacted>)" }
    public var debugDescription: String { description }

    var scopeFingerprint: String {
        Self.fingerprint(accountFingerprint + "|team:" + (teamID.map(String.init) ?? "personal"))
    }

    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct GrokLocalCredentialReader: Sendable {
    public init() {}

    public func load() throws -> GrokCredential {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        guard [URL(fileURLWithPath: "/Applications/Grok Bot.app"), home.appendingPathComponent("Applications/Grok Bot.app")]
            .contains(where: { manager.fileExists(atPath: $0.path) }) else { throw QuotaProviderError.notInstalled }
        let support = home.appendingPathComponent("Library/Application Support")
        let files = ["Grok Bot", "Sand"].map { support.appendingPathComponent($0).appendingPathComponent("sand-secrets.json") }
        guard let file = files.first(where: { manager.fileExists(atPath: $0.path) }) else { throw QuotaProviderError.authenticationRequired }
        let data: Data
        do {
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 2_097_152 else { throw QuotaProviderError.invalidResponse }
            data = try Data(contentsOf: file)
        } catch let error as QuotaProviderError { throw error }
        catch { throw QuotaProviderError.accessRequired }
        let decryptor = ElectronSafeStorageDecryptor(applicationName: "Grok Bot")
        return try Self.decode(data, decrypt: { value in
            guard let ciphertext = Data(base64Encoded: value) else { throw QuotaProviderError.invalidResponse }
            var plain = try decryptor.decrypt(ciphertext)
            defer { plain.resetBytes(in: 0..<plain.count) }
            guard let text = String(data: plain, encoding: .utf8) else { throw QuotaProviderError.invalidResponse }
            return text
        }, now: Date())
    }

    static func decode(_ data: Data, decrypt: (String) throws -> String, now: Date) throws -> GrokCredential {
        guard data.count <= 2_097_152 else { throw QuotaProviderError.invalidResponse }
        do {
            let record = try JSONDecoder().decode(SecretRecord.self, from: data)
            guard record.version == nil || record.version == 1 else { throw QuotaProviderError.invalidResponse }
            let fields: [String: String]
            let active: String?
            if let accountText = record.cursorAccounts {
                let accounts = try JSONDecoder().decode(Accounts.self, from: Data(accountText.utf8))
                guard let selected = accounts.active else { throw QuotaProviderError.authenticationRequired }
                guard let account = accounts.accounts[selected] else { throw QuotaProviderError.invalidResponse }
                fields = account
                active = selected
            } else {
                fields = ["cursor-access-token": record.accessToken, "cursor-selected-team-id": record.selectedTeamID].compactMapValues { $0 }
                active = nil
            }
            guard let storedToken = fields["cursor-access-token"] else { throw QuotaProviderError.authenticationRequired }
            let token = try secret(storedToken, expectedScope: active, decrypt: decrypt)
            guard token.utf8.count <= 65_536, !token.contains("\r"), !token.contains("\n"), !token.contains("\0") else { throw QuotaProviderError.invalidResponse }
            let parts = token.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw QuotaProviderError.authenticationRequired }
            var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            guard let payloadData = Data(base64Encoded: payload) else { throw QuotaProviderError.authenticationRequired }
            let identity = try JSONDecoder().decode(TokenIdentity.self, from: payloadData)
            guard let subject = identity.sub, !subject.isEmpty, let expiry = identity.exp,
                  expiry.isFinite, expiry > now.timeIntervalSince1970 else { throw QuotaProviderError.authenticationRequired }
            let fingerprint = GrokCredential.fingerprint(subject)
            guard active == nil || active == fingerprint else { throw QuotaProviderError.accountChanged }
            var teamID: Int?
            if let storedTeam = fields["cursor-selected-team-id"] {
                let team = try secret(storedTeam, expectedScope: fingerprint, decrypt: decrypt)
                guard let value = Int(team), value > 0 else { throw QuotaProviderError.invalidResponse }
                teamID = value
            }
            let machineID = try record.machineID.map { try secret($0, expectedScope: nil, decrypt: decrypt) }
            return GrokCredential(token: token, machineID: machineID, accountFingerprint: fingerprint, teamID: teamID)
        } catch let error as QuotaProviderError { throw error }
        catch { throw QuotaProviderError.invalidResponse }
    }

    private static func secret(_ value: String, expectedScope: String?, decrypt: (String) throws -> String) throws -> String {
        if value.hasPrefix("plaintext:v1:") {
            guard let plain = Data(base64Encoded: String(value.dropFirst("plaintext:v1:".count))),
                  let string = String(data: plain, encoding: .utf8) else { throw QuotaProviderError.invalidResponse }
            return string
        }
        if value.hasPrefix("scoped:v1:") {
            let parts = value.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[2].count == 64, parts[2].allSatisfy({ $0.isHexDigit }),
                  expectedScope == nil || String(parts[2]) == expectedScope else { throw QuotaProviderError.accountChanged }
            return try decrypt(String(parts[3]))
        }
        return try decrypt(value)
    }

    private struct Accounts: Decodable {
        let active: String?
        let accounts: [String: [String: String]]
    }
    private struct TokenIdentity: Decodable { let sub: String?; let exp: Double? }
    private struct SecretRecord: Decodable {
        let version: Int?
        let cursorAccounts: String?
        let accessToken: String?
        let selectedTeamID: String?
        let machineID: String?
        enum CodingKeys: String, CodingKey {
            case version
            case cursorAccounts = "cursor-accounts"
            case accessToken = "cursor-access-token"
            case selectedTeamID = "cursor-selected-team-id"
            case machineID = "cursor-machine-id"
        }
    }
}
