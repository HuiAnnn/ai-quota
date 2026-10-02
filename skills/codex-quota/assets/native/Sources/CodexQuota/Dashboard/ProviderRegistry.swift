import Foundation
import QuotaCore

struct ProviderRegistry {
    static let codexDescriptor = ProviderDescriptor(id: "codex", name: "Codex", bundleIdentifier: "com.openai.codex", refreshInterval: 60)
    private(set) var providers: [any QuotaProvider]

    init(providers: [any QuotaProvider]) {
        var seen: Set<String> = ["codex"]
        self.providers = providers.filter { seen.insert($0.descriptor.id).inserted }
    }

    static func builtIns(museProvider: any QuotaProvider = MuseQuotaProvider()) -> [any QuotaProvider] {
        [GrokQuotaProvider(), ManusQuotaProvider(), CueQuotaProvider(), museProvider]
    }

    var descriptors: [ProviderDescriptor] { [Self.codexDescriptor] + providers.map(\.descriptor) }

    mutating func addFile(_ fileURL: URL) throws -> any QuotaProvider {
        let provider = try QuotaFileProvider(fileURL: fileURL)
        guard !descriptors.contains(where: { $0.id == provider.descriptor.id }) else { throw QuotaFileError.invalidDocument }
        providers.append(provider)
        return provider
    }

    mutating func remove(_ id: String) -> (any QuotaProvider)? {
        guard id.hasPrefix("custom."), let index = providers.firstIndex(where: { $0.descriptor.id == id }) else { return nil }
        return providers.remove(at: index)
    }
}
