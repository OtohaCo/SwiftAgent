import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct JevHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

protocol JevHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> JevHTTPResponse
}

struct URLSessionJevHTTPTransport: JevHTTPTransport {
    func send(_ request: URLRequest) async throws -> JevHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = JevRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let (body, response) = try await session.data(for: request)
        guard !delegate.didRedirect else { throw JevTransportFailure.redirect }
        guard let response = response as? HTTPURLResponse else { throw JevTransportFailure.nonHTTPResponse }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String { result[name] = String(describing: entry.value) }
        }
        return .init(status: response.statusCode, headers: headers, body: body)
    }
}

private enum JevTransportFailure: Error {
    case redirect
    case nonHTTPResponse
}

private final class JevRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirected = false
    var didRedirect: Bool { lock.withLock { redirected } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.withLock { redirected = true }
        completionHandler(nil)
    }
}
