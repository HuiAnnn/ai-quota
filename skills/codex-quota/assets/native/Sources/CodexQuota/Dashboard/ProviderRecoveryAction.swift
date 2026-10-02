import QuotaCore

enum ProviderRecoveryAction {
    static func title(for error: QuotaProviderError?) -> String {
        switch error {
        case .accessRequired: return "授权"
        case .authenticationRequired, .notInstalled: return "登录"
        default: return "重试"
        }
    }
}
