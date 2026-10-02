import Foundation

public protocol QuotaProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func fetchQuota() async throws -> ProviderSnapshot
    func disconnect() async
}

public extension QuotaProvider {
    func disconnect() async {}
}

public enum QuotaProviderError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled
    case authenticationRequired
    case accountChanged
    case accessRequired
    case invalidResponse
    case networkUnavailable
    case requestFailed
    case rateLimited

    public var invalidatesSnapshot: Bool {
        switch self {
        case .authenticationRequired, .accountChanged, .accessRequired: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "未找到此应用，请先安装。"
        case .authenticationRequired: return "请先在此应用中登录，然后刷新。"
        case .accountChanged: return "账号已变化，请刷新以读取新账号额度。"
        case .accessRequired: return "需要允许读取此应用的本机登录信息。"
        case .invalidResponse: return "暂时无法识别额度数据，请更新应用后重试。"
        case .networkUnavailable: return "连接失败，稍后会自动重试。"
        case .requestFailed: return "暂时无法读取额度，稍后会自动重试。"
        case .rateLimited: return "查询过于频繁，稍后会自动重试。"
        }
    }
}
