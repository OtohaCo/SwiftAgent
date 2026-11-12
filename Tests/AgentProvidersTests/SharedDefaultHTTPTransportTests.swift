#if canImport(Darwin) || os(Linux)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

@Suite(.serialized)
struct SharedDefaultHTTPTransportTests {
    @Test func concurrentResponsesRemainSeparateAndTheClientCanBeReused() async throws {
        let server = try TransportLoopbackServer()
        defer { server.stop() }
        let transport = URLSessionProviderHTTPTransport.shared
        let first = Reading(transport, server.request("/first"))
        let second = Reading(transport, server.request("/second"))
        defer { first.cancel(); second.cancel() }
        try await eventually { first.body == "data: /first-start\n\n" && second.body == "data: /second-start\n\n" }
        #expect(transport.activeRequests == 2)
        #expect(transport.liveExchanges == 2)
        try server.finish("/second", event: "second-end")
        try server.finish("/first", event: "first-end")
        try await eventually { first.finished && second.finished }
        #expect(first.body == "data: /first-start\n\ndata: first-end\n\n")
        #expect(second.body == "data: /second-start\n\ndata: second-end\n\n")
        #expect(first.statuses == [200] && second.statuses == [200])
        #expect(first.succeeded && second.succeeded)
        try await assertDrained(transport)
        try await thirdRequest(transport, server)
    }

    @Test func cancellingOneResponseLeavesTheOtherStreamingToCompletion() async throws {
        let server = try TransportLoopbackServer()
        defer { server.stop() }
        let transport = URLSessionProviderHTTPTransport.shared
        let first = Reading(transport, server.request("/cancelled"))
        let second = Reading(transport, server.request("/survivor"))
        defer { first.cancel(); second.cancel() }
        try await eventually { !first.body.isEmpty && !second.body.isEmpty }
        first.cancel()
        try await eventually {
            first.finished && transport.activeRequests == 1 && server.disconnectedPaths.contains("/cancelled")
        }
        #expect(first.cancelled)
        #expect(!second.finished)
        #expect(!server.disconnectedPaths.contains("/survivor"))
        try server.finish("/survivor", event: "survivor-end")
        try await eventually { second.finished }
        #expect(second.succeeded)
        #expect(second.body == "data: /survivor-start\n\ndata: survivor-end\n\n")
        #expect(first.body == "data: /cancelled-start\n\n")
        try await assertDrained(transport)
        try await thirdRequest(transport, server)
    }

    @Test func authorizationIsPerRequestAndCookiesAreNeverReplayed() async throws {
        let server = try TransportLoopbackServer()
        defer { server.stop() }
        let transport = URLSessionProviderHTTPTransport.shared
        let first = Reading(transport, server.request("/account-a", authorization: "Bearer fixture-a"))
        let second = Reading(transport, server.request("/account-b", authorization: "Bearer fixture-b"))
        defer { first.cancel(); second.cancel() }
        try await eventually { !first.body.isEmpty && !second.body.isEmpty }
        #expect(server.requests.first { $0.path == "/account-a" }?.headers["authorization"] == "Bearer fixture-a")
        #expect(server.requests.first { $0.path == "/account-b" }?.headers["authorization"] == "Bearer fixture-b")
        try server.finish("/account-a", event: "a-end")
        try server.finish("/account-b", event: "b-end")
        try await eventually { first.finished && second.finished }
        #expect(first.succeeded && second.succeeded)
        try await assertDrained(transport)
        try await thirdRequest(transport, server)
        let third = try #require(server.requests.first { $0.path == "/third" })
        #expect(third.headers["authorization"] == nil)
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    private func thirdRequest(_ transport: URLSessionProviderHTTPTransport, _ server: TransportLoopbackServer) async throws {
        let third = Reading(transport, server.request("/third"))
        defer { third.cancel() }
        try await eventually { third.body == "data: /third-start\n\n" }
        try server.finish("/third", event: "third-end")
        try await eventually { third.finished }
        #expect(third.succeeded && third.statuses == [200])
        #expect(third.body == "data: /third-start\n\ndata: third-end\n\n")
        try await assertDrained(transport)
    }

    private func assertDrained(_ transport: URLSessionProviderHTTPTransport) async throws {
        try await eventually { transport.activeRequests == 0 && transport.liveExchanges == 0 }
        #expect(transport.activeRequests == 0)
        #expect(transport.liveExchanges == 0)
    }
}

private final class Reading: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var body = Data()
        var statuses: [Int] = []
        var finished = false
        var succeeded = false
        var cancelled = false
    }
    private let state = State()
    private let task: Task<Void, Never>
    var body: String { state.lock.withLock { String(decoding: state.body, as: UTF8.self) } }
    var statuses: [Int] { state.lock.withLock { state.statuses } }
    var finished: Bool { state.lock.withLock { state.finished } }
    var succeeded: Bool { state.lock.withLock { state.succeeded } }
    var cancelled: Bool { state.lock.withLock { state.cancelled } }

    init(_ transport: URLSessionProviderHTTPTransport, _ request: URLRequest) {
        let state = state
        task = Task {
            do {
                for try await event in transport.stream(request) {
                    state.lock.withLock {
                        switch event {
                        case .response(let status, _): state.statuses.append(status)
                        case .data(let data): state.body.append(data)
                        }
                    }
                }
                // AsyncThrowingStream cancellation may end iteration without throwing.
                try Task.checkCancellation()
                state.lock.withLock { state.succeeded = true; state.finished = true }
            } catch {
                state.lock.withLock {
                    state.cancelled = error is CancellationError
                    state.finished = true
                }
            }
        }
    }
    func cancel() { task.cancel() }
}

private func eventually(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw LoopbackWaitExpired() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
private struct LoopbackWaitExpired: Error {}
#endif
