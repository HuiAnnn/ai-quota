import QuotaCore

extension AIQuotaStore {
    @MainActor static let shared = AIQuotaStore(
        providers: ProviderRegistry.builtIns(museProvider: MuseQuotaProvider(
            credentialsLoader: { try await MuseWebSession.shared.credentials() }
        ))
    )
}
