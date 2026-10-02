import Darwin
import Foundation
import XCTest
@testable import QuotaCore

final class CodexClientTests: XCTestCase {
    func testRelocatesConnectionAfterDesktopUpdateWithoutRestartingCompanion() async throws {
        let old = try FakeAppServer(mode: "split")
        let replacement = try FakeAppServer(mode: "split")
        defer { old.remove(); replacement.remove() }
        let selected = ExecutableSelection(old.executable)
        let client = CodexClient(executableURL: old.executable, codexHome: old.directory,
                                 executableResolver: { selected.url })
        _ = try await client.fetchSnapshot()
        try FileManager.default.removeItem(at: old.executable)
        selected.set(replacement.executable)
        let updated = try await client.fetchSnapshot()
        await client.disconnect()
        XCTAssertEqual(updated.menuBarRemainingPercent, 73)
        XCTAssertEqual(try replacement.messages().compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read"
        ])
        try old.assertChildrenExited()
        try replacement.assertChildrenExited()
    }

    func testSplitFramesNotificationsSessionReuseAndReadOnlyMethods() async throws {
        let fixture = try FakeAppServer(mode: "split")
        defer { fixture.remove() }
        let client = fixture.client()
        let first = try await client.fetchSnapshot()
        let second = try await client.fetchSnapshot()
        await client.disconnect()

        XCTAssertEqual(first.menuBarRemainingPercent, 73)
        XCTAssertEqual(first.accountId, "backend-account-id")
        XCTAssertEqual(first, second)
        let messages = try fixture.messages()
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read",
            "account/read", "account/rateLimits/read"
        ])
        let initialization = try XCTUnwrap(messages.first?["params"] as? [String: Any])
        XCTAssertEqual((initialization["clientInfo"] as? [String: Any])?["name"] as? String, "codex_quota_menu")
        XCTAssertEqual((initialization["clientInfo"] as? [String: Any])?["version"] as? String, "0.2.0")
        for message in messages where message["method"] as? String == "account/read" {
            XCTAssertEqual((message["params"] as? [String: Any])?["refreshToken"] as? Bool, false)
        }
        try fixture.assertChildrenExited()
    }

    func testLoggedOutAndAPIKeyAccountsInvalidatePreviousData() async throws {
        for (mode, expected) in [("loggedout", CodexClientError.notLoggedIn), ("apikey", .unsupportedAuthentication)] {
            let fixture = try FakeAppServer(mode: mode)
            defer { fixture.remove() }
            let client = fixture.client()
            do {
                _ = try await client.fetchSnapshot()
                XCTFail("Expected authentication error")
            } catch let error as CodexClientError {
                XCTAssertEqual(error, expected)
                XCTAssertTrue(error.invalidatesSnapshot)
            }
            await client.disconnect()
            XCTAssertFalse(try fixture.messages().contains { $0["method"] as? String == "account/rateLimits/read" })
            try fixture.assertChildrenExited()
        }
    }

    func testStartupTimeoutKillsUnresponsiveChild() async throws {
        let fixture = try FakeAppServer(mode: "initialize-hang")
        defer { fixture.remove() }
        let client = fixture.client(timeout: 0.6)
        let started = Date()
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("Expected startup timeout")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .requestTimedOut)
            XCTAssertFalse(error.invalidatesSnapshot)
        }
        await client.disconnect()
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        try fixture.assertChildrenExited()
    }

    func testRequestTimeoutReconnectsOnNextFetch() async throws {
        let fixture = try FakeAppServer(mode: "hang-once")
        defer { fixture.remove() }
        let client = fixture.client(timeout: 1)
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("Expected timeout")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .requestTimedOut)
        }
        let snapshot = try await client.fetchSnapshot()
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 73)
        await client.disconnect()
        XCTAssertEqual(try fixture.messages().filter { $0["method"] as? String == "initialize" }.count, 2)
        try fixture.assertChildrenExited()
    }

    func testMalformedResponseAndServerErrorDoNotExposeRawContent() async throws {
        for (mode, expected) in [("malformed", CodexClientError.invalidResponse), ("server-error", .serverError(code: -32000))] {
            let fixture = try FakeAppServer(mode: mode)
            defer { fixture.remove() }
            let client = fixture.client()
            do {
                _ = try await client.fetchSnapshot()
                XCTFail("Expected response failure")
            } catch let error as CodexClientError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET-TEST-CONTENT"))
            }
            await client.disconnect()
            try fixture.assertChildrenExited()
        }
    }

    func testUnexpectedExitRejectsPendingRequest() async throws {
        let fixture = try FakeAppServer(mode: "exit")
        defer { fixture.remove() }
        let client = fixture.client()
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("Expected connection closure")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .connectionClosed)
        }
        await client.disconnect()
        try fixture.assertChildrenExited()
    }

    func testDisconnectRejectsPendingAndWaitsForStubbornChild() async throws {
        let fixture = try FakeAppServer(mode: "stubborn")
        defer { fixture.remove() }
        let client = fixture.client()
        let fetch = Task { try await client.fetchSnapshot() }
        try await fixture.waitFor(method: "account/rateLimits/read")
        let started = Date()
        await client.disconnect()
        do {
            _ = try await fetch.value
            XCTFail("Expected disconnected request")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .connectionClosed)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try fixture.assertChildrenExited()
    }

    func testCancellationClosesOwnedProcess() async throws {
        let fixture = try FakeAppServer(mode: "hang")
        defer { fixture.remove() }
        let client = fixture.client()
        let fetch = Task { try await client.fetchSnapshot() }
        try await fixture.waitFor(method: "account/rateLimits/read")
        fetch.cancel()
        do {
            _ = try await fetch.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        await client.disconnect()
        try fixture.assertChildrenExited()
    }

    func testConcurrentFetchesAreSerialized() async throws {
        let fixture = try FakeAppServer(mode: "normal")
        defer { fixture.remove() }
        let client = fixture.client()
        try await withThrowingTaskGroup(of: QuotaSnapshot.self) { group in
            for _ in 0..<4 { group.addTask { try await client.fetchSnapshot() } }
            for try await snapshot in group { XCTAssertEqual(snapshot.menuBarRemainingPercent, 73) }
        }
        await client.disconnect()
        let methods = try fixture.messages().compactMap { $0["method"] as? String }
        XCTAssertEqual(Array(methods.dropFirst(2)), Array(repeating: ["account/read", "account/rateLimits/read"], count: 4).flatMap { $0 })
    }

    func testExternalAuthChangeRestartsSessionAndInvalidatesOldAccount() async throws {
        let fixture = try FakeAppServer(mode: "normal")
        defer { fixture.remove() }
        let client = fixture.client()
        _ = try await client.fetchSnapshot()
        // These are synthetic fixture values, never the real Codex credentials.
        try Data("changed synthetic auth marker".utf8).write(to: fixture.directory.appendingPathComponent("auth.json"))
        try Data("second@example.invalid".utf8).write(to: fixture.directory.appendingPathComponent("identity.txt"))
        do {
            _ = try await client.fetchSnapshot()
            XCTFail("Expected account change")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .accountChanged)
            XCTAssertTrue(error.invalidatesSnapshot)
        }
        _ = try await client.fetchSnapshot()
        await client.disconnect()
        XCTAssertEqual(try fixture.messages().filter { $0["method"] as? String == "initialize" }.count, 3)
        try fixture.assertChildrenExited()
    }

    func testResetPreflightsAccountAndForwardsOnlySelectedCreditAndKey() async throws {
        let fixture = try FakeAppServer(mode: "reset-reset")
        defer { fixture.remove() }
        let client = fixture.client()
        let outcome = try await client.consumeResetCredit(creditId: "selected-credit-二",
            idempotencyKey: "test-idempotency-key-1", expectedAccountId: "backend-account-id")
        XCTAssertEqual(outcome, .reset)
        await client.disconnect()
        let messages = try fixture.messages()
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read", "account/rateLimitResetCredit/consume"
        ])
        let reset = try XCTUnwrap(messages.last?["params"] as? [String: String])
        XCTAssertEqual(reset, ["creditId": "selected-credit-二", "idempotencyKey": "test-idempotency-key-1"])
        try fixture.assertChildrenExited()
    }

    func testResetDecodesAllDocumentedOutcomes() async throws {
        for expected in [ResetCreditOutcome.reset, .alreadyRedeemed, .nothingToReset, .noCredit] {
            let fixture = try FakeAppServer(mode: "reset-" + expected.rawValue)
            defer { fixture.remove() }
            let client = fixture.client()
            let outcome = try await client.consumeResetCredit(creditId: "credit-1",
                idempotencyKey: "same-explicit-key", expectedAccountId: "backend-account-id")
            XCTAssertEqual(outcome, expected)
            await client.disconnect()
            XCTAssertEqual(try fixture.messages().filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }.count, 1)
            try fixture.assertChildrenExited()
        }
    }

    func testResetAccountMismatchNeverSendsConsume() async throws {
        let fixture = try FakeAppServer(mode: "reset-reset")
        defer { fixture.remove() }
        let client = fixture.client()
        do {
            _ = try await client.consumeResetCredit(creditId: "credit-1",
                idempotencyKey: "test-key", expectedAccountId: "different-account")
            XCTFail("Expected account mismatch")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .accountChanged)
            XCTAssertTrue(error.invalidatesSnapshot)
        }
        await client.disconnect()
        XCTAssertEqual(try fixture.messages().compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read"
        ])
        try fixture.assertChildrenExited()
    }

    func testResetRejectsEmptyArgumentsBeforeConnecting() async throws {
        let fixture = try FakeAppServer(mode: "reset-reset")
        defer { fixture.remove() }
        let client = fixture.client()
        for arguments in [("", "key", "account"), ("credit", "  \n", "account"), ("credit", "key", "")] {
            do {
                _ = try await client.consumeResetCredit(creditId: arguments.0,
                    idempotencyKey: arguments.1, expectedAccountId: arguments.2)
                XCTFail("Expected invalid arguments")
            } catch let error as CodexClientError {
                XCTAssertEqual(error, .invalidResetRequest)
                XCTAssertFalse(error.invalidatesSnapshot)
            }
        }
        await client.disconnect()
        XCTAssertTrue(try fixture.messages().isEmpty)
    }

    func testResetRejectsLoggedOutAPIKeyAndAuthChangedDuringPreflight() async throws {
        for (mode, expected) in [("loggedout", CodexClientError.notLoggedIn),
                                 ("apikey", .unsupportedAuthentication),
                                 ("reset-auth-change", .accountChanged)] {
            let fixture = try FakeAppServer(mode: mode)
            defer { fixture.remove() }
            let client = fixture.client()
            do {
                _ = try await client.consumeResetCredit(creditId: "credit-1",
                    idempotencyKey: "test-key", expectedAccountId: "backend-account-id")
                XCTFail("Expected preflight rejection")
            } catch let error as CodexClientError {
                XCTAssertEqual(error, expected)
                XCTAssertTrue(error.invalidatesSnapshot)
            }
            await client.disconnect()
            XCTAssertFalse(try fixture.messages().contains { $0["method"] as? String == "account/rateLimitResetCredit/consume" })
            try fixture.assertChildrenExited()
        }
    }

    func testResetTimeoutDoesNotRetryAndSameKeyWorksAfterClientRestart() async throws {
        let fixture = try FakeAppServer(mode: "reset-timeout-once")
        defer { fixture.remove() }
        let firstClient = fixture.client(timeout: 1)
        do {
            _ = try await firstClient.consumeResetCredit(creditId: "credit-2",
                idempotencyKey: "persistent-key", expectedAccountId: "backend-account-id")
            XCTFail("Expected lost response")
        } catch let error as CodexClientError {
            XCTAssertEqual(error, .requestTimedOut)
        }
        await firstClient.disconnect()
        XCTAssertEqual(try fixture.messages().filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }.count, 1)

        let restartedClient = fixture.client()
        let outcome = try await restartedClient.consumeResetCredit(creditId: "credit-2",
            idempotencyKey: "persistent-key", expectedAccountId: "backend-account-id")
        XCTAssertEqual(outcome, .alreadyRedeemed)
        await restartedClient.disconnect()
        let params = try fixture.messages()
            .filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }
            .compactMap { $0["params"] as? [String: String] }
        XCTAssertEqual(params, Array(repeating: ["creditId": "credit-2", "idempotencyKey": "persistent-key"], count: 2))
        let ledger = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.directory.appendingPathComponent("redemptions.json"))) as? [String: String]
        XCTAssertEqual(ledger, ["persistent-key": "credit-2"])
        try fixture.assertChildrenExited()
    }

    func testResetAndReadOperationsNeverInterleave() async throws {
        let fixture = try FakeAppServer(mode: "reset-reset")
        defer { fixture.remove() }
        let client = fixture.client()
        let reset = Task {
            try await client.consumeResetCredit(creditId: "credit-1", idempotencyKey: "test-key",
                expectedAccountId: "backend-account-id")
        }
        try await fixture.waitFor(method: "account/read")
        let read = Task { try await client.fetchSnapshot() }
        _ = try await reset.value
        _ = try await read.value
        await client.disconnect()
        XCTAssertEqual(try fixture.messages().compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read", "account/rateLimits/read",
            "account/rateLimitResetCredit/consume", "account/read", "account/rateLimits/read"
        ])
        try fixture.assertChildrenExited()
    }

    func testResetErrorsAndUnexpectedOutcomesStaySanitized() async throws {
        for (mode, expected) in [("reset-server-error", CodexClientError.serverError(code: -32000)), ("reset-unknown-outcome", .invalidResponse)] {
            let fixture = try FakeAppServer(mode: mode)
            defer { fixture.remove() }
            let client = fixture.client()
            do {
                _ = try await client.consumeResetCredit(creditId: "credit-1",
                    idempotencyKey: "test-key", expectedAccountId: "backend-account-id")
                XCTFail("Expected sanitized failure")
            } catch let error as CodexClientError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(error.localizedDescription.contains("SECRET-TEST-CONTENT"))
            }
            await client.disconnect()
            XCTAssertEqual(try fixture.messages().filter { $0["method"] as? String == "account/rateLimitResetCredit/consume" }.count, 1)
            try fixture.assertChildrenExited()
        }
    }
}

