import Foundation
import QuotaCore

enum MuseWebAuthenticationError: Error, Equatable {
    case loginRequired, accessRestricted, checkpointRequired, tokenUnavailable, invalidResponse, networkUnavailable
    case requestRejected(Int)
}

@MainActor
final class MuseConnectionAttempt {
    enum Stage: Equatable { case login, quota }
    enum Problem: Equatable {
        case loginRequired, accessRestricted, checkpointRequired, tokenUnavailable, invalidResponse
        case networkUnavailable, quotaAccessRejected, rateLimited, accountChanged
        case requestRejected(Int)
    }
    enum State: Equatable {
        case idle, checking(Stage), connected, failed(Stage, Problem)
        var message: String {
            switch self {
            case .idle: return "请在上方完成 Muse 网页登录，再点击验证连接。登录信息仅保存在本机。"
            case .checking(.login): return "正在检查 Muse 网页登录…"
            case .checking(.quota): return "网页登录已通过，正在读取真实额度…"
            case .connected: return "Muse 登录和额度读取均已验证。"
            case .failed(let stage, let problem):
                let prefix = stage == .login ? "登录检查未通过：" : "额度读取未通过："
                switch problem {
                case .loginRequired: return prefix + "尚未完成 Muse 网页登录（或会话已失效）。请在上方登录后重试。"
                case .accessRestricted: return prefix + "Muse 账号尚未获得访问权限。请在上方完成访问流程。"
                case .checkpointRequired: return prefix + "Muse 需要验证账号。请在上方完成验证后重试。"
                case .tokenUnavailable: return "网页登录已通过，但 Muse 未提供额度访问令牌；此会话的额度读取尚未完成。"
                case .invalidResponse: return prefix + "Muse 返回了当前版本无法识别的数据。"
                case .networkUnavailable: return prefix + "网络请求失败或超时。请稍后重试。"
                case .quotaAccessRejected: return prefix + "Muse 额度接口拒绝了当前网页凭据；尚未确认网页令牌可访问额度。"
                case .rateLimited: return prefix + "Muse 暂时限制了请求频率。请稍后重试。"
                case .accountChanged: return prefix + "账号或会话已切换，请重试。"
                case .requestRejected(let status): return prefix + "Muse 返回 HTTP \(status)，请稍后重试。"
                }
            }
        }
    }
    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?
    private var activeID: UUID?

    func verify(authenticate: () async throws -> Void, fetchQuota: () async throws -> Void) async -> Bool {
        guard activeID == nil else { return false }
        let id = UUID()
        activeID = id
        var stage = Stage.login
        update(.checking(stage))
        do {
            try Task.checkCancellation()
            try await authenticate()
            guard activeID == id else { return false }
            try Task.checkCancellation()
            stage = .quota
            update(.checking(stage))
            try await fetchQuota()
            guard activeID == id else { return false }
            try Task.checkCancellation()
            activeID = nil
            update(.connected)
            return true
        } catch {
            guard activeID == id else { return false }
            activeID = nil
            if error is CancellationError { update(.idle) }
            else { update(.failed(stage, Self.problem(error, stage: stage))) }
            return false
        }
    }

    func cancel() {
        activeID = nil
        update(.idle)
    }

    private func update(_ state: State) {
        self.state = state
        onStateChange?(state)
    }

    private static func problem(_ error: Error, stage: Stage) -> Problem {
        if let error = error as? MuseWebAuthenticationError {
            switch error {
            case .loginRequired: return .loginRequired
            case .accessRestricted: return .accessRestricted
            case .checkpointRequired: return .checkpointRequired
            case .tokenUnavailable: return .tokenUnavailable
            case .invalidResponse: return .invalidResponse
            case .networkUnavailable: return .networkUnavailable
            case .requestRejected(let status): return .requestRejected(status)
            }
        }
        switch error as? QuotaProviderError {
        case .authenticationRequired, .accessRequired:
            return stage == .login ? .loginRequired : .quotaAccessRejected
        case .accountChanged: return .accountChanged
        case .rateLimited: return .rateLimited
        case .invalidResponse: return .invalidResponse
        default: return .networkUnavailable
        }
    }
}
