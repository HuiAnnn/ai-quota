import XCTest
import Foundation
import CryptoKit
import SQLite3
@testable import QuotaCore

final class ElectronAuthenticationTests: XCTestCase {
    func testCredentialFingerprintIsStableAndDescriptionsHideSecrets() {
        let credential = LocalProviderCredential(token: "abc", deviceID: "private-device")
        XCTAssertEqual(credential.accountFingerprint, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertFalse(String(describing: credential).contains("abc"))
        XCTAssertFalse(String(reflecting: credential).contains("private-device"))
    }

    func testChromiumSafeStorageFixtureDecryptsWithVerifiedMacParameters() throws {
        let decryptor = ElectronSafeStorageDecryptor(applicationName: "Cue", passwordLoader: { Data("fixture-password".utf8) })
        let encrypted = try XCTUnwrap(Data(base64Encoded: "djEwMCVwdu+joCzJ0wc3lWCSug=="))
        XCTAssertEqual(try decryptor.decrypt(encrypted), Data("fixture-session".utf8))
    }

    func testUnsupportedApplicationCannotReadKeychain() {
        let decryptor = ElectronSafeStorageDecryptor(applicationName: "External App", passwordLoader: { XCTFail("must not read keychain"); return Data() })
        XCTAssertThrowsError(try decryptor.decrypt(Data("v10-invalid".utf8))) { XCTAssertEqual($0 as? QuotaProviderError, .accessRequired) }
    }

    func testInvalidEncryptionAndDeniedKeychainAreSafeErrors() {
        let denied = ElectronSafeStorageDecryptor(applicationName: "Cue", passwordLoader: { throw QuotaProviderError.accessRequired })
        XCTAssertThrowsError(try denied.decrypt(Data(base64Encoded: "djEwMCVwdu+joCzJ0wc3lWCSug==")!)) { XCTAssertEqual($0 as? QuotaProviderError, .accessRequired) }
        let decoder = ElectronSafeStorageDecryptor(applicationName: "Cue", passwordLoader: { Data("fixture-password".utf8) })
        XCTAssertThrowsError(try decoder.decrypt(Data("v20-other-data".utf8))) { XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse) }
    }

    func testKeychainMetadataSelectsTheActualElectronAccountWithoutGuessing() throws {
        XCTAssertEqual(try ElectronSafeStorageDecryptor.keychainAccount(applicationName: "Grok Bot", accounts: ["Grok Bot Key"]), "Grok Bot Key")
        XCTAssertEqual(try ElectronSafeStorageDecryptor.keychainAccount(applicationName: "Grok Bot", accounts: ["Grok Bot"]), "Grok Bot")
        XCTAssertThrowsError(try ElectronSafeStorageDecryptor.keychainAccount(applicationName: "Grok Bot", accounts: [])) {
            XCTAssertEqual($0 as? QuotaProviderError, .authenticationRequired)
        }
        for accounts in [["Grok Bot", "Grok Bot Key"], ["unexpected-owner"]] {
            XCTAssertThrowsError(try ElectronSafeStorageDecryptor.keychainAccount(applicationName: "Grok Bot", accounts: accounts)) {
                XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse)
            }
        }
    }

    func testMissingKeychainItemIsDistinctFromDeniedInteraction() {
        XCTAssertEqual(ElectronSafeStorageDecryptor.keychainError(status: -25300), .authenticationRequired)
        XCTAssertEqual(ElectronSafeStorageDecryptor.keychainError(status: -25308), .accessRequired)
        XCTAssertEqual(ElectronSafeStorageDecryptor.keychainError(status: -25293), .accessRequired)
    }

    func testCookieReaderOnlyReadsRequestedSessionAndDoesNotModifyDatabase() throws {
        let url = try database(version: 24, rows: [("api.manus.im", "session_id", "opaque-session"), ("other.example", "session_id", "unrelated")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        let plain = Data(SHA256.hash(data: Data("api.manus.im".utf8))) + Data("fixture-session".utf8)
        let reader = ElectronCookieReader(applicationName: "Cue", databaseURL: url, decrypt: { _ in plain })
        let credential = try reader.loadSession(host: "api.manus.im", deviceID: "fixture-device")
        XCTAssertEqual(credential.token, "fixture-session")
        XCTAssertEqual(credential.deviceID, "fixture-device")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try reader.loadSession(host: "other.example")) { XCTAssertEqual($0 as? QuotaProviderError, .accessRequired) }
        XCTAssertThrowsError(try reader.loadSession(host: "api.manus.im", name: "other_cookie")) { XCTAssertEqual($0 as? QuotaProviderError, .accessRequired) }
    }

    func testV24CookieCannotBeReusedForAnotherHost() throws {
        let url = try database(version: 24, rows: [("api.manus.im", "session_id", "opaque-session")])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let wrongHost = Data(SHA256.hash(data: Data("other.example".utf8))) + Data("fixture-session".utf8)
        let reader = ElectronCookieReader(applicationName: "Manus Studio", databaseURL: url, decrypt: { _ in wrongHost })
        XCTAssertThrowsError(try reader.loadSession(host: "api.manus.im")) { XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse) }
    }

    func testMissingAndAmbiguousSessionAreNotInvented() throws {
        for rows in [[], [("api.manus.im", "session_id", "first"), ("api.manus.im", "session_id", "second")]] {
            let url = try database(version: 24, rows: rows)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let reader = ElectronCookieReader(applicationName: "Cue", databaseURL: url, decrypt: { _ in Data() })
            XCTAssertThrowsError(try reader.loadSession(host: "api.manus.im")) { XCTAssertEqual($0 as? QuotaProviderError, rows.isEmpty ? .authenticationRequired : .invalidResponse) }
        }
    }

    private func database(version: Int, rows: [(String, String, String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Cookies")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','\(version)'); CREATE TABLE cookies(host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER);", nil, nil, nil), SQLITE_OK)
        for row in rows {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?,?, '', ?, 0)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_text(statement, 1, row.0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(statement, 2, row.1, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            let blob = Data(row.2.utf8)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(blob.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }
}
