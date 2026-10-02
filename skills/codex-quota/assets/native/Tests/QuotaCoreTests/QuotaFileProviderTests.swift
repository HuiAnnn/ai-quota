import Foundation
import XCTest
@testable import QuotaCore

final class QuotaFileProviderTests: XCTestCase {
    // Quota amounts are fictional test inputs, independent of live accounts.
    private func withFile(_ text: String, action: (URL) async throws -> Void) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(text.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await action(file)
    }

    private func document(id: String = "custom.example", metrics: String = """
        [{"id":"monthly","label":"每月积分","remaining":4000,"limit":10000,"unit":"积分"}]
        """, observedAt: String = "2026-01-01T00:00:00Z") -> String {
        """
        {"schemaVersion":1,"id":"\(id)","name":"示例 AI","observedAt":"\(observedAt)","metrics":\(metrics)}
        """
    }

    func testReadsActualFileAndRefreshesWithoutExecutingAnything() async throws {
        try await withFile(document()) { file in
            let provider = try QuotaFileProvider(fileURL: file)
            let first = try await provider.fetchQuota()
            XCTAssertEqual(provider.descriptor.id, "custom.example")
            XCTAssertEqual(first.menuBarRemainingPercent!, 40, accuracy: 0.0001)
            try Data(document(metrics: "[{\"id\":\"weekly\",\"label\":\"每周\",\"remainingPercent\":22}]").utf8).write(to: file)
            let next = try await provider.fetchQuota()
            XCTAssertEqual(next.menuBarRemainingPercent, 22)
        }
    }

    func testReservedAndDuplicateIdentifiersAreRejected() async throws {
        try await withFile(document(id: "codex")) { file in
            XCTAssertThrowsError(try QuotaFileProvider(fileURL: file))
        }
        try await withFile(document(metrics: "[{\"id\":\"x\",\"label\":\"A\"},{\"id\":\"x\",\"label\":\"B\"}]")) { file in
            XCTAssertThrowsError(try QuotaFileProvider(fileURL: file))
        }
    }

    func testMissingTimestampCredentialFieldsAndOversizeInputAreRejected() async throws {
        for text in [
            "{\"schemaVersion\":1,\"id\":\"custom.a\",\"name\":\"A\",\"metrics\":[]}",
            document().replacingOccurrences(of: "\"schemaVersion\":1", with: "\"token\":\"fixture-token\",\"schemaVersion\":1"),
            String(repeating: " ", count: 1024 * 1024 + 1)
        ] {
            try await withFile(text) { file in
                XCTAssertThrowsError(try QuotaFileProvider(fileURL: file))
            }
        }
    }

    func testFutureObservationAndUnknownLimitNeverCreateFalsePercentage() async throws {
        try await withFile(document(observedAt: "2100-01-01T00:00:00Z")) { file in
            XCTAssertThrowsError(try QuotaFileProvider(fileURL: file))
        }
        try await withFile(document(metrics: "[{\"id\":\"balance\",\"label\":\"积分\",\"remaining\":10000}]")) { file in
            let snapshot = try await QuotaFileProvider(fileURL: file).fetchQuota()
            XCTAssertNil(snapshot.menuBarRemainingPercent)
            XCTAssertEqual(snapshot.metrics.first?.remaining, 10000)
        }
    }
}
