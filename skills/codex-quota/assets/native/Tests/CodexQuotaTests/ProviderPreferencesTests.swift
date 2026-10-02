import Foundation
import XCTest
import QuotaCore
@testable import CodexQuota

@MainActor
final class ProviderPreferencesTests: XCTestCase {
    func testInitialCodexAndDefaultSurvivesRestart() throws {
        let name = "ProviderPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = ProviderPreferences(defaults: defaults)
        XCTAssertEqual(first.defaultProviderID, "codex")
        XCTAssertEqual(first.enabledProviderIDs, Set(["codex", "grok", "manus", "cue", "muse"]))
        first.setDefaultProviderID("muse")
        let restarted = ProviderPreferences(defaults: defaults)
        XCTAssertEqual(restarted.defaultProviderID, "muse")
    }

    func testHidingDefaultFallsBackAndNeverLeavesNoEnabledProvider() throws {
        let name = "ProviderPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ProviderPreferences(defaults: defaults)
        preferences.setDefaultProviderID("muse")
        preferences.setEnabledProviderID("muse", enabled: false)
        XCTAssertEqual(preferences.defaultProviderID, "codex")
        for id in ["grok", "manus", "cue", "codex"] { preferences.setEnabledProviderID(id, enabled: false) }
        XCTAssertEqual(preferences.enabledProviderIDs, ["codex"])
        XCTAssertEqual(preferences.defaultProviderID, "codex")
    }

    func testRemovingImportedDefaultFallsBackAndCannotRemoveBuiltin() throws {
        let name = "ProviderPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ProviderPreferences(defaults: defaults)
        preferences.registerImportedProvider(id: "custom.example", fileURL: URL(fileURLWithPath: "/tmp/example.json"))
        preferences.setDefaultProviderID("custom.example")
        preferences.removeImportedProvider(id: "custom.example")
        preferences.removeImportedProvider(id: "codex")
        XCTAssertEqual(preferences.defaultProviderID, "codex")
        XCTAssertNil(preferences.importedFilePaths["custom.example"])
        XCTAssertTrue(preferences.enabledProviderIDs.contains("codex"))
    }

    func testImportRejectsBuiltinAndDuplicateIDWithoutReplacingProvider() throws {
        let name = "ProviderPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, id: String, balance: Int) throws -> URL {
            let file = root.appendingPathComponent(name)
            let text = """
            {"schemaVersion":1,"id":"\(id)","name":"Example","observedAt":"2026-01-01T00:00:00Z","metrics":[{"id":"monthly","label":"Month","remaining":\(balance),"limit":100}]}
            """
            try Data(text.utf8).write(to: file)
            return file
        }
        let codex = QuotaStore(start: false, journal: PreferencesEmptyJournal())
        let store = AIQuotaStore(codex: codex, providers: [], preferences: ProviderPreferences(defaults: defaults), start: false)
        XCTAssertThrowsError(try store.importProvider(fileURL: file("builtin.json", id: "codex", balance: 10)))
        try store.importProvider(fileURL: file("first.json", id: "custom.example", balance: 25))
        XCTAssertThrowsError(try store.importProvider(fileURL: file("second.json", id: "custom.example", balance: 90)))
        XCTAssertEqual(store.descriptors.filter { $0.id == "custom.example" }.count, 1)
        XCTAssertEqual(store.defaultProviderID, "codex")
    }

    func testMissingImportedFileCanBeImportedAgainAtNewPath() throws {
        let name = "ProviderPreferencesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = ProviderPreferences(defaults: defaults)
        preferences.registerImportedProvider(id: "custom.example", fileURL: root.appendingPathComponent("missing.json"))
        preferences.setDefaultProviderID("custom.example")
        let codex = QuotaStore(start: false, journal: PreferencesEmptyJournal())
        let store = AIQuotaStore(codex: codex, providers: [], preferences: preferences, start: false)
        XCTAssertEqual(store.defaultProviderID, "codex")
        XCTAssertFalse(store.descriptors.contains { $0.id == "custom.example" })
        let restoredFile = root.appendingPathComponent("restored.json")
        let document = """
        {"schemaVersion":1,"id":"custom.example","name":"Example","observedAt":"2026-01-01T00:00:00Z","metrics":[{"id":"monthly","label":"Month","remaining":25,"limit":100}]}
        """
        try Data(document.utf8).write(to: restoredFile)
        XCTAssertNoThrow(try store.importProvider(fileURL: restoredFile))
        XCTAssertEqual(preferences.importedFilePaths["custom.example"], restoredFile.path)
        XCTAssertTrue(store.enabledProviderIDs.contains("custom.example"))
        XCTAssertEqual(store.descriptors.filter { $0.id == "custom.example" }.count, 1)
    }
}

private struct PreferencesEmptyJournal: ResetIntentStoring {
    func load() throws -> ResetIntent? { nil }
    func save(_ intent: ResetIntent) throws {}
    func clear() throws {}
}
