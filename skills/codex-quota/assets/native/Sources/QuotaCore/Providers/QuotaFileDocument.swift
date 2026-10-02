import Foundation

public enum QuotaFileError: Error, LocalizedError {
    case invalidDocument, reservedIdentifier, tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "额度文件格式无效，请检查版本、周期、数值和更新时间。"
        case .reservedIdentifier: return "扩展应用的标识必须以 custom. 开头，不能覆盖内置应用。"
        case .tooLarge: return "额度文件超过 1 MB，无法导入。"
        }
    }
}

struct QuotaFileDocument: Decodable {
    let schemaVersion: Int
    let id: String
    let name: String
    let observedAt: String
    let metrics: [Metric]

    struct Metric: Decodable {
        let id: String
        let label: String
        let kind: QuotaMetric.Kind?
        let remainingPercent: Double?
        let remaining: Double?
        let limit: Double?
        let unit: String?
        let reset: Reset?
        let contributesToSummary: Bool?
    }

    struct Reset: Decodable {
        let at: String
        let precision: QuotaReset.Precision?
    }

    static func read(_ file: URL, now: Date = Date()) throws -> QuotaFileDocument {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw QuotaFileError.invalidDocument }
            guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { throw QuotaFileError.tooLarge }
            let data = try Data(contentsOf: file)
            guard data.count <= 1_048_576 else { throw QuotaFileError.tooLarge }
            try validateKeys(data)
            let document = try JSONDecoder().decode(Self.self, from: data)
            try document.validate(now: now)
            return document
        } catch let error as QuotaFileError {
            throw error
        } catch {
            throw QuotaFileError.invalidDocument
        }
    }

    private func validate(now: Date) throws {
        guard id.hasPrefix("custom.") else { throw QuotaFileError.reservedIdentifier }
        guard schemaVersion == 1, id.count <= 64,
              id.range(of: "^custom\\.[a-z0-9][a-z0-9.-]*$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              let date = Self.date(observedAt), date <= now.addingTimeInterval(300),
              !metrics.isEmpty, metrics.count <= 20,
              Set(metrics.map(\.id)).count == metrics.count else { throw QuotaFileError.invalidDocument }
        for metric in metrics {
            guard !metric.id.isEmpty, metric.id.count <= 64, !metric.label.isEmpty, metric.label.count <= 80,
                  (metric.unit?.count ?? 0) <= 20,
                  [metric.remainingPercent, metric.remaining, metric.limit].compactMap({ $0 }).allSatisfy(\.isFinite),
                  metric.remainingPercent.map({ (0...100).contains($0) }) ?? true,
                  metric.limit.map({ $0 > 0 }) ?? true else { throw QuotaFileError.invalidDocument }
            if let reset = metric.reset, Self.date(reset.at) == nil { throw QuotaFileError.invalidDocument }
        }
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(id: id, name: name, refreshInterval: 60)
    }

    var snapshot: ProviderSnapshot {
        ProviderSnapshot(providerID: id, metrics: metrics.map { metric in
            QuotaMetric(id: metric.id, label: metric.label, kind: metric.kind ?? .periodic,
                        remainingPercent: metric.remainingPercent, remaining: metric.remaining,
                        limit: metric.limit, unit: metric.unit,
                        reset: metric.reset.flatMap { reset in
                            Self.date(reset.at).map { QuotaReset(date: $0, precision: reset.precision ?? .instant) }
                        }, contributesToSummary: metric.contributesToSummary ?? true)
        }, observedAt: Self.date(observedAt)!)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func validateKeys(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "id", "name", "observedAt", "metrics"]),
              let metrics = object["metrics"] as? [[String: Any]] else { throw QuotaFileError.invalidDocument }
        for metric in metrics {
            guard Set(metric.keys).isSubset(of: ["id", "label", "kind", "remainingPercent", "remaining", "limit", "unit", "reset", "contributesToSummary"]) else { throw QuotaFileError.invalidDocument }
            if let reset = metric["reset"] as? [String: Any], !Set(reset.keys).isSubset(of: ["at", "precision"]) {
                throw QuotaFileError.invalidDocument
            }
        }
    }
}
