import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

struct ProviderHTTPTransportTests {
    @Test func sanitizesTransportFailureWithoutRetrying() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let received = ProviderHTTPReceived()
        let consumer = collect(fixture, into: received)
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        fixture.perform { instance in
            instance.client?.urlProtocol(instance, didFailWithError: NSError(
                domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "sensitive fixture payload",
                           NSURLErrorFailingURLErrorKey: URL(string: "https://private.invalid/secret")!]))
        }
        try await eventually { await received.completed }
        #expect(await received.error as? ModelProviderError == ModelProviderError(
            kind: .transport, message: "HTTP transport failed."))
        #expect(fixture.startCount == 1)
    }

    @Test func rejectsNonHTTPResponse() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let received = ProviderHTTPReceived()
        let consumer = collect(fixture, into: received)
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        fixture.perform { instance in
            let response = URLResponse(url: instance.request.url!, mimeType: "text/plain",
                                       expectedContentLength: 1, textEncodingName: nil)
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            instance.client?.urlProtocol(instance, didLoad: Data([1]))
            instance.client?.urlProtocolDidFinishLoading(instance)
        }
        try await eventually { await received.completed }
        #expect(await (received.error as? ModelProviderError)?.kind == .invalidResponse)
        #expect(await received.count == 0)
    }

    @Test func disablesPersistenceEvenForInjectedConfiguration() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = [ProviderHTTPURLProtocol.self]
        let transport = URLSessionProviderHTTPTransport(configurationFactory: { configuration })
        let stream = transport.stream(fixture.request)
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        let consumer = Task { for try await _ in stream {} }
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        fixture.perform { instance in
            #expect(!instance.request.httpShouldHandleCookies)
            #expect(instance.request.cachePolicy == .reloadIgnoringLocalCacheData)
        }
        fixture.respond()
        fixture.finish()
        try await consumer.value
    }

    @Test func consumerCancellationStopsUnderlyingRequest() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let consumer = Task {
            for try await _ in fixture.transport.stream(fixture.request) {}
        }
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        consumer.cancel()
        try await eventually { fixture.stopped }
        _ = await consumer.result
    }

    @Test func abandoningConsumerStopsUnderlyingRequest() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let received = ProviderHTTPReceived()
        let consumer = Task {
            do {
                for try await _ in fixture.transport.stream(fixture.request) { break }
                await received.complete(nil)
            } catch { await received.complete(error) }
        }
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        fixture.respond()
        fixture.send("first")
        try await eventually { await received.completed }
        #expect(await received.error == nil)
        try await eventually { fixture.stopped }
    }

#if !os(Linux)
    // swift-corelibs-foundation URLSession fatals when a URLProtocol reports a redirect.
    @Test func rejectsSameAndCrossOriginRedirects() async throws {
        for destination in ["https://fixture.invalid/redirected", "https://other.invalid/redirected"] {
            let fixture = ProviderHTTPFixture()
            defer { fixture.remove() }
            let target = ProviderHTTPFixture(url: URL(string: destination)!)
            defer { target.remove() }
            let received = ProviderHTTPReceived()
            let consumer = Task {
                do {
                    for try await event in fixture.transport.stream(fixture.request) {
                        await received.append(event)
                    }
                    await received.complete(nil)
                } catch { await received.complete(error) }
            }
            defer { consumer.cancel() }
            try await fixture.waitForStart()
            fixture.redirect(to: URL(string: destination)!)
            try await eventually { await received.completed }
            #expect(await (received.error as? ModelProviderError)?.kind == .invalidResponse)
            #expect(await received.count == 0)
            #expect(target.startCount == 0)
        }
    }
#endif

    @Test func alreadyCancelledCallerDoesNotStartRequest() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let consumer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                for try await _ in fixture.transport.stream(fixture.request) {}
                Issue.record("Expected cancellation")
            } catch { #expect(error is CancellationError) }
        }
        await consumer.value
        #expect(fixture.startCount == 0)
    }

    @Test func sessionCancellationIsCancellationError() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let received = ProviderHTTPReceived()
        let consumer = collect(fixture, into: received)
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        fixture.perform { $0.client?.urlProtocol($0, didFailWithError: URLError(.cancelled)) }
        try await eventually { await received.completed }
        #expect(await received.error is CancellationError)
    }

    @Test func deliversResponseAndSeparateChunksBeforeEOF() async throws {
        let fixture = ProviderHTTPFixture()
        defer { fixture.remove() }
        let received = ProviderHTTPReceived()
        let consumer = Task {
            for try await event in fixture.transport.stream(fixture.request) {
                await received.append(event)
            }
        }
        defer { consumer.cancel() }
        try await fixture.waitForStart()
        fixture.respond()
        fixture.send("first")
        try await eventually { await received.count == 2 }
        fixture.send("second")
        try await eventually { await received.count == 3 }
        let events = await received.events
        guard case .response(let status, let headers) = events[0] else {
            Issue.record("Response must precede bytes")
            return
        }
        #expect(status == 200)
        #expect(headers["X-Fixture"] == "stream")
        guard case .data(let first) = events[1], case .data(let second) = events[2] else {
            Issue.record("Expected separate data events")
            return
        }
        #expect(first == Data("first".utf8))
        #expect(second == Data("second".utf8))
        fixture.finish()
        try await consumer.value
    }
}

