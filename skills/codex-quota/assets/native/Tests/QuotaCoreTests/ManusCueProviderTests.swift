import XCTest
import Foundation
@testable import QuotaCore

final class ManusCueProviderTests: XCTestCase {
    // All quota values, dates, and credentials below are fictional test inputs.
    private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testManusMonthlyPercentUsesSubscriptionTotalAndDailyPoolDoesNotLimitSummary() throws {
        let data = Data(#"{"totalCredits":5300,"freeCredits":300,"periodicCredits":4000,"proMonthlyCredits":10000,"addonCredits":1000,"eventCredits":0,"refreshCredits":0,"maxRefreshCredits":300,"refreshInterval":"daily","nextRefreshTime":"2023-11-15T00:00:00Z"}"#.utf8)
        let snapshot = try ManusQuotaMapper.snapshot(from: data, accountFingerprint: "account", observedAt: observedAt)
        let monthly = try XCTUnwrap(snapshot.metrics.first { $0.id == "monthly" })
        let daily = try XCTUnwrap(snapshot.metrics.first { $0.id == "refresh" })
        XCTAssertEqual(monthly.remaining, 4000)
        XCTAssertEqual(monthly.limit, 10000)
        XCTAssertEqual(try XCTUnwrap(snapshot.menuBarRemainingPercent), 40, accuracy: 0.0001)
        XCTAssertNil(monthly.reset)
        XCTAssertEqual(daily.remainingPercent, 0)
        XCTAssertFalse(daily.contributesToSummary)
        XCTAssertEqual(daily.reset?.date, Date(timeIntervalSince1970: 1_700_006_400))
        XCTAssertEqual(snapshot.metrics.first { $0.id == "addon" }?.kind, .balance)
    }

    func testManusMissingMonthlyDenominatorKeepsBalanceAndUnknownPercent() throws {
        let data = Data(#"{"periodicCredits":4000,"proMonthlyCredits":0,"refreshCredits":300,"maxRefreshCredits":300,"refreshInterval":"daily"}"#.utf8)
        let snapshot = try ManusQuotaMapper.snapshot(from: data, accountFingerprint: nil, observedAt: observedAt)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "monthly" }?.remaining, 4000)
        XCTAssertNil(snapshot.menuBarRemainingPercent)
    }

    func testManusExplicitZeroFreeBalanceStaysKnownWithoutInventingPercentage() throws {
        let snapshot = try ManusQuotaMapper.snapshot(from: Data(#"{"freeCredits":0}"#.utf8), accountFingerprint: nil, observedAt: observedAt)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "free" }?.remaining, 0)
        XCTAssertNil(snapshot.menuBarRemainingPercent)
    }

    func testManusRejectsEmptyAndNegativeQuotaPayloads() {
        for payload in ["{}", #"{"periodicCredits":-1,"proMonthlyCredits":10000}"#] {
            XCTAssertThrowsError(try ManusQuotaMapper.snapshot(from: Data(payload.utf8), accountFingerprint: nil, observedAt: observedAt)) {
                XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse)
            }
        }
    }

    func testCueWeeklyUsageIncludesReservationsAndSeparatesPurchasedBalance() throws {
        let data = Data(#"{"membership":{"accessAllowed":true,"validUntilMs":"1800000000000"},"windowStartMs":"1699400000000","windowEndMs":"1700006400000","limitCredits":"1000","usedCredits":"100","reservedCredits":"50","weeklyRemainingCredits":"850","purchasedRemainingCredits":"2000","remainingCredits":"2850"}"#.utf8)
        let snapshot = try CueQuotaMapper.snapshot(from: data, accountFingerprint: "account", observedAt: observedAt)
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 85)
        let weekly = try XCTUnwrap(snapshot.metrics.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.remaining, 850)
        XCTAssertEqual(weekly.limit, 1000)
        XCTAssertEqual(weekly.reset?.date, Date(timeIntervalSince1970: 1_700_006_400))
        XCTAssertEqual(snapshot.metrics.first { $0.id == "purchased" }?.remaining, 2000)
        XCTAssertFalse(try XCTUnwrap(snapshot.metrics.first { $0.id == "purchased" }).contributesToSummary)
    }

    func testCueRejectsExpiredMembershipAndUnknownDenominator() {
        for payload in [
            #"{"membership":{"accessAllowed":true},"windowStartMs":"1699400000000","windowEndMs":"1699999999000","limitCredits":"1000"}"#,
            #"{"membership":{"accessAllowed":true},"windowStartMs":"1699400000000","windowEndMs":"1700006400000","limitCredits":"0"}"#
        ] {
            XCTAssertThrowsError(try CueQuotaMapper.snapshot(from: Data(payload.utf8), accountFingerprint: nil, observedAt: observedAt)) {
                XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse)
            }
        }
    }

