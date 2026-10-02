import XCTest
import Foundation
import CryptoKit
@testable import QuotaCore

final class GrokProviderTests: XCTestCase {
    private let usage = Data(#"{"usagePercent":27.5,"nextResetTimestampUtc":"2026-10-08T06:12:00Z","hasNonZeroIncludedLimit":true,"isTeamSeat":false,"usesPooledEnterpriseAllowance":false}"#.utf8)

    func testActualSchemaConvertsUsedPercentAndKeepsExtraSpendSeparate() throws {
        let current = Data(#"{"billingCycleEnd":"1791439920000","spendLimitUsage":{"individualLimit":2000,"individualUsed":250}}"#.utf8)
        let metrics = try GrokUsageDecoder.decode(usage: usage, currentPeriod: current)
        XCTAssertEqual(metrics[0].remainingPercent, 72.5)
        XCTAssertEqual(metrics[0].reset?.precision, .instant)
        XCTAssertEqual(metrics[0].reset?.date.timeIntervalSince1970, 1791439920)
        XCTAssertEqual(metrics[1].remaining, 17.5)
        XCTAssertEqual(metrics[1].limit, 20)
        XCTAssertFalse(metrics[1].contributesToSummary)
    }

    func testMissingAndEnterpriseSharedUsageStayUnknown() throws {
        for data in [Data("{}".utf8), Data(#"{"usesPooledEnterpriseAllowance":true,"usagePercent":10}"#.utf8)] {
            let metrics = try GrokUsageDecoder.decode(usage: data, currentPeriod: nil)
            XCTAssertNil(metrics[0].remainingPercent)
        }
        XCTAssertEqual(try GrokUsageDecoder.decode(usage: Data(#"{"usagePercent":150}"#.utf8), currentPeriod: nil)[0].remainingPercent, 0)
        XCTAssertThrowsError(try GrokUsageDecoder.decode(usage: Data(#"{"usagePercent":"NaN"}"#.utf8), currentPeriod: nil)) { XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse) }
    }

    func testUnlimitedOnDemandSentinelDoesNotCreateAnInventedBalance() throws {
        let current = Data(#"{"spendLimitUsage":{"individualLimit":2147483647,"individualUsed":250}}"#.utf8)
        XCTAssertEqual(try GrokUsageDecoder.decode(usage: usage, currentPeriod: current).count, 1)
    }

    func testProtobufJSONOmittedZeroSpendKeepsTheFullOnDemandBalance() throws {
        let current = Data(#"{"spendLimitUsage":{"individualLimit":2000}}"#.utf8)
        let metrics = try GrokUsageDecoder.decode(usage: usage, currentPeriod: current)
        XCTAssertEqual(metrics.first(where: { $0.id == "on-demand" })?.remaining, 20)
    }

    func testProviderUsesOnlyVerifiedReadOnlyRoutes() async throws {
        let fixed = Date(timeIntervalSince1970: 1790000000)
        let transport = GrokFixtureTransport(usage: usage)
        let credential = GrokCredential(token: "fixture-token", machineID: "fixture-machine", accountFingerprint: "fixture-account", teamID: 42)
        let provider = GrokQuotaProvider(transport: transport, credentialsLoader: { credential }, now: { fixed })
        let snapshot = try await provider.fetchQuota()
        XCTAssertEqual(snapshot.accountFingerprint, "e9772b413e40a36879b4cded4803fcaa4ccb173eb65850501ea815d7f8fb3fee")
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 72.5)
        XCTAssertEqual(snapshot.observedAt, fixed)
        let requests = await transport.requests
        XCTAssertEqual(Set(requests.compactMap(\.url?.path)), ["/aiserver.v1.DashboardService/GetSandUsageStatus", "/aiserver.v1.DashboardService/GetCurrentPeriodUsage"])
        for request in requests {
            XCTAssertEqual(request.url?.host, "api2.cursor.sh")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.httpBody, Data("{}".utf8))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-cursor-team-id"), "42")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        }
    }

    func testAccountSwitchDiscardsLateQuota() async {
        let sequence = GrokCredentialSequence()
        let provider = GrokQuotaProvider(transport: GrokFixtureTransport(usage: usage), credentialsLoader: { await sequence.load() })
        do { _ = try await provider.fetchQuota(); XCTFail("late quota should be rejected") }
        catch { XCTAssertEqual(error as? QuotaProviderError, .accountChanged) }
    }

    func testAccountChangeIsDetectedBeforeAFailingNetworkRequest() async throws {
        let credentials = GrokMutableCredentials()
        let transport = GrokFixtureTransport(usage: usage)
        let provider = GrokQuotaProvider(transport: transport, credentialsLoader: { await credentials.load() })
        _ = try await provider.fetchQuota()
        await credentials.switchAccount()
        await transport.failNetwork()
        do { _ = try await provider.fetchQuota(); XCTFail("account switch should invalidate the old snapshot") }
        catch { XCTAssertEqual(error as? QuotaProviderError, .accountChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2, "must reject the changed identity before sending another request")
    }

    func testUnrecognizableLoginDataInvalidatesAnExistingSnapshot() async {
        let provider = GrokQuotaProvider(transport: GrokFixtureTransport(usage: usage), credentialsLoader: { throw QuotaProviderError.invalidResponse })
        do { _ = try await provider.fetchQuota(); XCTFail("unknown credentials must fail") }
        catch { XCTAssertEqual(error as? QuotaProviderError, .authenticationRequired) }
    }

    func testNetworkFailureAfterInFlightAccountSwitchClearsTheOldIdentity() async throws {
        let credentials = GrokMutableCredentials()
        let transport = GrokSwitchingTransport(usage: usage, credentials: credentials)
        let provider = GrokQuotaProvider(transport: transport, credentialsLoader: { await credentials.load() })
        _ = try await provider.fetchQuota()
        await transport.switchDuringRequest()
        do { _ = try await provider.fetchQuota(); XCTFail("in-flight identity change must invalidate the snapshot") }
        catch { XCTAssertEqual(error as? QuotaProviderError, .accountChanged) }
    }

    func testTeamChangeInvalidatesThePreviousTeamBeforeNetwork() async throws {
        let credentials = GrokMutableCredentials()
        let transport = GrokFixtureTransport(usage: usage)
        let provider = GrokQuotaProvider(transport: transport, credentialsLoader: { await credentials.load() })
        _ = try await provider.fetchQuota()
        await credentials.switchTeam()
        await transport.failNetwork()
        do { _ = try await provider.fetchQuota(); XCTFail("team change must invalidate the old quota") }
        catch { XCTAssertEqual(error as? QuotaProviderError, .accountChanged) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLocalReaderUsesActiveAccountAndRejectsMismatchedScope() throws {
        let subject = "synthetic-account"
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": 2_000_000_000])
        let token = "header." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") + ".signature"
        let fingerprint = SHA256.hash(data: Data(subject.utf8)).map { String(format: "%02x", $0) }.joined()
        let accounts: [String: Any] = ["active": fingerprint, "accounts": [fingerprint: ["cursor-access-token": "token-cipher", "cursor-selected-team-id": "team-cipher"], "inactive": ["cursor-access-token": "ignored"]]]
        let accountsString = String(data: try JSONSerialization.data(withJSONObject: accounts), encoding: .utf8)!
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "cursor-accounts": accountsString, "cursor-machine-id": "machine-cipher"])
        let value = try GrokLocalCredentialReader.decode(data, decrypt: { value in
            switch value { case "token-cipher": return token; case "team-cipher": return "42"; case "machine-cipher": return "fixture-machine"; default: throw QuotaProviderError.invalidResponse }
        }, now: Date(timeIntervalSince1970: 1790000000))
        XCTAssertEqual(value.accountFingerprint, fingerprint)
        XCTAssertEqual(value.teamID, 42)
        XCTAssertEqual(value.machineID, "fixture-machine")
        XCTAssertThrowsError(try GrokLocalCredentialReader.decode(data, decrypt: { _ in "mismatched" }, now: Date(timeIntervalSince1970: 1790000000)))
    }
}

private actor GrokFixtureTransport: QuotaHTTPTransport {
    let usage: Data
    var requests: [URLRequest] = []
    private var failing = false
    init(usage: Data) { self.usage = usage }
    func send(_ request: URLRequest) throws -> Data {
        requests.append(request)
        if failing { throw QuotaProviderError.networkUnavailable }
        switch request.url?.path {
        case "/aiserver.v1.DashboardService/GetSandUsageStatus": return usage
        case "/aiserver.v1.DashboardService/GetCurrentPeriodUsage": return Data("{}".utf8)
        default: throw QuotaProviderError.requestFailed
        }
    }
    func failNetwork() { failing = true }
}

private actor GrokMutableCredentials {
    private var account = "first-account"
    private var teamID = 42
    func switchAccount() { account = "second-account" }
    func switchTeam() { teamID = 84 }
    func load() -> GrokCredential { GrokCredential(token: "fixture-token", accountFingerprint: account, teamID: teamID) }
}

private actor GrokSwitchingTransport: QuotaHTTPTransport {
    let usage: Data
    let credentials: GrokMutableCredentials
    private var switching = false
    init(usage: Data, credentials: GrokMutableCredentials) { self.usage = usage; self.credentials = credentials }
    func switchDuringRequest() { switching = true }
    func send(_ request: URLRequest) async throws -> Data {
        if switching {
            if request.url?.path.hasSuffix("GetSandUsageStatus") == true { await credentials.switchAccount() }
            throw QuotaProviderError.networkUnavailable
        }
        return request.url?.path.hasSuffix("GetSandUsageStatus") == true ? usage : Data("{}".utf8)
    }
}

private actor GrokCredentialSequence {
    private var reads = 0
    func load() -> GrokCredential {
        reads += 1
        return GrokCredential(token: "fixture-token", accountFingerprint: reads == 1 ? "first-account" : "second-account")
    }
}
