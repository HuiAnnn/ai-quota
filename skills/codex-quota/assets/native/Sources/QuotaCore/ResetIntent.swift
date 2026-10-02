import Darwin
import Foundation

/// The stable identity of one user-confirmed reset attempt, retained across retries.
public struct ResetIntent: Codable, Equatable, Sendable {
    public let accountId: String
    public let creditId: String
    public let idempotencyKey: String
    public let createdAt: Date
    public let outcome: ResetCreditOutcome?

    public init(
        accountId: String,
        creditId: String,
        idempotencyKey: String = UUID().uuidString,
        createdAt: Date = Date(),
        outcome: ResetCreditOutcome? = nil
    ) {
        self.accountId = accountId
        self.creditId = creditId
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.outcome = outcome
    }

    /// Retain a terminal response so a later retry performs local cleanup only.
    public func confirmed(_ outcome: ResetCreditOutcome) -> ResetIntent {
        ResetIntent(accountId: accountId, creditId: creditId,
                    idempotencyKey: idempotencyKey, createdAt: createdAt, outcome: outcome)
    }
}

/// Stores one pending attempt in a dedicated directory. Callers must serialize all
/// operations (normally on the main thread) and reuse a loaded key before sending
/// another request. A failed load must never be treated as an empty journal.
public final class ResetIntentJournal {
    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexQuota", isDirectory: true)
            .appendingPathComponent("pending-reset.json", isDirectory: false)
    }

    public let fileURL: URL

    public init(fileURL: URL = ResetIntentJournal.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load() throws -> ResetIntent? {
        try validateFileURL()
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if Self.isMissingFile(error) { return nil }
            throw error
        }
        // Keep corrupt contents untouched so recovery cannot accidentally issue a new key.
        return try JSONDecoder().decode(ResetIntent.self, from: data)
    }

    public func save(_ intent: ResetIntent) throws {
        try validateFileURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(intent)
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // Create the replacement with its final permissions before writing any data.
        let staging = directory.appendingPathComponent(".pending-reset-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw Self.posixError() }
        defer {
            Darwin.close(descriptor)
            try? manager.removeItem(at: staging)
        }
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, start.advanced(by: written), bytes.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                written += count
            }
        }
        try Self.synchronize(descriptor)
        guard Darwin.rename(staging.path, fileURL.path) == 0 else { throw Self.posixError() }
        // Persist the rename before the caller is allowed to send a reset request.
        try Self.synchronizeDirectory(directory)
    }

    public func clear() throws {
        try validateFileURL()
        // Unlink only this entry; never recursively remove a directory if the path
        // is unexpectedly occupied by something other than the journal file.
        guard Darwin.unlink(fileURL.path) == 0 else {
            if errno == ENOENT { return }
            throw Self.posixError()
        }
        try Self.synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private func validateFileURL() throws {
        guard fileURL.isFileURL, !fileURL.lastPathComponent.isEmpty else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { Darwin.close(descriptor) }
        try synchronize(descriptor)
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno != EINTR { throw posixError() }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
            || (error.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code))
    }
}
