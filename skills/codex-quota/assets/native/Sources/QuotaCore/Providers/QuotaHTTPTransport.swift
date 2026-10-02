import Foundation

public protocol QuotaHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
}

/// Ephemeral, HTTPS-only account requests; credentials never follow redirects.
public struct URLSessionQuotaTransport: QuotaHTTPTransport {
    private let allowedHosts: Set<String>
    private let session: URLSession

    public init(allowedHosts: Set<String>) {
        self.init(allowedHosts: allowedHosts, configuration: .ephemeral)
    }

    init(allowedHosts: Set<String>, configuration: URLSessionConfiguration) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RejectQuotaRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              allowedHosts.contains(host.lowercased()), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { throw QuotaProviderError.requestFailed }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw QuotaProviderError.invalidResponse }
            switch response.statusCode {
            case 401, 403: throw QuotaProviderError.authenticationRequired
            case 429: throw QuotaProviderError.rateLimited
            case 200...299: break
            default: throw QuotaProviderError.requestFailed
            }
            guard data.count <= 2 * 1024 * 1024 else { throw QuotaProviderError.invalidResponse }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as QuotaProviderError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // URLs and server response bodies may contain private data.
            throw QuotaProviderError.networkUnavailable
        }
    }
}

private final class RejectQuotaRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
