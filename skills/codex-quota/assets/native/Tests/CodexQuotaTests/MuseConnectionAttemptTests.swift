import XCTest
import QuotaCore
@testable import CodexQuota

@MainActor
final class MuseConnectionAttemptTests: XCTestCase {
    func testLoginFailureDoesNotAdvanceToQuotaOrConfirmConnection() async {
        let attempt = MuseConnectionAttempt()
        var requestedQuota = false
        let connected = await attempt.verify(authenticate: {
            throw MuseWebAuthenticationError.loginRequired
        }, fetchQuota: {
            requestedQuota = true
        })
        XCTAssertFalse(connected)
        XCTAssertFalse(requestedQuota)
        XCTAssertEqual(attempt.state, .failed(.login, .loginRequired))
    }

    func testValidLoginWithoutWorkingQuotaDoesNotConfirmConnection() async {
        let attempt = MuseConnectionAttempt()
        let connected = await attempt.verify(authenticate: {}, fetchQuota: {
            throw QuotaProviderError.authenticationRequired
        })
        XCTAssertFalse(connected)
        XCTAssertEqual(attempt.state, .failed(.quota, .quotaAccessRejected))
    }

    func testConnectionSucceedsOnlyAfterBothStagesFinish() async {
        let attempt = MuseConnectionAttempt()
        var stages: [MuseConnectionAttempt.State] = []
        attempt.onStateChange = { stages.append($0) }
        let connected = await attempt.verify(authenticate: {}, fetchQuota: {})
        XCTAssertTrue(connected)
        XCTAssertEqual(stages, [.checking(.login), .checking(.quota), .connected])
    }

    func testClosingDuringQuotaCheckCannotLaterConfirmConnection() async {
        let attempt = MuseConnectionAttempt()
        let gate = MuseAttemptGate()
        let task = Task { await attempt.verify(authenticate: {}, fetchQuota: { await gate.wait() }) }
        await gate.waitUntilStarted()
        attempt.cancel()
        gate.resume()
        let connected = await task.value
        XCTAssertFalse(connected)
        XCTAssertEqual(attempt.state, .idle)
    }

    func testRawNetworkErrorCannotEnterConnectionFeedback() async {
        let attempt = MuseConnectionAttempt()
        let connected = await attempt.verify(authenticate: {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bearer fixture-secret"])
        }, fetchQuota: {})
        XCTAssertFalse(connected)
        XCTAssertEqual(attempt.state, .failed(.login, .networkUnavailable))
        XCTAssertFalse(attempt.state.message.contains("fixture-secret"))
    }
}

@MainActor
private final class MuseAttemptGate {
    private var completion: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilStarted() async {
        for _ in 0..<100 {
            if completion != nil { return }
            await Task.yield()
        }
        XCTFail("The quota stage did not start")
    }
    func resume() { completion?.resume(); completion = nil }
}
