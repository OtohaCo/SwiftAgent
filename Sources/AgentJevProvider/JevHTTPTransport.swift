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

/// Sends Jev requests over one `URLSession` that lives as long as the transport.
///
/// One session serves every request, as `URLSessionProviderHTTPTransport` does: a session made and let go for each
/// request triggers a swift-corelibs-foundation bug on Linux, which frees the session's curl multi handle while curl
/// still uses it, and the process aborts ("_MultiHandle deallocated with non-zero retain count"; swift-corelibs-foundation
/// PR #5491). Each request is a task of the shared session; its callbacks are routed to that request by the task's
/// identifier. A redirect is refused, never followed.
struct URLSessionJevHTTPTransport: JevHTTPTransport {
    private let shared: JevHTTPSharedSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        shared = JevHTTPSharedSession(configuration: configuration)
    }

    /// How many requests are still routed to their callers; for tests.
    var activeRequests: Int { shared.router.activeCount }

    func send(_ request: URLRequest) async throws -> JevHTTPResponse {
        try Task.checkCancellation()
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let exchange = JevHTTPExchange()
        let shared = shared
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard exchange.begin(continuation) else { return }
                shared.start(request, for: exchange)
            }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
        }
    }
}

private enum JevTransportFailure: Error {
    case redirect
    case nonHTTPResponse
}

/// The session a transport's requests share, and the router that hands each request's callbacks to its exchange.
/// The session keeps the router (its delegate) until the session is let go, which happens when the transport is gone:
/// on another queue, so never from inside one of the session's own callbacks.
private final class JevHTTPSharedSession: @unchecked Sendable {
    let router = JevHTTPRouter()
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

    func start(_ request: URLRequest, for exchange: JevHTTPExchange) {
        let task = session.dataTask(with: request)
        guard router.add(exchange, for: task) else { return }
        task.resume()
    }
}

/// Hands the shared session's callbacks to the exchange of the task they are for. A task with no exchange (finished,
/// or ended by its caller's cancellation) is cancelled or ignored.
private final class JevHTTPRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var exchanges: [Int: JevHTTPExchange] = [:]

    var activeCount: Int { lock.withLock { exchanges.count } }

    /// False when the exchange ended before its task could start (its caller was cancelled meanwhile).
    func add(_ exchange: JevHTTPExchange, for task: URLSessionDataTask) -> Bool {
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

    private func exchange(for task: URLSessionTask) -> JevHTTPExchange? {
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
        exchange(for: task)?.finish(.failure(JevTransportFailure.redirect))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        exchange(for: task)?.completed(with: error)
    }
}

// One request and its caller. Session callbacks and the caller's cancellation can race. All mutable state is locked,
// the caller is resumed once, and terminal paths detach references before invoking callbacks.
private final class JevHTTPExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<JevHTTPResponse, any Error>?
    /// The outcome when the request ended before its caller was waiting.
    private var earlyOutcome: Result<JevHTTPResponse, any Error>?
    private var ended = false
    private var task: URLSessionDataTask?
    private var onEnd: (@Sendable () -> Void)?
    private var response: HTTPURLResponse?
    private var body = Data()

    /// False when the request already ended: the caller is resumed with that outcome and the task is not started.
    func begin(_ continuation: CheckedContinuation<JevHTTPResponse, any Error>) -> Bool {
        let outcome: Result<JevHTTPResponse, any Error>? = lock.withLock {
            guard !ended else { return earlyOutcome ?? .failure(CancellationError()) }
            self.continuation = continuation
            return nil
        }
        guard let outcome else { return true }
        continuation.resume(with: outcome)
        return false
    }

    /// False when the request already ended: the task is not started.
    func attach(_ task: URLSessionDataTask, onEnd: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard !ended else { return false }
            self.task = task
            self.onEnd = onEnd
            return true
        }
    }

    /// Ends the request once: the task is cancelled when it had not ended, and the router forgets the request. The
    /// shared session is left as it is.
    func finish(_ outcome: Result<JevHTTPResponse, any Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<JevHTTPResponse, any Error>?, URLSessionDataTask?, (@Sendable () -> Void)?)? in
            guard !ended else { return nil }
            ended = true
            let state = (continuation, task, onEnd)
            if continuation == nil { earlyOutcome = outcome }
            continuation = nil
            task = nil
            onEnd = nil
            return state
        }
        guard let state else { return }
        state.1?.cancel()
        state.2?()
        state.0?.resume(with: outcome)
    }

    /// True to go on receiving the body.
    func received(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else {
            finish(.failure(JevTransportFailure.nonHTTPResponse))
            return false
        }
        return lock.withLock {
            guard !ended else { return false }
            self.response = response
            return true
        }
    }

    func received(_ data: Data) {
        lock.withLock { if !ended { body.append(data) } }
    }

    func completed(with error: (any Error)?) {
        if let error {
            finish(.failure(error))
            return
        }
        let received = lock.withLock { response.map { ($0, body) } }
        guard let (response, body) = received else {
            finish(.failure(JevTransportFailure.nonHTTPResponse))
            return
        }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            if let name = entry.key as? String { result[name] = String(describing: entry.value) }
        }
        finish(.success(.init(status: response.statusCode, headers: headers, body: body)))
    }
}
