import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

/// Wire progress that decodes to no `ModelEvent`, and the policy option that counts it.
struct ProviderWireActivityTests {
    /// Each adapter receives bytes that carry no content: SSE comments, `ping` and lifecycle
    /// events, an encrypted reasoning item, a signature-only reasoning delta or thought part.
    /// None of them produces an output event, so without wire activity the policy would see
    /// silence; every chunk is reported as activity.
    @Test(arguments: ["openai", "anthropic", "gemini", "deepseek"])
    func progressWithoutContentProducesNoOutputButIsReported(provider: String) async throws {
        let chunks = wireOnlyChunks(provider)
        let transport = WireChunkTransport(chunks: chunks)
        let adapter: any ModelProvider
        switch provider {
        case "gemini": adapter = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: transport)
        case "anthropic": adapter = try AnthropicProvider(apiKey: "key", transport: transport)
        case "openai": adapter = try OpenAIResponsesProvider(apiKey: "key", transport: transport)
        default: adapter = try DeepSeekResponsesProvider(apiKey: "key", transport: transport)
        }
        let recorder = ProviderWireActivityRecorder {}
        let stream = ProviderWireActivity.$recorder.withValue(recorder) {
            adapter.stream(request: .init(model: .init(provider: provider, name: "fixture"), messages: [.user([.text("Hi")])]))
        }
        var events: [ModelEvent] = []
        do {
            for try await event in stream { events.append(event) }
            Issue.record("Expected the stream to end without a terminal")
        } catch let error as ModelProviderError {
            #expect(error.diagnostic?.reason == .streamEndedEarly, "\(error)")
        }
        #expect(events.allSatisfy(Self.isNotOutput), "\(events)")
        #expect(recorder.reports == chunks.count)
    }

    @Test func reportOutsideAPolicyDoesNothing() {
        ProviderWireActivity.report()
    }

    /// Keep-alives for longer than the idle budget keep the request alive; the content
    /// that follows completes it. The idle timer restarts on each keep-alive.
    @Test func wireActivityRestartsTheIdleBudgetWithoutCountingAsOutput() async throws {
        let sleeper = WireManualSleeper(), feed = WireFeedTransport()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: feed)
        let policy = try ProviderRequestPolicy(idleBeforeFirstOutput: .seconds(10), idleCountsWireActivity: true)
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: policy,
            clock: .init(now: { .zero }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 }))
        let consume = Task { () throws -> [ModelEvent] in
            var events: [ModelEvent] = []
            for try await event in wrapped.stream(request: geminiRequest) { events.append(event) }
            return events
        }
        await sleeper.waitForRegistrations(1)
        await feed.waitForStart()
        for round in 1...3 {
            feed.send(Data(": keep-alive\n\n".utf8))
            await sleeper.waitForRegistrations(round + 1)
            #expect(await sleeper.pendingCount == 1)
        }
        feed.send(geminiTextFixture)
        feed.finish()
        let events = try await consume.value
        #expect(events.contains(.textDelta("Hello")))
        #expect(await sleeper.firedCount == 0)
    }

    /// With the option on, a stream that sends nothing more still times out.
    @Test func silentStreamStillTimesOutWhenWireActivityCounts() async throws {
        let sleeper = WireManualSleeper(), feed = WireFeedTransport()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: feed)
        let policy = try ProviderRequestPolicy(idleBeforeFirstOutput: .seconds(10), idleCountsWireActivity: true)
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: policy,
            clock: .init(now: { .zero }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 }))
        let consume = Task { () async -> ModelProviderError? in
            do { for try await _ in wrapped.stream(request: geminiRequest) {} } catch let error as ModelProviderError { return error }
            catch {}
            return nil
        }
        await feed.waitForStart()
        await sleeper.waitForRegistrations(1)
        await sleeper.fireOnly()
        #expect(await consume.value?.diagnostic?.reason == .firstOutputTimedOut)
    }

    /// Without the option, keep-alives do not restart the budget.
    @Test func keepAlivesDoNotCountByDefault() async throws {
        let sleeper = WireManualSleeper(), feed = WireFeedTransport()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: feed)
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: try .init(idleBeforeFirstOutput: .seconds(10)),
            clock: .init(now: { .zero }, sleep: { try await sleeper.sleep($0) }, jitter: { 0 }))
        let consume = Task { () async -> ModelProviderError? in
            do { for try await _ in wrapped.stream(request: geminiRequest) {} } catch let error as ModelProviderError { return error }
            catch {}
            return nil
        }
        await feed.waitForStart()
        await sleeper.waitForRegistrations(1)
        feed.send(Data(": keep-alive\n\n".utf8))
        await feed.waitForDelivered(1)
        await sleeper.fireOnly()
        #expect(await consume.value?.diagnostic?.reason == .firstOutputTimedOut)
        #expect(await sleeper.registrations == 1)
    }

    private static func isNotOutput(_ event: ModelEvent) -> Bool {
        switch event {
        case .responseStarted, .usage, .inputTransformations, .requestAttempt: true
        default: false
        }
    }

    private func wireOnlyChunks(_ provider: String) -> [Data] {
        func frame(_ name: String?, _ json: String) -> Data {
            Data(((name.map { "event: \($0)\n" } ?? "") + "data: \(json)\n\n").utf8)
        }
        let keepAlive = Data(": keep-alive\n\n".utf8)
        switch provider {
        case "openai":
            return [
                frame("response.created", #"{"type":"response.created","response":{"id":"resp_w","object":"response","status":"in_progress","model":"fixture","output":[]},"sequence_number":0}"#),
                keepAlive,
                frame("response.in_progress", #"{"type":"response.in_progress","response":{"id":"resp_w","object":"response","status":"in_progress","model":"fixture","output":[]},"sequence_number":1}"#),
                frame("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs_w","type":"reasoning","summary":[],"encrypted_content":"opaque"},"sequence_number":2}"#),
                keepAlive,
            ]
        case "anthropic":
            return [
                frame("message_start", #"{"type":"message_start","message":{"id":"msg-w","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#),
                frame("ping", #"{"type":"ping"}"#),
                frame("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
                frame("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"c2ln"}}"#),
                frame("ping", #"{"type":"ping"}"#),
                keepAlive,
            ]
        case "gemini":
            return [
                frame(nil, #"{"responseId":"r","candidates":[{"index":0,"content":{"role":"model","parts":[{"thought":true,"text":"","thoughtSignature":"c2ln"}]}}]}"#),
                keepAlive,
                frame(nil, #"{"responseId":"r","usageMetadata":{"promptTokenCount":1,"thoughtsTokenCount":9}}"#),
                keepAlive,
            ]
        default:
            return [
                frame("response.created", #"{"type":"response.created","response":{"id":"resp-w","model":"fixture","status":"in_progress"},"sequence_number":0}"#),
                keepAlive,
                frame("response.in_progress", #"{"type":"response.in_progress","response":{"id":"resp-w","model":"fixture","status":"in_progress"},"sequence_number":1}"#),
                keepAlive,
            ]
        }
    }
}

/// Sends each chunk as its own data event, then ends without a terminal.
private struct WireChunkTransport: ProviderHTTPTransport {
    let chunks: [Data]
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
            for chunk in chunks { continuation.yield(.data(chunk)) }
            continuation.finish()
        }
    }
}

/// A transport the test feeds chunk by chunk.
private final class WireFeedTransport: ProviderHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ProviderHTTPEvent, Error>.Continuation?
    private let started = WireCounter(), delivered = WireCounter()

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ProviderHTTPEvent, Error>.makeStream()
        continuation.yield(.response(status: 200, headers: ["Content-Type": "text/event-stream"]))
        lock.withLock { self.continuation = continuation }
        let delivered = self.delivered
        Task { await started.increment() }
        // Count a chunk as delivered once the adapter has asked for the event after it.
        return AsyncThrowingStream { output in
            let task = Task {
                var count = 0
                do {
                    for try await event in stream {
                        output.yield(event)
                        if case .data = event { count += 1; await delivered.set(count) }
                    }
                    output.finish()
                } catch { output.finish(throwing: error) }
            }
            output.onTermination = { _ in task.cancel(); continuation.finish() }
        }
    }
    func send(_ data: Data) { _ = lock.withLock { continuation?.yield(.data(data)) } }
    func finish() { lock.withLock { continuation?.finish() } }
    func waitForStart() async { await started.wait(atLeast: 1) }
    func waitForDelivered(_ count: Int) async { await delivered.wait(atLeast: count) }
}

private actor WireCounter {
    var value = 0
    var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func increment() { set(value + 1) }
    func set(_ new: Int) {
        value = new
        let ready = waiters.filter { $0.0 <= value }
        waiters.removeAll { $0.0 <= value }
        for waiter in ready { waiter.1.resume() }
    }
    /// Waits for `target`, or records an issue after a bound so a missing step fails instead of hanging.
    func wait(atLeast target: Int) async {
        if value >= target { return }
        let bound = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.expire(target)
        }
        await withCheckedContinuation { waiters.append((target, $0)) }
        bound.cancel()
    }
    private func expire(_ target: Int) {
        guard value < target, waiters.contains(where: { $0.0 == target }) else { return }
        Issue.record("Timed out waiting for \(target), reached \(value)")
        let expired = waiters.filter { $0.0 == target }
        waiters.removeAll { $0.0 == target }
        for waiter in expired { waiter.1.resume() }
    }
}

/// Sleeps that end only when the test fires them or the sleeping task is cancelled.
private actor WireManualSleeper {
    private var pending: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<UUID> = []
    private let registered = WireCounter()
    private(set) var registrations = 0
    private(set) var firedCount = 0
    var pendingCount: Int { pending.count }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                pending.append((id, continuation))
                registrations += 1
                let count = registrations
                Task { await registered.set(count) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.0 == id }) {
            pending.remove(at: index).1.resume(throwing: CancellationError())
        } else { cancelled.insert(id) }
    }
    /// Waits until `count` sleeps have started and every earlier one has been cancelled.
    func waitForRegistrations(_ count: Int) async {
        await registered.wait(atLeast: count)
        while pending.count > 1 { await Task.yield() }
    }
    func fireOnly() {
        #expect(pending.count == 1)
        guard !pending.isEmpty else { return }
        firedCount += 1
        pending.removeFirst().1.resume()
    }
}