private final class ExecutableSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL
    init(_ value: URL) { self.value = value }
    var url: URL { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: URL) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

private struct FakeAppServer {
    let directory: URL
    let executable: URL

    init(mode: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-quota-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/python3
        import json, os, signal, sys, time
        from pathlib import Path
        root = Path(__file__).parent
        mode = "\(mode)"
        if sys.argv[1:] != ["app-server", "--listen", "stdio://"]:
            sys.exit(2)
        with (root / "pids.txt").open("a") as file:
            file.write(str(os.getpid()) + "\\n")
        marker = root / "started"
        first_start = not marker.exists()
        marker.touch()
        if mode == "stubborn":
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        identity_file = root / "identity.txt"
        identity = identity_file.read_text() if identity_file.exists() else "first@example.invalid"
        def send(message, split=False):
            payload = json.dumps(message).encode() + b"\\n"
            if split:
                for chunk in [payload[:3], payload[3:11], payload[11:]]:
                    os.write(1, chunk)
                    time.sleep(0.006)
            else:
                os.write(1, payload)
        def hang():
            while True:
                time.sleep(1)
        for line in sys.stdin:
            request = json.loads(line)
            with (root / "messages.jsonl").open("a") as file:
                file.write(json.dumps(request) + "\\n")
            method = request["method"]
            if method == "initialized":
                continue
            result = {}
            if method == "initialize":
                if mode == "initialize-hang":
                    hang()
                result = {"userAgent": "fake-codex"}
            elif method == "account/read":
                account = {"type": "chatgpt", "email": identity, "planType": "pro"}
                if mode == "loggedout":
                    account = None
                if mode == "apikey":
                    account = {"type": "apiKey"}
                result = {"account": account, "requiresOpenaiAuth": True}
            elif method == "account/rateLimits/read":
                if mode in ["hang", "stubborn"] or (mode == "hang-once" and first_start):
                    hang()
                if mode == "exit":
                    sys.exit(0)
                if mode == "malformed":
                    os.write(1, b"SECRET-TEST-CONTENT invalid JSON\\n")
                    continue
                if mode == "server-error":
                    send({"id": request["id"], "error": {"code": -32000, "message": "SECRET-TEST-CONTENT"}})
                    continue
                result = {"accountId": "backend-account-id", "rateLimitsByLimitId": {
                    "codex": {"limitId": "codex", "primary": {"usedPercent": 27, "windowDurationMins": 300, "resetsAt": 1900000000}}
                }}
                if mode == "reset-auth-change":
                    (root / "auth.json").write_text("synthetic auth changed during preflight")
                # More than a pipe's capacity verifies that stderr is drained.
                os.write(2, b"discarded stderr\\n" * 12000)
            elif method == "account/rateLimitResetCredit/consume" and mode.startswith("reset-"):
                params = request["params"]
                if set(params.keys()) != {"creditId", "idempotencyKey"}:
                    sys.exit(4)
                if mode == "reset-server-error":
                    send({"id": request["id"], "error": {"code": -32000, "message": "SECRET-TEST-CONTENT"}})
                    continue
                if mode == "reset-unknown-outcome":
                    result = {"outcome": "SECRET-TEST-CONTENT"}
                elif mode == "reset-timeout-once":
                    ledger_path = root / "redemptions.json"
                    ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {}
                    if params["idempotencyKey"] in ledger:
                        result = {"outcome": "alreadyRedeemed"}
                    else:
                        ledger[params["idempotencyKey"]] = params["creditId"]
                        ledger_path.write_text(json.dumps(ledger))
                        hang()
                else:
                    result = {"outcome": mode[len("reset-"):]}
            else:
                sys.exit(3)
            if mode == "split":
                os.write(1, b'{"method":"account/updated","params":{}}\\n{"id":999,"result":{}}\\n')
            send({"id": request["id"], "result": result}, split=mode == "split")
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func client(timeout: TimeInterval = 5) -> CodexClient {
        CodexClient(executableURL: executable, codexHome: directory, requestTimeout: timeout)
    }

    func messages() throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("messages.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    func waitFor(method: String) async throws {
        for _ in 0..<1000 {
            if try messages().contains(where: { $0["method"] as? String == method }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CodexClientError.requestTimedOut
    }

    func assertChildrenExited(file: StaticString = #filePath, line: UInt = #line) throws {
        let path = directory.appendingPathComponent("pids.txt")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        for pid in try String(contentsOf: path).split(separator: "\n").compactMap({ Int32($0) }) {
            XCTAssertEqual(Darwin.kill(pid, 0), -1, "Owned process still alive", file: file, line: line)
            XCTAssertEqual(errno, ESRCH, file: file, line: line)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
