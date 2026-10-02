import Foundation
import CryptoKit
import SQLite3

/// Reads only the Manus service's session cookie from its existing Electron profile.
public struct ElectronCookieReader: Sendable {
    private let applicationName: String
    private let databaseURL: URL
    private let decrypt: @Sendable (Data) throws -> Data

    public init(applicationName: String, databaseURL: URL) {
        self.init(applicationName: applicationName, databaseURL: databaseURL, decrypt: {
            try ElectronSafeStorageDecryptor(applicationName: applicationName).decrypt($0)
        })
    }

    init(applicationName: String, databaseURL: URL, decrypt: @escaping @Sendable (Data) throws -> Data) {
        self.applicationName = applicationName
        self.databaseURL = databaseURL
        self.decrypt = decrypt
    }

    public func loadSession(host: String, name: String = "session_id", deviceID: String? = nil) throws -> LocalProviderCredential {
        guard ["Cue", "Manus Studio"].contains(applicationName), host == "api.manus.im", name == "session_id" else {
            throw QuotaProviderError.accessRequired
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { throw QuotaProviderError.authenticationRequired }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(database)
            throw QuotaProviderError.accessRequired
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        let version = try schemaVersion(database)
        guard (1...24).contains(version) else { throw QuotaProviderError.invalidResponse }
        var statement: OpaquePointer?
        let query = "SELECT host_key, value, encrypted_value, expires_utc FROM cookies WHERE (host_key = ? OR host_key = ?) AND name = ? LIMIT 3"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { throw QuotaProviderError.invalidResponse }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, host, -1, transient)
        sqlite3_bind_text(statement, 2, "." + host, -1, transient)
        sqlite3_bind_text(statement, 3, name, -1, transient)
        var candidates: [(String, String, Data)] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let expiry = sqlite3_column_int64(statement, 3)
            if expiry == 0 || Double(expiry) / 1_000_000 - 11_644_473_600 > Date().timeIntervalSince1970 {
                let domain = text(statement, column: 0)
                let value = text(statement, column: 1)
                let count = Int(sqlite3_column_bytes(statement, 2))
                guard count <= 131_072 else { throw QuotaProviderError.invalidResponse }
                let encrypted = sqlite3_column_blob(statement, 2).map { Data(bytes: $0, count: count) } ?? Data()
                candidates.append((domain, value, encrypted))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw QuotaProviderError.requestFailed }
        guard candidates.count == 1 else {
            throw candidates.isEmpty ? QuotaProviderError.authenticationRequired : QuotaProviderError.invalidResponse
        }
        let (domain, value, encrypted) = candidates[0]
        guard value.isEmpty || encrypted.isEmpty else { throw QuotaProviderError.invalidResponse }
        let token: String
        if encrypted.isEmpty {
            token = value
        } else {
            var plain = try decrypt(encrypted)
            defer { plain.resetBytes(in: 0..<plain.count) }
            if version >= 24 {
                let digest = Data(SHA256.hash(data: Data(domain.utf8)))
                guard plain.count >= digest.count, plain.prefix(digest.count) == digest else { throw QuotaProviderError.invalidResponse }
                plain = Data(plain.dropFirst(digest.count))
            }
            guard let decoded = String(data: plain, encoding: .utf8) else { throw QuotaProviderError.invalidResponse }
            token = decoded
        }
        guard !token.isEmpty, token.utf8.count <= 65_536, !token.contains("\r"), !token.contains("\n") else {
            throw QuotaProviderError.authenticationRequired
        }
        return LocalProviderCredential(token: token, deviceID: deviceID)
    }

    private func schemaVersion(_ database: OpaquePointer?) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK else { throw QuotaProviderError.invalidResponse }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw QuotaProviderError.invalidResponse }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func text(_ statement: OpaquePointer?, column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
