import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentJevProvider

struct JevHTTPTransportTests {
    /// One session serves a transport's requests (a session per request triggers a Foundation bug on Linux,
    /// swift-corelibs-foundation PR #5491); each finished request is forgotten.
    @Test func oneTransportCarriesRequestsOneAfterAnother() async throws {
        let transport = fixtureTransport()
        for text in ["first", "second", "third"] {
            let fixture = JevHTTPFixture(.respond(text))
            defer { fixture.remove() }
            let response = try await transport.send(fixture.request)
            #expect(response.status == 200)
            #expect(response.body == Data(text.utf8))
            #expect(response.headers["X-Fixture"] == "jev")
            try await eventually { transport.activeRequests == 0 }
        }
    }

    @Test func concurrentRequestsGetTheirOwnResponses() async throws {
        let transport = fixtureTransport()
        let first = JevHTTPFixture(.respond("first"))
        let second = JevHTTPFixture(.respond("second"))
        defer { first.remove(); second.remove() }
        async let one = transport.send(first.request)
        async let two = transport.send(second.request)
        let (a, b) = try await (one, two)
        #expect(a.body == Data("first".utf8))
        #expect(b.body == Data("second".utf8))
        try await eventually { transport.activeRequests == 0 }
    }

    @Test func callerCancellationStopsUnderlyingRequest() async throws {
        let transport = fixtureTransport()
        let fixture = JevHTTPFixture(.hang)
        defer { fixture.remove() }
        let caller = Task { try await transport.send(fixture.request) }
        try await eventually { fixture.startCount == 1 }
        caller.cancel()
        await #expect(throws: CancellationError.self) { try await caller.value }
        try await eventually { fixture.stopped }
        try await eventually { transport.activeRequests == 0 }
    }

    @Test func alreadyCancelledCallerDoesNotStartRequest() async throws {
        let transport = fixtureTransport()
        let fixture = JevHTTPFixture(.respond("unused"))
        defer { fixture.remove() }
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(fixture.request)
        }
        await #expect(throws: CancellationError.self) { try await caller.value }
        #expect(fixture.startCount == 0)
        #expect(transport.activeRequests == 0)
    }

    @Test func disablesPersistenceEvenForInjectedConfiguration() async throws {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [JevHTTPURLProtocol.self]
        let transport = URLSessionJevHTTPTransport(configuration: configuration)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        let fixture = JevHTTPFixture(.respond("ok"))
        defer { fixture.remove() }
        _ = try await transport.send(fixture.request)
        #expect(fixture.lastRequest?.httpShouldHandleCookies == false)
        #expect(fixture.lastRequest?.cachePolicy == .reloadIgnoringLocalCacheData)
    }

#if !os(Linux)
    // swift-corelibs-foundation URLSession fatals when a URLProtocol reports a redirect.
    @Test func refusesRedirects() async throws {
        let transport = fixtureTransport()
        let target = JevHTTPFixture(.respond("redirected"))
        let fixture = JevHTTPFixture(.redirect(target.url))
        defer { fixture.remove(); target.remove() }
        await #expect(throws: (any Error).self) { try await transport.send(fixture.request) }
        #expect(target.startCount == 0)
        try await eventually { transport.activeRequests == 0 }
    }
#endif
}

private struct JevHTTPTimeout: Error {}

private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw JevHTTPTimeout()
}

private func fixtureTransport() -> URLSessionJevHTTPTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [JevHTTPURLProtocol.self]
    return URLSessionJevHTTPTransport(configuration: configuration)
}

// Mutable fixture state and the registry are protected by locks; protocol callbacks are dispatched on one queue.
private final class JevHTTPFixture: @unchecked Sendable {
    enum Reply {
        case respond(String)
        case hang
        case redirect(URL)
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "JevHTTPFixture")
    private var starts = 0
    private var stops = 0
    private var last: URLRequest?
    let url = URL(string: "https://jev-fixture.invalid/\(UUID().uuidString)")!
    let reply: Reply

    init(_ reply: Reply) {
        self.reply = reply
        JevHTTPURLProtocol.registry.insert(self)
    }

    var request: URLRequest { URLRequest(url: url) }
    var startCount: Int { lock.withLock { starts } }
    var stopped: Bool { lock.withLock { stops > 0 } }
    var lastRequest: URLRequest? { lock.withLock { last } }
    func remove() { JevHTTPURLProtocol.registry.remove(url) }
    func stop() { lock.withLock { stops += 1 } }

    func start(_ instance: JevHTTPURLProtocol) {
        lock.withLock {
            starts += 1
            last = instance.request
        }
        let reply = reply
        queue.async {
            switch reply {
            case .respond(let text):
                let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                               headerFields: ["X-Fixture": "jev", "Content-Type": "application/json"])!
                instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
                instance.client?.urlProtocol(instance, didLoad: Data(text.utf8))
                instance.client?.urlProtocolDidFinishLoading(instance)
            case .hang:
                break
            case .redirect(let target):
                let response = HTTPURLResponse(url: instance.request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                               headerFields: ["Location": target.absoluteString])!
                instance.client?.urlProtocol(instance, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            }
        }
    }
}

private final class JevHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [URL: JevHTTPFixture] = [:]
    func insert(_ fixture: JevHTTPFixture) { lock.withLock { fixtures[fixture.url] = fixture } }
    func remove(_ url: URL) { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
    func get(_ url: URL?) -> JevHTTPFixture? { lock.withLock { url.flatMap { fixtures[$0] } } }
}

// This subclass adds no mutable state; the shared registry locks all access.
private final class JevHTTPURLProtocol: URLProtocol {
    static let registry = JevHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let fixture = Self.registry.get(request.url) { fixture.start(self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    }
    override func stopLoading() { Self.registry.get(request.url)?.stop() }
}

#if !canImport(FoundationNetworking)
extension JevHTTPURLProtocol: @unchecked Sendable {}
#endif
