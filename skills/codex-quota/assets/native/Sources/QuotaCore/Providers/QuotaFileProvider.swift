import Foundation

public struct QuotaFileProvider: QuotaProvider {
    public let descriptor: ProviderDescriptor
    public let fileURL: URL

    public init(fileURL: URL) throws {
        descriptor = try QuotaFileDocument.read(fileURL).descriptor
        self.fileURL = fileURL
    }

    public func fetchQuota() async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        let document = try QuotaFileDocument.read(fileURL)
        guard document.id == descriptor.id else { throw QuotaFileError.invalidDocument }
        return document.snapshot
    }
}
