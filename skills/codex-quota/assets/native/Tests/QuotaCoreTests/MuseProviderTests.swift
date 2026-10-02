import Foundation
import XCTest
@testable import QuotaCore

final class MuseProviderTests: XCTestCase {
    // This fixture follows Muse 5.0's bundled mapSubscription schema.
    // All quota values, dates, and credentials are fictional test inputs.
    private let metered = Data(#"""
    {
      "tier": {"tier_id":"free","name":"Free","tier_code":"FREE","is_paid":false,"rank":0},
      "usage": {"state":"METERED","percent_used":7,"resets_at":"2030-04-12","quota_status":"AVAILABLE"},
      "status_subtitle":"Weekly limit resets on April 12",
      "usage_row_label":"每周额度","usage_row_value_label":"7% used",
      "topup_balance":2000000,"topup_total":2000000,
      "topup_row_label":"额外词元","topup_row_value_label":"2 million tokens remaining"
    }
    """#.utf8)

    func testWeeklyUsedPercentBecomesRemainingWithoutAddingExtraTokens() throws {
        let observed = Date(timeIntervalSince1970: 100)
        let snapshot = try MuseQuotaDecoder.decode(metered, accountFingerprint: "test-account", observedAt: observed)
        XCTAssertEqual(snapshot.providerID, "muse")
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 93)
        XCTAssertEqual(snapshot.observedAt, observed)
        XCTAssertEqual(snapshot.metrics.count, 2)
        let extra = try XCTUnwrap(snapshot.metrics.first { $0.id == "additional" })
        XCTAssertEqual(extra.kind, .balance)
        XCTAssertFalse(extra.contributesToSummary)
        XCTAssertEqual(extra.remaining, 2_000_000)
        XCTAssertEqual(extra.limit, 2_000_000)
        XCTAssertEqual(extra.remainingPercent, 100)
        XCTAssertEqual(extra.unit, "词元")
    }

    func testDateOnlyResetKeepsCalendarDayPrecision() throws {
        let snapshot = try MuseQuotaDecoder.decode(metered)
        let reset = try XCTUnwrap(snapshot.metrics.first?.reset)
        XCTAssertEqual(reset.precision, .day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: reset.date),
                       DateComponents(year: 2030, month: 4, day: 12))
    }

    func testMissingPercentAndAdditionalDenominatorStayUnknown() throws {
        let payload = Data(#"{"tier":{"tier_id":"free","name":"Free","is_paid":false},"usage":{"state":"METERED","percent_used":null},"topup_balance":500}"#.utf8)
        let snapshot = try MuseQuotaDecoder.decode(payload)
        XCTAssertNil(snapshot.menuBarRemainingPercent)
        XCTAssertNil(snapshot.metrics.first?.remainingPercent)
        let extra = try XCTUnwrap(snapshot.metrics.first { $0.id == "additional" })
        XCTAssertEqual(extra.remaining, 500)
        XCTAssertNil(extra.remainingPercent)
    }

    func testTimestampWithZoneKeepsInstantPrecisionAndUnknownNumberDoesNotInventUnit() throws {
        let instant = Data(#"{"usage":{"state":"METERED","percent_used":24,"resets_at":"2030-04-12T01:02:03Z"}}"#.utf8)
        let snapshot = try MuseQuotaDecoder.decode(instant)
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 76)
        let reset = try XCTUnwrap(snapshot.metrics.first?.reset)
        XCTAssertEqual(reset.precision, .instant)
        XCTAssertEqual(reset.date, ISO8601DateFormatter().date(from: "2030-04-12T01:02:03Z"))

        let unspecified = Data(#"{"usage":{"state":"METERED","percent_used":24,"resets_at":1902186123}}"#.utf8)
        XCTAssertNil(try MuseQuotaDecoder.decode(unspecified).metrics.first?.reset)
    }

    func testUnlimitedOrUnknownUsageDoesNotPretendToHavePercentage() throws {
        for state in ["UNLIMITED", "UNKNOWN"] {
            let payload = Data("{\"usage\":{\"state\":\"\(state)\",\"percent_used\":0}}".utf8)
            XCTAssertNil(try MuseQuotaDecoder.decode(payload).menuBarRemainingPercent)
        }
    }

    func testRejectsMissingUsageMalformedPercentAndOversizedPayload() {
        for payload in [#"{}"#, #"{"usage":{"state":"METERED","percent_used":"bad"}}"#,
                        #"{"usage":{"state":"METERED","percent_used":-1}}"#,
                        #"{"usage":{"state":"METERED","percent_used":1e999}}"#] {
            XCTAssertThrowsError(try MuseQuotaDecoder.decode(Data(payload.utf8))) {
                XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try MuseQuotaDecoder.decode(Data(repeating: 32, count: 1_048_577))) {
            XCTAssertEqual($0 as? QuotaProviderError, .invalidResponse)
        }
    }

    func testProviderMakesOnlyTheVerifiedReadOnlyRequest() async throws {
        let transport = MuseFixtureTransport(data: metered)
        let provider = MuseQuotaProvider(credentialsLoader: {
            LocalProviderCredential(token: "fixture-token", accountFingerprint: "fixture-account")
        }, transport: transport)
        let snapshot = try await provider.fetchQuota()
        XCTAssertEqual(snapshot.menuBarRemainingPercent, 93)
        let captured = await transport.request()
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://hatch-api.meta.ai/hatch/subscription")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Version"), "1.0.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(snapshot.accountFingerprint, "fixture-account")
    }

    func testProviderDiscardsResponseWhenAccountChangesDuringRequest() async {
        let credentials = MuseCredentialSequence()
        let provider = MuseQuotaProvider(credentialsLoader: { await credentials.load() },
                                         transport: MuseFixtureTransport(data: metered))
        do {
            _ = try await provider.fetchQuota()
            XCTFail("A response for the previous account must be discarded")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .accountChanged)
        }
    }

    func testAccountChangeInvalidatesOldQuotaBeforeNetworkFailure() async throws {
        let credentials = MuseMutableCredential()
        let transport = MuseSwitchableTransport(data: metered)
        let provider = MuseQuotaProvider(credentialsLoader: { await credentials.load() }, transport: transport)
        _ = try await provider.fetchQuota()
        await credentials.setAccount("second")
        await transport.fail()

        do {
            _ = try await provider.fetchQuota()
            XCTFail("Changing accounts must invalidate old quota before a failing network request")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .accountChanged)
        }
        let requests = await transport.requestCount()
        XCTAssertEqual(requests, 1)

        do {
            _ = try await provider.fetchQuota()
            XCTFail("The new account still has a network failure")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .networkUnavailable)
        }
        let retriedRequests = await transport.requestCount()
        XCTAssertEqual(retriedRequests, 2)
    }

    func testCredentialDecodeFailureInvalidatesSnapshotWithoutSendingRequest() async {
        let transport = MuseFixtureTransport(data: metered)
        let provider = MuseQuotaProvider(credentialsLoader: {
            throw QuotaProviderError.invalidResponse
        }, transport: transport)
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Unreadable identity must invalidate any old account snapshot")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .authenticationRequired)
            XCTAssertTrue((error as? QuotaProviderError)?.invalidatesSnapshot == true)
        }
        let request = await transport.request()
        XCTAssertNil(request)
    }

    func testAccountChangeDuringFailedRequestInvalidatesPreviousQuota() async throws {
        let credentials = MuseMutableCredential()
        let transport = MuseAccountChangingTransport(data: metered, credentials: credentials)
        let provider = MuseQuotaProvider(credentialsLoader: { await credentials.load() }, transport: transport)
        _ = try await provider.fetchQuota()
        do {
            _ = try await provider.fetchQuota()
            XCTFail("A network failure must not preserve quota after the account changed in flight")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .accountChanged)
        }
    }

    func testCancellationDoesNotProbeCredentialsAgain() async {
        let credentials = MuseMutableCredential()
        let provider = MuseQuotaProvider(credentialsLoader: { await credentials.load() },
                                         transport: MuseCancelledTransport())
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Cancelled requests must stop immediately")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let reads = await credentials.readCount()
        XCTAssertEqual(reads, 1)
    }

    func testMissingIdentityAfterFailedRequestInvalidatesPreviousQuota() async {
        let credentials = MuseIdentityFailureSequence()
        let provider = MuseQuotaProvider(credentialsLoader: { try await credentials.load() },
                                         transport: MuseFailedTransport())
        do {
            _ = try await provider.fetchQuota()
            XCTFail("A failed request with lost identity must not preserve an old snapshot")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .authenticationRequired)
        }
    }

    func testQuotaDecodeFailureRemainsAQuotaError() async {
        let provider = MuseQuotaProvider(credentialsLoader: {
            LocalProviderCredential(token: "fixture-token", accountFingerprint: "fixture-account")
        }, transport: MuseFixtureTransport(data: Data("{}".utf8)))
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Invalid quota payload must fail decoding")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .invalidResponse)
            XCTAssertFalse((error as? QuotaProviderError)?.invalidatesSnapshot == true)
        }
    }

    func testDefaultProviderRequiresOwnConnectionAndDoesNotReadMetaKeychain() async {
        do {
            _ = try await MuseQuotaProvider().fetchQuota()
            XCTFail("An unconnected provider must require authentication")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .authenticationRequired)
        }
    }

    func testProviderKeepsErrorsSanitizedAtCredentialBoundary() async {
        let provider = MuseQuotaProvider(credentialsLoader: {
            throw NSError(domain: "untrusted-private-token", code: 1)
        }, transport: MuseFixtureTransport(data: metered))
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Credential failures must propagate as a safe status")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .authenticationRequired)
            XCTAssertFalse(error.localizedDescription.contains("untrusted-private-token"))
        }
    }

    func testProviderSanitizesUnexpectedTransportErrors() async {
        let provider = MuseQuotaProvider(credentialsLoader: {
            LocalProviderCredential(token: "fixture-token", accountFingerprint: "fixture-account")
        }, transport: MuseFailedTransport())
        do {
            _ = try await provider.fetchQuota()
            XCTFail("Transport errors must be represented without a private response body")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .networkUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("untrusted-private-body"))
        }
    }
}

private actor MuseFixtureTransport: QuotaHTTPTransport {
    let data: Data
    private var lastRequest: URLRequest?
    init(data: Data) { self.data = data }
    func send(_ request: URLRequest) -> Data {
        lastRequest = request
        return data
    }
    func request() -> URLRequest? { lastRequest }
}

private actor MuseCredentialSequence {
    private var reads = 0
    func load() -> LocalProviderCredential {
        reads += 1
        return LocalProviderCredential(token: "fixture-token", accountFingerprint: reads == 1 ? "first" : "second")
    }
}

private struct MuseFailedTransport: QuotaHTTPTransport {
    func send(_ request: URLRequest) async throws -> Data {
        throw NSError(domain: "untrusted-private-body", code: 1)
    }
}

private actor MuseMutableCredential {
    private var account = "first"
    private var reads = 0
    func setAccount(_ value: String) { account = value }
    func readCount() -> Int { reads }
    func load() -> LocalProviderCredential {
        reads += 1
        return LocalProviderCredential(token: "fixture-token", accountFingerprint: account)
    }
}

private actor MuseSwitchableTransport: QuotaHTTPTransport {
    let data: Data
    private var shouldFail = false
    private var count = 0
    init(data: Data) { self.data = data }
    func fail() { shouldFail = true }
    func requestCount() -> Int { count }
    func send(_ request: URLRequest) throws -> Data {
        count += 1
        if shouldFail { throw QuotaProviderError.networkUnavailable }
        return data
    }
}

private actor MuseAccountChangingTransport: QuotaHTTPTransport {
    let data: Data
    let credentials: MuseMutableCredential
    private var requests = 0
    init(data: Data, credentials: MuseMutableCredential) {
        self.data = data
        self.credentials = credentials
    }
    func send(_ request: URLRequest) async throws -> Data {
        requests += 1
        guard requests > 1 else { return data }
        await credentials.setAccount("second")
        throw QuotaProviderError.networkUnavailable
    }
}

private actor MuseIdentityFailureSequence {
    private var reads = 0
    func load() throws -> LocalProviderCredential {
        reads += 1
        guard reads == 1 else { throw QuotaProviderError.invalidResponse }
        return LocalProviderCredential(token: "fixture-token", accountFingerprint: "first")
    }
}

private struct MuseCancelledTransport: QuotaHTTPTransport {
    func send(_ request: URLRequest) async throws -> Data { throw CancellationError() }
}
