import Foundation

public enum AnnouncementKind: String, Codable, Sendable { case regular, banked, unknown }
public enum AnnouncementPhase: String, Codable, Sendable { case upcoming, announcedComplete, unconfirmed, observed }

public struct ResetAnnouncement: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let text: String
    public let sourceURL: URL
    public let kind: AnnouncementKind
    public let phase: AnnouncementPhase

    /// The feed is third-party transcription. Classification never asserts account-level delivery.
    public var currentPhase: AnnouncementPhase { Self.classify(text, observed: phase == .observed) }

    static func clauses(_ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"[^.!?\n]+[.!?]?"#) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    static func classify(_ text: String, observed: Bool) -> AnnouncementPhase {
        if observed { return .observed }
        let text = text.lowercased().replacingOccurrences(of: "’", with: "'")
        // Unrelated account instructions must not negate a clear reset promise in another sentence.
        // A cancellation or delay remains conservative even if the post quotes an older promise.
        if text.contains("cancel") || text.contains("delay") { return .unconfirmed }
        let resetClauses = clauses(text).filter { $0.contains("reset") }
        if resetClauses.contains(where: isUncertainClause) { return .unconfirmed }
        let phases = resetClauses.map { classifyClause($0) }
        if phases.contains(.upcoming) { return .upcoming }
        if phases.contains(.announcedComplete) { return .announcedComplete }
        return .unconfirmed
    }

    private static func classifyClause(_ text: String) -> AnnouncementPhase {
        if isUncertainClause(text) {
            return .unconfirmed
        }
        if ["will reset", "will have reset", "will give", "will credit", "will do", "will land", "is landing", "lands ", "landing in", "should land", "propagating"].contains(where: text.contains) {
            return .upcoming
        }
        if ["reset all propagated", "all reset for everyone", "have reset", "has been reset", "have been reset", "reset has been propagated", "added a banked reset", "have added a reset", "have credited a reset", "have credited one reset"].contains(where: text.contains) {
            return .announcedComplete
        }
        return .unconfirmed
    }

    private static func isUncertainClause(_ text: String) -> Bool {
        ["not ", "n't", "no reset", "maybe", "might", "could", "would", "if ", "unless", "assuming", "provided", "once ", "when ", "whether", "?", "cancel", "delay"].contains(where: text.contains)
    }

    public static func decodeFeed(_ data: Data) throws -> [ResetAnnouncement] {
        guard data.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw AnnouncementError.invalidData }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        var seen = Set<String>()
        let items = rows.compactMap { row -> ResetAnnouncement? in
            guard let id = row["id"] as? String, !id.isEmpty, id.count < 200,
                  let text = row["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rawDate = row["announced_at"] as? String,
                  let date = fractional.date(from: rawDate) ?? seconds.date(from: rawDate),
                  let source = row["source"] as? [String: Any],
                  let rawURL = source["url"] as? String,
                  let url = URL(string: rawURL), let cleanURL = validatedSourceURL(url),
                  let sourceType = source["type"] as? String,
                  sourceType == "observed" || (sourceType == "x_post" && source["author"] as? String == "thsottiaux"),
                  seen.insert(id).inserted else { return nil }
            return ResetAnnouncement(id: id, date: date, text: String(text.prefix(16000)), sourceURL: cleanURL,
                                     kind: AnnouncementKind(rawValue: row["reset_type"] as? String ?? "") ?? .unknown,
                                     phase: classify(text, observed: sourceType == "observed"))
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        guard rows.isEmpty || !items.isEmpty else { throw AnnouncementError.invalidData }
        return Array(items.prefix(10))
    }

    public static func validatedSourceURL(_ url: URL) -> URL? {
        guard url.scheme == "https", let host = url.host, ["x.com", "twitter.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "thsottiaux", parts[1] == "status",
              !parts[2].isEmpty, parts[2].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return URL(string: "https://x.com/thsottiaux/status/\(parts[2])")
    }
}

public enum AnnouncementError: LocalizedError {
    case invalidData, http(Int), tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidData: return "公告数据格式暂不支持"
        case .http(let code): return "公告源暂时不可用（HTTP \(code)）"
        case .tooLarge: return "公告响应超出大小限制"
        }
    }
}

public struct AnnouncementClient: Sendable {
    public init() {}
    public func fetch() async throws -> [ResetAnnouncement] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://codex-resets.com/api/v1/resets?limit=20")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexQuota/0.2 (personal macOS companion)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnnouncementError.invalidData }
        guard http.statusCode == 200 else { throw AnnouncementError.http(http.statusCode) }
        guard response.url?.host == "codex-resets.com", response.url?.scheme == "https" else { throw AnnouncementError.invalidData }
        guard response.expectedContentLength <= 1_048_576 else { throw AnnouncementError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_048_576 else { throw AnnouncementError.tooLarge }
            data.append(byte)
        }
        return try ResetAnnouncement.decodeFeed(data)
    }
}