    func testCueClampsOverusedWindowToZeroRemaining() throws {
        let data = Data(#"{"membership":{"accessAllowed":true},"windowStartMs":"1699400000000","windowEndMs":"1700006400000","limitCredits":"1000","usedCredits":"1100","reservedCredits":"50"}"#.utf8)
        let snapshot = try CueQuotaMapper.snapshot(from: data, accountFingerprint: nil, observedAt: observedAt)
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 0)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "weekly" }?.remaining, 0)
    }

    func testCueRequiresActiveMembership() {
        let data = Data(#"{"membership":{"accessAllowed":false}}"#.utf8)
        XCTAssertThrowsError(try CueQuotaMapper.snapshot(from: data, accountFingerprint: nil, observedAt: observedAt)) {
            XCTAssertEqual($0 as? QuotaProviderError, .authenticationRequired)
        }
    }

    func testManusRequestUsesReadOnlyRPCAndCurrentCredential() async throws {
        let capture = ManusRequestCapture(response: Data(#"{"periodicCredits":4000,"proMonthlyCredits":10000}"#.utf8))
        let provider = ManusQuotaProvider(transport: capture, credentialsLoader: {
            LocalProviderCredential(token: "fixture-session", deviceID: "fixture-device", accountFingerprint: "account")
        }, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let snapshot = try await provider.fetchQuota()
        let capturedRequest = await capture.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.manus.im/user.v1.UserService/GetAvailableCredits")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, Data("{}".utf8))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-session")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-client-id"), "fixture-device")
        XCTAssertEqual(snapshot.accountFingerprint, "account")
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 40)
    }

    func testAccountChangeIsDetectedBeforeAFailingRequestCanKeepOldAccountData() async throws {
        let credentials = ManusBetweenRequestsCredentialSequence()
        let transport = ManusFailSecondTransport()
        let provider = ManusQuotaProvider(transport: transport, credentialsLoader: { await credentials.load() })
        _ = try await provider.fetchQuota()
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Changed accounts must invalidate the snapshot before requesting quota")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .accountChanged)
        }
        let count = await transport.requestCount
        XCTAssertEqual(count, 1)
    }

    func testAccountChangeDuringNetworkFailureInvalidatesOldSnapshot() async throws {
        let credentials = ManusMutableCredentials()
        let transport = ManusSwitchWhileFailingTransport(credentials: credentials)
        let provider = ManusQuotaProvider(transport: transport, credentialsLoader: { await credentials.load() })
        _ = try await provider.fetchQuota()
        do {
            _ = try await provider.fetchQuota()
            XCTFail("A network error must not preserve another account's quota")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .accountChanged)
        }
    }

    func testCueDiscardsInFlightResultAfterAccountSwitch() async {
        let credentials = ManusCredentialSequence()
        let capture = ManusRequestCapture(response: Data(#"{"membership":{"accessAllowed":true},"windowStartMs":"1699400000000","windowEndMs":"1700006400000","limitCredits":"1000","usedCredits":"100"}"#.utf8))
        let provider = CueQuotaProvider(transport: capture, credentialsLoader: { await credentials.load() }, now: { Date(timeIntervalSince1970: 1_700_000_000) })
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Quota from an account that changed must be discarded")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .accountChanged)
        }
    }
}

private actor ManusRequestCapture: QuotaHTTPTransport {
    private var request: URLRequest?
    let response: Data
    init(response: Data) { self.response = response }
    func send(_ request: URLRequest) async throws -> Data {
        self.request = request
        return response
    }
    func lastRequest() -> URLRequest? { request }
}

private actor ManusCredentialSequence {
    private var reads = 0
    func load() -> LocalProviderCredential {
        reads += 1
        return LocalProviderCredential(token: reads == 1 ? "first" : "second", accountFingerprint: reads == 1 ? "first-account" : "second-account")
    }
}

private actor ManusBetweenRequestsCredentialSequence {
    private var reads = 0
    func load() -> LocalProviderCredential {
        reads += 1
        return LocalProviderCredential(token: reads <= 2 ? "first" : "second")
    }
}

private actor ManusFailSecondTransport: QuotaHTTPTransport {
    private(set) var requestCount = 0
    func send(_ request: URLRequest) async throws -> Data {
        requestCount += 1
        guard requestCount == 1 else { throw QuotaProviderError.networkUnavailable }
        return Data(#"{"periodicCredits":4000,"proMonthlyCredits":10000}"#.utf8)
    }
}

private actor ManusMutableCredentials {
    private var token = "first"
    func load() -> LocalProviderCredential { LocalProviderCredential(token: token) }
    func switchAccount() { token = "second" }
}

private actor ManusSwitchWhileFailingTransport: QuotaHTTPTransport {
    private var count = 0
    private let credentials: ManusMutableCredentials
    init(credentials: ManusMutableCredentials) { self.credentials = credentials }
    func send(_ request: URLRequest) async throws -> Data {
        count += 1
        if count == 1 { return Data(#"{"periodicCredits":4000,"proMonthlyCredits":10000}"#.utf8) }
        await credentials.switchAccount()
        throw QuotaProviderError.networkUnavailable
    }
}
