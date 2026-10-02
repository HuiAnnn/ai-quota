import AppKit
import Foundation
import QuotaCore

@MainActor
enum QuotaDiagnostics {
    private struct Result: Encodable {
        let name: String
        let remainingPercent: Double?
        let state: String
        let metrics: [Metric]

        struct Metric: Encodable {
            let label: String
            let kind: String
            let remainingPercent: Double?
            let remaining: Double?
            let limit: Double?
            let unit: String?
            let reset: Date?
            let resetPrecision: String?
        }

        init(name: String, snapshot: ProviderSnapshot?, error: QuotaProviderError?) {
            self.name = name
            remainingPercent = snapshot?.menuBarRemainingPercent
            state = error?.localizedDescription ?? "已连接"
            metrics = snapshot?.metrics.map {
                Metric(label: $0.label, kind: $0.kind.rawValue, remainingPercent: $0.remainingPercent,
                       remaining: $0.remaining, limit: $0.limit, unit: $0.unit,
                       reset: $0.reset?.date, resetPrecision: $0.reset?.precision.rawValue)
            } ?? []
        }
    }

    static func printAll() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        var output: [Result] = []
        if let executable = CodexExecutableLocator.locate() {
            let client = CodexClient(executableURL: executable)
            do {
                let snapshot = try await client.fetchSnapshot()
                output.append(Result(name: "Codex", snapshot: .codex(snapshot, observedAt: Date()), error: nil))
            } catch { output.append(Result(name: "Codex", snapshot: nil, error: .authenticationRequired)) }
            await client.disconnect()
        } else { output.append(Result(name: "Codex", snapshot: nil, error: .notInstalled)) }
        let providers = builtIns()
        let values = await fetch(providers)
        output += values.map { Result(name: $0.descriptor.name, snapshot: $0.snapshot, error: $0.error) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { print(String(decoding: try encoder.encode(output), as: UTF8.self)) }
        catch { fputs("无法生成诊断结果\n", stderr) }
        MuseWebSession.shared.shutdown()
    }

    static func previewStore(codex: QuotaStore) async -> AIQuotaStore {
        let values = await fetch(builtIns())
        let providers: [any QuotaProvider] = values.map { PreviewProvider(value: $0) }
        let suite = "AIQuotaPreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AIQuotaStore(codex: codex, providers: providers,
                                 preferences: ProviderPreferences(defaults: defaults), start: false)
        await store.refreshAndWait()
        return store
    }

    private struct Value: Sendable {
        let descriptor: ProviderDescriptor
        let snapshot: ProviderSnapshot?
        let error: QuotaProviderError?
    }

    private struct PreviewProvider: QuotaProvider {
        let value: Value
        var descriptor: ProviderDescriptor { value.descriptor }
        func fetchQuota() async throws -> ProviderSnapshot {
            if let snapshot = value.snapshot { return snapshot }
            throw value.error ?? .invalidResponse
        }
    }

    private static func builtIns() -> [any QuotaProvider] {
        ProviderRegistry.builtIns(museProvider: MuseQuotaProvider(
            credentialsLoader: { try await MuseWebSession.shared.credentials() }
        ))
    }

    private static func fetch(_ providers: [any QuotaProvider]) async -> [Value] {
        let byID = await withTaskGroup(of: Value.self) { group in
            for provider in providers {
                group.addTask {
                    let result: Value
                    do { result = Value(descriptor: provider.descriptor, snapshot: try await provider.fetchQuota(), error: nil) }
                    catch { result = Value(descriptor: provider.descriptor, snapshot: nil, error: error as? QuotaProviderError ?? .requestFailed) }
                    await provider.disconnect()
                    return result
                }
            }
            var values: [String: Value] = [:]
            for await result in group { values[result.descriptor.id] = result }
            return values
        }
        return providers.compactMap { byID[$0.descriptor.id] }
    }
}
