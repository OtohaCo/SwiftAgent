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

/// Streams provider requests over one `URLSession` that lives as long as the transport.
///
/// One session serves every request: a session made and let go for each request triggers a swift-corelibs-foundation
/// bug on Linux, which frees the session's curl multi handle while curl still uses it, and the process aborts
/// ("_MultiHandle deallocated with non-zero retain count"; swift-corelibs-foundation PR #5491). Each request is a task
/// of the shared session; its callbacks are routed to that request by the task's identifier.
public struct URLSessionProviderHTTPTransport: ProviderHTTPTransport {
    private let shared: ProviderHTTPSharedSession

    public init() { self.init(configurationFactory: { .ephemeral }) }

    internal init(configurationFactory: @escaping @Sendable () -> URLSessionConfiguration) {
        let configuration = configurationFactory()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        shared = ProviderHTTPSharedSession(configuration: configuration)
    }

    /// How many requests are still routed to their streams; for tests.
    internal var activeRequests: Int { shared.router.activeCount }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        let shared = shared
        return AsyncThrowingStream { continuation in
            guard !Task.isCancelled else {
                continuation.finish(throwing: CancellationError())
                return
            }
            var request = request
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.httpShouldHandleCookies = false
            let exchange = ProviderHTTPExchange(continuation: continuation)
            // The stream keeps the shared session alive while the request runs.
            continuation.onTermination = { @Sendable _ in withExtendedLifetime(shared) { exchange.cancel() } }
            shared.start(request, for: exchange)
        }
    }
}

/// The session a transport's requests share, and the router that hands each request's callbacks to its exchange.
/// The session keeps the router (its delegate) until the session is let go, which happens when the transport is gone:
/// on another queue, so never from inside one of the session's own callbacks.
private final class ProviderHTTPSharedSession: @unchecked Sendable {
    let router = ProviderHTTPRouter()
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: router, delegateQueue: queue)
    }

    deinit {
        let session = session
        DispatchQueue.global().async { session.finishTasksAndInvalidate() }
    }

    func start(_ request: URLRequest, for exchange: ProviderHTTPExchange) {
        let task = session.dataTask(with: request)
        guard router.add(exchange, for: task) else { return }
        task.resume()
    }
}

/// Hands the shared session's callbacks to the exchange of the task they are for. A task with no exchange (finished,
/// or cancelled by its stream) is cancelled or ignored.
private final class ProviderHTTPRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [Int: ProviderHTTPExchange] = [:]

    var activeCount: Int { lock.withLock { exchanges.count } }

    /// False when the exchange ended before its task could start (its stream was cancelled meanwhile).
    func add(_ exchange: ProviderHTTPExchange, for task: URLSessionDataTask) -> Bool {
        let identifier = task.taskIdentifier
        lock.withLock { exchanges[identifier] = exchange }
        guard exchange.attach(task, onEnd: { [weak self] in self?.remove(identifier) }) else {
            remove(identifier)
            return false
        }
        return true
    }

    private func remove(_ identifier: Int) {
        _ = lock.withLock { exchanges.removeValue(forKey: identifier) }
    }

    private func exchange(for task: URLSessionTask) -> ProviderHTTPExchange? {
        lock.withLock { exchanges[task.taskIdentifier] }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let exchange = exchange(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(exchange.received(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        exchange(for: dataTask)?.received(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        exchange(for: task)?.finish(throwing: ModelProviderError(kind: .invalidResponse, message: "HTTP redirects are not allowed.", diagnostic: .init(stage: .transport, reason: .redirect)))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        exchange(for: task)?.completed(with: error)
    }
}

// One request and its stream. Session callbacks and stream termination can race. All mutable lifecycle state is
// locked, and terminal paths detach references before invoking callbacks.
private final class ProviderHTTPExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProviderHTTPEvent, Error>.Continuation?
    private var task: URLSessionDataTask?
    private var onEnd: (@Sendable () -> Void)?
    private var receivedResponse = false

    init(continuation: AsyncThrowingStream<ProviderHTTPEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    /// False when the stream already ended: the task is not started.
    func attach(_ task: URLSessionDataTask, onEnd: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard continuation != nil else { return false }
            self.task = task
            self.onEnd = onEnd
            return true
        }
    }

    func cancel() { finish(throwing: CancellationError()) }

    /// Ends the stream once: the task is cancelled when it had not ended, and the router forgets the request. The
    /// shared session is left as it is.
    func finish(throwing error: (any Error)? = nil) {
        let state = lock.withLock {
            let state = (continuation, task, onEnd)
            continuation = nil
            task = nil
            onEnd = nil
            return state
        }
        state.1?.cancel()
        state.2?()
        state.0?.finish(throwing: error)
    }

    /// True to go on receiving the body.
    func received(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else {
            finish(throwing: ModelProviderError(kind: .invalidResponse, message: "Invalid HTTP response.", diagnostic: .init(stage: .transport, reason: .invalidHTTPResponse)))
            return false
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String, let value = entry.value as? String { result[name] = value }
        }
        let continuation = lock.withLock {
            receivedResponse = true
            return self.continuation
        }
        continuation?.yield(.response(status: response.statusCode, headers: headers))
        return continuation != nil
    }

    func received(_ data: Data) {
        lock.withLock { continuation }?.yield(.data(data))
    }

    func completed(with error: (any Error)?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(throwing: CancellationError()) }
            else { finish(throwing: ModelProviderError(kind: .transport, message: "HTTP transport failed.")) }
        } else if !lock.withLock({ receivedResponse }) {
            finish(throwing: ModelProviderError(kind: .invalidResponse, message: "Missing HTTP response.", diagnostic: .init(stage: .transport, reason: .missingHTTPResponse)))
        } else {
            finish()
        }
    }
}