private func collect(_ fixture: ProviderHTTPFixture, into received: ProviderHTTPReceived) -> Task<Void, Never> {
    Task {
        do {
            for try await event in fixture.transport.stream(fixture.request) { await received.append(event) }
            await received.complete(nil)
        } catch { await received.complete(error) }
    }
}

private actor ProviderHTTPReceived {
    var events: [ProviderHTTPEvent] = []
    var completed = false
    var error: (any Error)?
    var count: Int { events.count }
    func append(_ event: ProviderHTTPEvent) { events.append(event) }
    func complete(_ error: (any Error)?) { self.error = error; completed = true }
}

private struct ProviderHTTPTimeout: Error {}

private func eventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw ProviderHTTPTimeout()
}

// Mutable fixture state and the registry are protected by locks; protocol callbacks
// are dispatched on one queue so scripted chunks remain ordered.
private final class ProviderHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ProviderHTTPFixture")
    private var active: ProviderHTTPURLProtocol?
    private var stops = 0
    private var starts = 0
    let url: URL

    init(url: URL = URL(string: "https://fixture.invalid/\(UUID().uuidString)")!) {
        self.url = url
        ProviderHTTPURLProtocol.registry.insert(self)
    }
    var request: URLRequest { URLRequest(url: url) }
    var transport: URLSessionProviderHTTPTransport {
        URLSessionProviderHTTPTransport(configurationFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ProviderHTTPURLProtocol.self]
            return configuration
        })
    }
    var stopped: Bool { lock.withLock { stops > 0 } }
    var startCount: Int { lock.withLock { starts } }
    func attach(_ instance: ProviderHTTPURLProtocol) { lock.withLock { active = instance; starts += 1 } }
    func stop() { lock.withLock { stops += 1 } }
    func remove() { ProviderHTTPURLProtocol.registry.remove(url) }
    func waitForStart() async throws {
        try await eventually { self.lock.withLock { self.active != nil } }
    }
    func perform(_ action: @escaping @Sendable (ProviderHTTPURLProtocol) -> Void) {
        queue.async {
            if let instance = self.lock.withLock({ self.active }) { action(instance) }
        }
    }
    func respond() {
        perform { instance in
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: [
                                            "X-Fixture": "stream", "Content-Type": "text/event-stream"
                                           ])!
            instance.client?.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
    }
    func send(_ text: String) {
        perform { $0.client?.urlProtocol($0, didLoad: Data(text.utf8)) }
    }
    func redirect(to url: URL) {
        perform { instance in
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 302,
                                           httpVersion: "HTTP/1.1", headerFields: ["Location": url.absoluteString])!
            instance.client?.urlProtocol(instance, wasRedirectedTo: URLRequest(url: url), redirectResponse: response)
        }
    }
    func finish() { perform { $0.client?.urlProtocolDidFinishLoading($0) } }
}

private final class ProviderHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [URL: ProviderHTTPFixture] = [:]
    func insert(_ fixture: ProviderHTTPFixture) { lock.withLock { fixtures[fixture.url] = fixture } }
    func remove(_ url: URL) { _ = lock.withLock { fixtures.removeValue(forKey: url) } }
    func get(_ url: URL?) -> ProviderHTTPFixture? {
        lock.withLock { url.flatMap { fixtures[$0] } }
    }
}

// This subclass adds no mutable state; the shared registry locks all access.
private final class ProviderHTTPURLProtocol: URLProtocol {
    static let registry = ProviderHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let fixture = Self.registry.get(request.url) { fixture.attach(self) }
        else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
    }
    override func stopLoading() { Self.registry.get(request.url)?.stop() }
}

#if !canImport(FoundationNetworking)
extension ProviderHTTPURLProtocol: @unchecked Sendable {}
#endif
