import Combine
import Foundation

@MainActor
final class ProviderPreferences: ObservableObject {
    static let builtInProviderIDs: Set<String> = ["codex", "grok", "manus", "cue", "muse"]
    @Published private(set) var defaultProviderID: String
    @Published private(set) var enabledProviderIDs: Set<String>
    @Published private(set) var importedFilePaths: [String: String]

    private let defaults: UserDefaults
    private var knownProviderIDs: Set<String>
    private static let defaultKey = "AIQuota.defaultProviderID"
    private static let enabledKey = "AIQuota.enabledProviderIDs"
    private static let importedKey = "AIQuota.importedFilePaths"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let imports = (defaults.dictionary(forKey: Self.importedKey) as? [String: String] ?? [:])
            .filter { $0.key.hasPrefix("custom.") && $0.value.hasPrefix("/") }
        let known = Self.builtInProviderIDs.union(imports.keys)
        let savedDefault = defaults.string(forKey: Self.defaultKey) ?? "codex"
        var selectedDefault = known.contains(savedDefault) ? savedDefault : "codex"
        var enabled = defaults.stringArray(forKey: Self.enabledKey).map { Set($0).intersection(known) } ?? known
        if enabled.isEmpty { enabled = ["codex"] }
        if !enabled.contains(selectedDefault) {
            selectedDefault = enabled.contains("codex") ? "codex" : enabled.sorted().first!
        }
        importedFilePaths = imports
        knownProviderIDs = known
        defaultProviderID = selectedDefault
        enabledProviderIDs = enabled
    }

    func setDefaultProviderID(_ id: String) {
        guard knownProviderIDs.contains(id), enabledProviderIDs.contains(id) else { return }
        defaultProviderID = id
        persist()
    }

    func setEnabledProviderID(_ id: String, enabled: Bool) {
        guard knownProviderIDs.contains(id) else { return }
        if enabled { enabledProviderIDs.insert(id) }
        else { enabledProviderIDs.remove(id) }
        if enabledProviderIDs.isEmpty { enabledProviderIDs.insert("codex") }
        if !enabledProviderIDs.contains(defaultProviderID) {
            if id != "codex" {
                enabledProviderIDs.insert("codex")
                defaultProviderID = "codex"
            } else { defaultProviderID = enabledProviderIDs.sorted().first! }
        }
        persist()
    }

    @discardableResult
    func registerImportedProvider(id: String, fileURL: URL) -> Bool {
        guard id.hasPrefix("custom."), !Self.builtInProviderIDs.contains(id), importedFilePaths[id] == nil,
              fileURL.isFileURL else { return false }
        importedFilePaths[id] = fileURL.path
        knownProviderIDs.insert(id)
        enabledProviderIDs.insert(id)
        persist()
        return true
    }

    func removeImportedProvider(id: String) {
        guard importedFilePaths.removeValue(forKey: id) != nil else { return }
        knownProviderIDs.remove(id)
        enabledProviderIDs.remove(id)
        if defaultProviderID == id || enabledProviderIDs.isEmpty {
            enabledProviderIDs.insert("codex")
            defaultProviderID = "codex"
        }
        persist()
    }

    /// Called after restoring valid imports, so unavailable extensions cannot become the menu default.
    func reconcileProviderIDs(_ available: Set<String>) {
        knownProviderIDs = available.union(["codex"])
        enabledProviderIDs.formIntersection(knownProviderIDs)
        if enabledProviderIDs.isEmpty { enabledProviderIDs.insert("codex") }
        if !knownProviderIDs.contains(defaultProviderID) || !enabledProviderIDs.contains(defaultProviderID) {
            enabledProviderIDs.insert("codex")
            defaultProviderID = "codex"
        }
        persist()
    }

    private func persist() {
        defaults.set(defaultProviderID, forKey: Self.defaultKey)
        defaults.set(enabledProviderIDs.sorted(), forKey: Self.enabledKey)
        defaults.set(importedFilePaths, forKey: Self.importedKey)
    }
}
