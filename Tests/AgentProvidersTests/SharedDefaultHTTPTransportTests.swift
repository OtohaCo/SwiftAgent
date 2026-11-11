#if canImport(Network)
import Foundation
import Network
import Testing
@testable import AgentProviders

struct SharedDefaultHTTPTransportTests {
    @Test func defaultCopiesShareRequestsAndCancelIndependently() async throws {
        let server = try OpenHTTPResponses()
        defer { server.stop() }
        try await waitUntil { server.ready }
        let first = URLSessionProviderHTTPTransport.shared
        let second = URLSessionProviderHTTPTransport.shared
        let firstRequest = server.request("first")
        let secondRequest = server.request("second")
        let one = Task { do { for try await _ in first.stream(firstRequest) {} } catch {} }
        let two = Task { do { for try await _ in second.stream(secondRequest) {} } catch {} }
        defer { one.cancel(); two.cancel() }
        try await waitUntil { server.requests == 2 }
        let firstCount = first.activeRequests
        let secondCount = second.activeRequests
        #expect(firstCount == 2)
        #expect(secondCount == 2)
        guard firstCount == 2, secondCount == 2 else { return }
        one.cancel()
        await one.value
        try await waitUntil { first.activeRequests == 1 }
        #expect(second.activeRequests == 1)
        two.cancel()
        await two.value
        try await waitUntil { first.activeRequests == 0 && second.activeRequests == 0 }
    }
}

/// Only loopback traffic: each response stays open until its consumer cancels.
private final class OpenHTTPResponses: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "shared-http-transport-fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var started = false
    private var received = 0
    var ready: Bool { lock.withLock { started } }
    var requests: Int { lock.withLock { received } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.lock.withLock { self?.started = true } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
                guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
                self.lock.withLock { self.received += 1 }
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx\r\n".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in })
            }
        }
        listener.start(queue: queue)
    }
    func request(_ path: String) -> URLRequest {
        URLRequest(url: URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")!)
    }
    func stop() {
        listener.cancel()
        let all = lock.withLock { let all = connections; connections = []; return all }
        for connection in all { connection.cancel() }
    }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw FixtureWaitExpired() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
private struct FixtureWaitExpired: Error {}
#endif
