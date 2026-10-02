import XCTest
import QuotaCore
@testable import CodexQuota

final class MuseWebCredentialTests: XCTestCase {
    func testValidatedSessionUsesStableViewerAndBindingRatherThanRotatingToken() throws {
        let first = try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": ["outcome": "validated", "access_token": "fixture-one", "viewer_id": "viewer", "session_binding_id": "binding"]])
        let renewed = try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": ["outcome": "validated", "access_token": "fixture-two", "viewer_id": "viewer", "session_binding_id": "binding"]])
        let other = try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": ["outcome": "validated", "access_token": "fixture-two", "viewer_id": "other", "session_binding_id": "binding"]])
        XCTAssertEqual(first.accountFingerprint, renewed.accountFingerprint)
        XCTAssertNotEqual(first.accountFingerprint, other.accountFingerprint)
    }

    func testLoginAndIncompleteResponsesNeverBecomeCredentials() {
        let cases: [([String: Any], MuseWebAuthenticationError)] = [
            (["outcome": "login", "access_token": "fixture", "viewer_id": "viewer", "session_binding_id": "binding"], .loginRequired),
            (["outcome": "validated", "viewer_id": "viewer", "session_binding_id": "binding"], .tokenUnavailable),
            (["outcome": "validated", "access_token": "fixture", "session_binding_id": "binding"], .invalidResponse),
            (["outcome": "validated", "access_token": "", "viewer_id": "viewer", "session_binding_id": "binding"], .tokenUnavailable),
            (["outcome": "validated", "access_token": "fixture", "viewer_id": "viewer"], .invalidResponse)
        ]
        for (payload, expected) in cases {
            XCTAssertThrowsError(try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": payload])) { error in
                XCTAssertEqual(error as? MuseWebAuthenticationError, expected)
            }
        }
    }

    func testValidatedCheckWithoutNewTokenKeepsPreviouslyVerifiedSameSession() throws {
        let first = try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": ["outcome": "validated", "access_token": "fixture-one", "viewer_id": "viewer", "session_binding_id": "binding"]])
        let checked = try MuseWebCredential.decodeAuthCheck([
            "httpStatus": 200,
            "payload": ["outcome": "validated", "viewer_id": "viewer", "session_binding_id": "binding"]
        ], previous: first)
        XCTAssertEqual(checked.token, "fixture-one")
        XCTAssertEqual(checked.accountFingerprint, first.accountFingerprint)
    }

    func testTokenOmissionNeverBorrowsTokenFromDifferentAccountOrSession() throws {
        let previous = try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": ["outcome": "validated", "access_token": "fixture-one", "viewer_id": "viewer", "session_binding_id": "binding"]])
        for identity in [["viewer_id": "other", "session_binding_id": "binding"], ["viewer_id": "viewer", "session_binding_id": "new-binding"]] {
            var payload = identity
            payload["outcome"] = "validated"
            XCTAssertThrowsError(try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": payload], previous: previous)) { error in
                XCTAssertEqual(error as? MuseWebAuthenticationError, .tokenUnavailable)
            }
        }
    }

    func testFirstValidatedSessionWithoutTokenReportsUnsupportedTokenExchange() {
        XCTAssertThrowsError(try MuseWebCredential.decodeAuthCheck([
            "httpStatus": 200,
            "payload": ["outcome": "validated", "viewer_id": "viewer", "session_binding_id": NSNull()]
        ])) { error in
            XCTAssertEqual(error as? MuseWebAuthenticationError, .tokenUnavailable)
        }
    }

    func testRealUnauthenticatedAdmissionResponseCannotReuseCachedCredential() throws {
        let previous = try MuseWebCredential.decodeAuthCheck(["httpStatus": 200, "payload": ["outcome": "validated", "access_token": "fixture-one", "viewer_id": "viewer", "session_binding_id": "binding"]])
        XCTAssertThrowsError(try MuseWebCredential.decodeAuthCheck([
            "httpStatus": 401,
            "payload": ["type": "hatchAdmissionInvalidated", "reason": "session", "status": 401]
        ], previous: previous)) { error in
            XCTAssertEqual(error as? MuseWebAuthenticationError, .loginRequired)
        }
    }

    func testAdmissionAndCheckpointFailuresStayDistinctFromMissingLogin() {
        let cases: [([String: Any], MuseWebAuthenticationError)] = [
            (["httpStatus": 403, "payload": ["type": "hatchAdmissionInvalidated", "reason": "entitlement", "status": 403]], .accessRestricted),
            (["httpStatus": 403, "payload": ["type": "checkpointRequired"]], .checkpointRequired),
            (["httpStatus": 503, "payload": ["error": "fixture-secret"]], .requestRejected(503))
        ]
        for (response, expected) in cases {
            XCTAssertThrowsError(try MuseWebCredential.decodeAuthCheck(response)) { error in
                XCTAssertEqual(error as? MuseWebAuthenticationError, expected)
            }
        }
    }
}
