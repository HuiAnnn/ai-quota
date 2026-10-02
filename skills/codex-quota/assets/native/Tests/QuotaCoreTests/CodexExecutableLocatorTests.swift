import Foundation
import XCTest
@testable import QuotaCore

final class CodexExecutableLocatorTests: XCTestCase {
    func testUpdatedDesktopLayoutWorksWithoutShellPATH() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app")
        let nested = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try makeExecutable(nested)
        XCTAssertEqual(CodexExecutableLocator.locate(applicationRoots: [app.path], searchPath: "/usr/bin:/bin"), nested)
        let launcher = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        try makeExecutable(launcher)
        XCTAssertEqual(CodexExecutableLocator.locate(applicationRoots: [app.path], searchPath: ""), launcher)
        XCTAssertEqual(CodexExecutableLocator.desktopApplication(containing: nested)?.path, app.path)
    }
    func testLegacyAndPATHFallbackRemainAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Codex.app")
        let old = app.appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(old)
        XCTAssertEqual(CodexExecutableLocator.locate(applicationRoots: [app.path], searchPath: ""), old)
        try FileManager.default.removeItem(at: old)
        let cli = root.appendingPathComponent("bin/codex")
        try makeExecutable(cli)
        XCTAssertEqual(CodexExecutableLocator.locate(applicationRoots: [app.path], searchPath: cli.deletingLastPathComponent().path), cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cli.path)
        XCTAssertNil(CodexExecutableLocator.locate(applicationRoots: [app.path], searchPath: cli.deletingLastPathComponent().path))
    }
    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
