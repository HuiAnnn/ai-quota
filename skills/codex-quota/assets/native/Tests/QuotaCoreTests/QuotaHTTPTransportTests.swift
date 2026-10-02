import Foundation
import XCTest
@testable import QuotaCore

final class QuotaHTTPTransportTests: XCTestCase {
    func testRejectsUnapprovedHostsBeforeSendingCredentials() async throws {
        let transport = URLSessionQuotaTransport(allowedHosts: ["api.manus.im"])
        var request = URLRequest(url: URL(string: "https://unrelated.invalid/quota")!)
        request.setValue("fixture-secret", forHTTPHeaderField: "Authorization")
        do {
            _ = try await transport.send(request)
            XCTFail("Unapproved host must fail before a network request")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .requestFailed)
        }
    }

    func testRejectsPlaintextTransportEvenForApprovedHost() async throws {
        let transport = URLSessionQuotaTransport(allowedHosts: ["api.manus.im"])
        do {
            _ = try await transport.send(URLRequest(url: URL(string: "http://api.manus.im/quota")!))
            XCTFail("Credentials require HTTPS")
        } catch {
            XCTAssertEqual(error as? QuotaProviderError, .requestFailed)
        }
    }

    func testExpiredAuthAndRateLimitsHaveFixedSafeErrors() async throws {
        let transport = fixtureTransport()
        for (status, expected): (Int, QuotaProviderError) in [(401, .authenticationRequired), (403, .authenticationRequired), (429, .rateLimited), (500, .requestFailed)] {
            do {
                _ = try await transport.send(URLRequest(url: URL(string: "https://quota.test/status/\(status)")!))
                XCTFail("Error response must fail")
            } catch {
                XCTAssertEqual(error as? QuotaProviderError, expected)
                XCTAssertFalse(error.localizedDescription.contains("fixture-private-response"))
            }
        }
    }

    func testSuccessfulResponseIsPassedToProviderWithoutCookieStorage() async throws {
        let data = try await fixtureTransport().send(URLRequest(url: URL(string: "https://quota.test/status/200")!))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "fixture-private-response")
    }

    private func fixtureTransport() -> URLSessionQuotaTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QuotaHTTPFixtureProtocol.self]
        return URLSessionQuotaTransport(allowedHosts: ["quota.test"], configuration: configuration)
    }
}

private final class QuotaHTTPFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "quota.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.url!.lastPathComponent)!
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture-private-response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
