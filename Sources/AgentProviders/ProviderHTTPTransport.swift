import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderHTTPEvent: Sendable {
    case response(status: Int, headers: [String: String])
    case data(Data)
}

public protocol ProviderHTTPTransport: Sendable {
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error>
}

public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    private let configurationFactory: @Sendable () -> URLSessionConfiguration

    public init() { configurationFactory = { .ephemeral } }

    internal init(configurationFactory: @escaping @Sendable () -> URLSessionConfiguration) {
        self.configurationFactory = configurationFactory
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            let configuration = configurationFactory()
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            var request = request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            let delegate = ProviderHTTPSessionDelegate(continuation: continuation)
            continuation.onTermination = { @Sendable _ in delegate.cancel() }
            delegate.start(request, configuration: configuration)
        }
    }
}

// URLSession callbacks and stream termination can race. All mutable lifecycle
// state is locked, and terminal paths detach references before invoking callbacks.
private final class ProviderHTTPSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProviderHTTPEvent, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var receivedResponse = false

    init(continuation: AsyncThrowingStream<ProviderHTTPEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration) {
        lock.withLock {
            guard continuation != nil else { return }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            task.resume()
        }
    }

    func cancel() { finish(throwing: CancellationError()) }

    private func finish(throwing error: (any Error)? = nil) {
        let state = lock.withLock {
            let state = (continuation, session, task)
            continuation = nil
            session = nil
            task = nil
            return state
        }
        state.2?.cancel()
        state.1?.invalidateAndCancel()
        state.0?.finish(throwing: error)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: ModelProviderError(kind: .invalidResponse, message: "Invalid HTTP response."))
            return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
        }
        let continuation = lock.withLock {
            receivedResponse = true
            return self.continuation
        }
        continuation?.yield(.response(status: response.statusCode, headers: headers))
        completionHandler(continuation == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { continuation }?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        finish(throwing: ModelProviderError(kind: .invalidResponse, message: "HTTP redirects are not allowed."))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(throwing: CancellationError()) }
            else { finish(throwing: ModelProviderError(kind: .transport, message: "HTTP transport failed.")) }
        } else if !lock.withLock({ receivedResponse }) {
            finish(throwing: ModelProviderError(kind: .invalidResponse, message: "Missing HTTP response."))
        } else {
            finish()
        }
    }
}
