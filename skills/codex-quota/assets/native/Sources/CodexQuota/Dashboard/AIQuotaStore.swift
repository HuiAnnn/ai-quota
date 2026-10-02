import AppKit
import Combine
import Foundation
import QuotaCore

@MainActor
final class AIQuotaStore: ObservableObject {
    @Published private(set) var descriptors: [ProviderDescriptor]
    @Published private(set) var enabledProviderIDs: Set<String>
    @Published private(set) var selectedProviderID: String
    @Published private(set) var defaultProviderID: String
    @Published private(set) var states: [String: ProviderState] = [:]

    let codex: QuotaStore
    let preferences: ProviderPreferences
    private var registry: ProviderRegistry
    private var stores: [String: ProviderStore] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var observers: [NSObjectProtocol] = []
    private let automaticallyStarts: Bool
    private var isStopped = false
    private var isSleeping = false

    init(codex: QuotaStore? = nil, providers: [any QuotaProvider] = ProviderRegistry.builtIns(),
         preferences: ProviderPreferences? = nil, start: Bool = true) {
        let codex = codex ?? QuotaStore.shared
        self.codex = codex
        let preferences = preferences ?? ProviderPreferences()
        self.preferences = preferences
        automaticallyStarts = start
        var registry = ProviderRegistry(providers: providers)
        for path in preferences.importedFilePaths.values.sorted() {
            _ = try? registry.addFile(URL(fileURLWithPath: path))
        }
        self.registry = registry
        let descriptors = registry.descriptors
        self.descriptors = descriptors
        preferences.reconcileProviderIDs(Set(descriptors.map(\.id)))
        enabledProviderIDs = preferences.enabledProviderIDs
        defaultProviderID = preferences.defaultProviderID
        selectedProviderID = preferences.defaultProviderID
        for provider in registry.providers { attach(provider, start: start && enabledProviderIDs.contains(provider.descriptor.id)) }
        subscriptions["codex"] = codex.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.publishStates() }
        }
        publishStates()
        if start {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pauseForSleep() }
            })
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.wake() }
            })
        }
    }

    var enabledDescriptors: [ProviderDescriptor] { descriptors.filter { enabledProviderIDs.contains($0.id) } }
    var selectedDescriptor: ProviderDescriptor? { descriptors.first { $0.id == selectedProviderID } }
    var defaultDescriptor: ProviderDescriptor? { descriptors.first { $0.id == defaultProviderID } }
    var summaryRemainingPercent: Double? { state(for: defaultProviderID)?.remainingPercent }
    var menuTitle: String {
        guard let remaining = summaryRemainingPercent else {
            return state(for: defaultProviderID)?.isRefreshing == true ? "···" : "—"
        }
        return QuotaStore.percentText(remaining)
    }

    func state(for id: String) -> ProviderState? {
        if id == "codex" {
            let snapshot = codex.snapshot.map { ProviderSnapshot.codex($0, observedAt: codex.updatedAt ?? Date()) }
            let error: QuotaProviderError? = codex.errorMessage == nil ? nil : (snapshot == nil ? .authenticationRequired : .requestFailed)
            return ProviderState(descriptor: ProviderRegistry.codexDescriptor, snapshot: snapshot,
                                 isRefreshing: codex.isBusy, error: error, errorMessage: codex.errorMessage,
                                 updatedAt: codex.updatedAt, isStale: snapshot != nil && codex.errorMessage != nil)
        }
        return stores[id]?.state
    }

    func selectDetail(_ id: String) {
        guard enabledProviderIDs.contains(id), descriptors.contains(where: { $0.id == id }) else { return }
        selectedProviderID = id
    }

    func setDefault(_ id: String) {
        preferences.setDefaultProviderID(id)
        synchronizePreferences()
    }

    func setEnabled(_ id: String, enabled: Bool) {
        guard descriptors.contains(where: { $0.id == id }) else { return }
        preferences.setEnabledProviderID(id, enabled: enabled)
        synchronizePreferences()
        if enabledProviderIDs.contains(id) {
            if !isStopped { stores[id]?.activate(automaticRefresh: automaticallyStarts, isSleeping: isSleeping) }
        } else if let store = stores[id] {
            store.suspend()
        }
        publishStates()
    }

    func requestRefresh(_ id: String? = nil) {
        guard !isStopped, !isSleeping else { return }
        for candidate in id.map({ [$0] }) ?? enabledDescriptors.map(\.id) {
            guard enabledProviderIDs.contains(candidate) else { continue }
            if candidate == "codex" { codex.requestRefresh() }
            else { stores[candidate]?.requestRefresh() }
        }
        publishStates()
    }

    /// Structured refresh used by diagnostics and manual actions; services execute independently.
    func refresh(_ id: String? = nil) async {
        guard !isStopped, !isSleeping else { return }
        let ids = (id.map { [$0] } ?? enabledDescriptors.map(\.id)).filter { enabledProviderIDs.contains($0) }
        if ids.contains("codex") { codex.requestRefresh() }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                guard let store = stores[id] else { continue }
                group.addTask { await store.refresh() }
            }
        }
        publishStates()
    }

    /// Wait for the independent providers without creating a new Codex app-server connection.
    func refreshAndWait() async {
        guard !isStopped, !isSleeping else { return }
        await withTaskGroup(of: Void.self) { group in
            for descriptor in enabledDescriptors where descriptor.id != "codex" {
                guard let store = stores[descriptor.id] else { continue }
                group.addTask { await store.refresh() }
            }
        }
        publishStates()
    }

    func panelDidOpen() {
        codex.updateLoginItemState()
        for descriptor in enabledDescriptors {
            if state(for: descriptor.id)?.updatedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
                requestRefresh(descriptor.id)
            }
        }
    }

    /// UI connection coordinators perform authorization, then invoke this refresh-only action.
    func connectMissingPermission(_ id: String) { requestRefresh(id) }
    func connect(_ id: String) { requestRefresh(id) }

    func importProvider(fileURL: URL) throws {
        let provider = try registry.addFile(fileURL)
        // Registry validation rejects active duplicates before a stale saved path is replaced.
        if preferences.importedFilePaths[provider.descriptor.id] != nil {
            preferences.removeImportedProvider(id: provider.descriptor.id)
        }
        guard preferences.registerImportedProvider(id: provider.descriptor.id, fileURL: fileURL) else {
            _ = registry.remove(provider.descriptor.id)
            throw QuotaFileError.invalidDocument
        }
        descriptors = registry.descriptors
        synchronizePreferences()
        attach(provider, start: automaticallyStarts && !isSleeping && !isStopped)
        publishStates()
    }

    func removeProvider(_ id: String) {
        guard registry.remove(id) != nil else { return }
        let store = stores.removeValue(forKey: id)
        subscriptions.removeValue(forKey: id)
        preferences.removeImportedProvider(id: id)
        descriptors = registry.descriptors
        synchronizePreferences()
        publishStates()
        if let store { Task { await store.stop() } }
    }

    func pauseForSleep() {
        isSleeping = true
        for store in stores.values { store.pauseForSleep() }
        publishStates()
    }

    func wake() {
        guard !isStopped else { return }
        isSleeping = false
        for (id, store) in stores where enabledProviderIDs.contains(id) { store.wake() }
        if enabledProviderIDs.contains("codex") { codex.requestRefresh() }
        publishStates()
    }

    func shutdown() async {
        isStopped = true
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        subscriptions.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for store in stores.values { group.addTask { await store.stop() } }
        }
        await codex.shutdown()
        publishStates()
    }

    private func attach(_ provider: any QuotaProvider, start: Bool) {
        let id = provider.descriptor.id
        let store = ProviderStore(provider: provider, start: false)
        if start { store.start() }
        else if automaticallyStarts, !isStopped, enabledProviderIDs.contains(id) {
            store.activate(automaticRefresh: true, isSleeping: isSleeping)
        }
        stores[id] = store
        subscriptions[id] = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.publishStates() }
        }
    }

    private func synchronizePreferences() {
        enabledProviderIDs = preferences.enabledProviderIDs
        defaultProviderID = preferences.defaultProviderID
        if !enabledProviderIDs.contains(selectedProviderID) || !descriptors.contains(where: { $0.id == selectedProviderID }) {
            selectedProviderID = defaultProviderID
        }
    }

    private func publishStates() {
        states = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            state(for: descriptor.id).map { (descriptor.id, $0) }
        })
    }
}
