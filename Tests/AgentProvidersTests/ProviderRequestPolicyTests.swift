import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

struct ProviderRequestPolicyTests {
    @Test(arguments: ["gemini", "anthropic", "openai", "deepseek"])
    func cleanEOFMissingTerminalIsTransport(provider: String) async throws {
        let transport = FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data()])
        let adapter: any ModelProvider
        switch provider {
        case "gemini": adapter = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: transport)
        case "anthropic": adapter = try AnthropicProvider(apiKey: "key", transport: transport)
        case "openai": adapter = try OpenAIResponsesProvider(apiKey: "key", transport: transport)
        default: adapter = try DeepSeekResponsesProvider(apiKey: "key", transport: transport)
        }
        do {
            for try await _ in adapter.stream(request: .init(model: .init(provider: provider, name: "fixture"), messages: [.user([.text("Hi")])])) {}
            Issue.record("Expected early EOF")
        } catch let error as ModelProviderError {
            #expect(error.kind == .transport)
            #expect(error.diagnostic?.reason.rawValue == "streamEndedEarly")
        }
    }

    @Test(arguments: [(429, "insufficient_quota", "quotaExhausted"),
                      (429, "rate_limit_exceeded", "rateLimited"),
                      (404, "model_not_found", "modelNotFound"),
                      (529, "overloaded_error", "overloaded")])
    func boundedHTTPClassification(status: Int, code: String, expected: String) async throws {
        let transport = FixtureHTTPTransport(probe: ProviderRequestProbe(),
            bodies: [Data(#"{"error":{"code":"\#(code)","type":"\#(code)","message":"private payload"}}"#.utf8)], status: status)
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: transport)
        do {
            for try await _ in provider.stream(request: geminiRequest) {}
            Issue.record("Expected failure")
        } catch let error as ModelProviderError {
            #expect(error.kind.rawValue == expected)
            #expect(!String(reflecting: error).contains("private payload"))
        }
    }
}

extension ProviderRequestPolicyTests {
    @Test func retriesBeforeOutputWithoutDuplicatingStartAndCapsBackoff() async throws {
        let probe = ProviderRequestProbe()
        let transport = PolicySequenceTransport(probe: probe, first: Data("data: {\"usageMetadata\":{\"promptTokenCount\":1}}\n\n".utf8), second: geminiTextFixture)
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: transport)
        let sleeps = PolicySleeps()
        let policy = try ProviderRequestPolicy(maximumAttempts: 2, initialBackoff: .seconds(2), maximumBackoff: .seconds(3), maximumRetryAfter: .seconds(4))
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: policy,
            clock: .init(now: { .zero }, sleep: { await sleeps.record($0) }, jitter: { 1 }))
        var accumulator = ModelEventAccumulator()
        for try await event in wrapped.stream(request: geminiRequest) { try accumulator.append(event) }
        #expect(try accumulator.finish().stopReason == .endTurn)
        #expect(await probe.requests.count == 2)
        #expect(await sleeps.values == [.seconds(2)])
    }

    @Test func partialOutputNeverRetries() async throws {
        let probe = ProviderRequestProbe()
        let partial = try geminiFixture(parts: [.object(["text": .string("partial")])], reason: nil)
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }),
            transport: PolicySequenceTransport(probe: probe, first: partial, second: geminiTextFixture))
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: try .init(maximumAttempts: 3))
        var seen = false
        do {
            for try await event in wrapped.stream(request: geminiRequest) { if case .textDelta = event { seen = true } }
            Issue.record("Expected EOF")
        } catch let error as ModelProviderError { #expect(error.diagnostic?.reason == .streamEndedEarly) }
        #expect(seen)
        #expect(await probe.requests.count == 1)
    }
}

private actor PolicySleeps {
    var values: [Duration] = []
    func record(_ value: Duration) { values.append(value) }
}

private struct PolicySequenceTransport: ProviderHTTPTransport {
    let probe: ProviderRequestProbe
    let first: Data
    let second: Data
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let index = await probe.record(request)
                continuation.yield(.response(status: 200, headers: [:]))
                continuation.yield(.data(index == 1 ? first : second))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ProviderRequestPolicyTests {
    @Test(arguments: ["first", "after", "total"])
    func controlledIdleAndTotalTimeoutsCancelTransport(mode: String) async throws {
        let sleeps = PolicyManualSleeper(), output = PolicySignal(), cancelled = PolicySignal(), started = PolicySignal()
        let transport = PolicyStallingTransport(partial: mode == "after", cancelled: cancelled, started: started)
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport: transport)
        let policy = try ProviderRequestPolicy(
            idleBeforeFirstOutput: mode == "total" ? nil : .seconds(10),
            idleAfterOutput: mode == "after" ? .seconds(3) : nil,
            totalDeadline: mode == "total" ? .seconds(5) : nil)
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: policy,
            clock: .init(now: { .zero }, sleep: { try await sleeps.sleep($0) }, jitter: { 0 }))
        let consume = Task {
            do {
                for try await event in wrapped.stream(request: geminiRequest) {
                    if case .textDelta = event { await output.fire() }
                }
                Issue.record("Expected timeout")
            } catch let error as ModelProviderError {
                let reason: ModelProviderError.Diagnostic.Reason = mode == "first"
                    ? .firstOutputTimedOut : (mode == "after" ? .outputIdleTimedOut : .requestDeadlineExceeded)
                #expect(error.diagnostic?.reason == reason)
            }
        }
        await started.wait()
        if mode == "after" { await output.wait() }
        let expected = Duration.seconds(mode == "first" ? 10 : (mode == "after" ? 3 : 5))
        let duration = await sleeps.fireNext(expected: expected)
        #expect(duration == .seconds(mode == "first" ? 10 : (mode == "after" ? 3 : 5)))
        try await consume.value
        await cancelled.wait()
    }

    @Test func cancellationDoesNotRetry() async throws {
        let cancelled = PolicySignal(), entered = PolicySignal(), probe = ProviderRequestProbe()
        let provider = try GeminiProvider(credentials: .init(apiKey: { "key" }),
            transport: PolicyStallingTransport(partial: true, cancelled: cancelled, probe: probe))
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: try .init(maximumAttempts: 3))
        let consume = Task {
            do {
                for try await event in wrapped.stream(request: geminiRequest) {
                    if case .textDelta = event { await entered.fire() }
                }
            } catch is CancellationError {}
            catch { Issue.record("Expected cancellation, got \(error)") }
        }
        await entered.wait()
        consume.cancel()
        await consume.value
        await cancelled.wait()
        #expect(await probe.requests.count == 1)
    }

    @Test func routePolicyAcceptsOverloadButRejectsQuotaRetries() throws {
        let policy = try ModelProviderFallbackPolicy(maxAttempts: 2, retryableKinds: [.overloaded])
        #expect(policy.retryableKinds.contains(.overloaded))
        #expect(throws: ModelProviderFallbackPolicyError.invalidRetryableKinds) {
            try ModelProviderFallbackPolicy(maxAttempts: 2, retryableKinds: [.quotaExhausted])
        }
    }

    @Test func retryDelayCapsAndInvalidConfiguration() throws {
        let policy = try ProviderRequestPolicy(maximumAttempts: 10, initialBackoff: .seconds(2),
            maximumBackoff: .seconds(8), maximumRetryAfter: .seconds(12))
        #expect(policy.delay(after: 1, retryAfter: nil, jitter: 0) == .seconds(1))
        #expect(policy.delay(after: 9, retryAfter: nil, jitter: 1) == .seconds(8))
        #expect(policy.delay(after: 9, retryAfter: .seconds(9_999), jitter: 1) == .seconds(12))
        #expect(throws: ModelProviderError.self) { try ProviderRequestPolicy(maximumAttempts: 0) }
        #expect(throws: ModelProviderError.self) { try ProviderRequestPolicy(totalDeadline: .zero) }
    }
}

private actor PolicySignal {
    var fired = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func fire() { fired = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func wait() async {
        if fired { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor PolicyManualSleeper {
    var pending: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []
    var cancelled: Set<UUID> = []
    var observer: CheckedContinuation<Void, Never>?
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled.remove(id) != nil || Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                pending.append((id, duration, continuation))
                observer?.resume(); observer = nil
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.0 == id }) {
            pending.remove(at: index).2.resume(throwing: CancellationError())
        } else { cancelled.insert(id) }
    }
    func fireNext(expected: Duration) async -> Duration {
        while !pending.contains(where: { $0.1 == expected }) { await withCheckedContinuation { observer = $0 } }
        let next = pending.remove(at: pending.firstIndex(where: { $0.1 == expected })!)
        next.2.resume()
        return next.1
    }
}

private struct PolicyStallingTransport: ProviderHTTPTransport {
    let partial: Bool
    let cancelled: PolicySignal
    var probe: ProviderRequestProbe? = nil
    var started: PolicySignal? = nil
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let probe { await probe.record(request) }
                continuation.yield(.response(status: 200, headers: [:]))
                if partial {
                    continuation.yield(.data(try geminiFixture(parts: [.object(["text": .string("partial")])], reason: nil)))
                } else {
                    continuation.yield(.data(Data("data: {\"usageMetadata\":{\"promptTokenCount\":1}}\n\n".utf8)))
                }
                await started?.fire()
                // Deliberately retain the stream until the consumer cancels.
            }
            continuation.onTermination = { _ in task.cancel(); Task { await cancelled.fire() } }
        }
    }
}

extension ProviderRequestPolicyTests {
    @Test(arguments: [ModelEvent.reasoningDelta("thinking"),
        .toolCallStarted(.init(rawValue: "call"), name: "tool"),
        .toolCallArgumentsDelta(.init(rawValue: "call"), "{}")])
    func anyContentOrToolEventBlocksReplay(event: ModelEvent) async throws {
        let calls = PolicySleeps()
        let provider = PolicyEventProvider(event: event, calls: calls)
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider, policy: try .init(maximumAttempts: 3))
        do {
            for try await _ in wrapped.stream(request: geminiRequest) {}
            Issue.record("Expected transport failure")
        } catch let error as ModelProviderError { #expect(error.kind == .transport) }
        #expect(await calls.values.count == 1)
    }

    @Test func totalBudgetIncludesBackoffAndQuotaNeverRetries() async throws {
        let calls = PolicySleeps()
        let provider = PolicyEventProvider(event: nil, calls: calls)
        let sleeps = PolicyManualSleeper()
        let wrapped = ProviderRequestPolicyProvider(wrapping: provider,
            policy: try .init(totalDeadline: .seconds(1), maximumAttempts: 3, initialBackoff: .seconds(2)),
            clock: .init(now: { .zero }, sleep: { try await sleeps.sleep($0) }, jitter: { 1 }))
        do {
            for try await _ in wrapped.stream(request: geminiRequest) {}
            Issue.record("Expected deadline")
        } catch let error as ModelProviderError { #expect(error.diagnostic?.reason == .requestDeadlineExceeded) }
        #expect(await calls.values.count == 1)

        let probe = ProviderRequestProbe()
        let inner = try GeminiProvider(credentials: .init(apiKey: { "key" }), transport:
            FixtureHTTPTransport(probe: probe, bodies: [Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)], status: 429))
        let quota = ProviderRequestPolicyProvider(wrapping: inner, policy: try .init(maximumAttempts: 3))
        do { for try await _ in quota.stream(request: geminiRequest) {} }
        catch let error as ModelProviderError { #expect(error.kind == .quotaExhausted) }
        #expect(await probe.requests.count == 1)
    }
}

private struct PolicyEventProvider: ModelProvider {
    let event: ModelEvent?
    let calls: PolicySleeps
    var descriptor: ModelProviderDescriptor { .init(id: "fixture", capabilities: [.streaming]) }
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await calls.record(.zero)
            try emit(.responseStarted(.init(id: "r", model: request.model)))
            if let event { try emit(event) }
            throw ModelProviderError(kind: .transport, message: "Fixture interrupted.")
        }
    }
}

extension ProviderRequestPolicyTests {
    @Test func failedAttemptReportsSurvivePreOutputBuffering() async throws {
        let calls = PolicySleeps()
        let report = ModelRequestAttempt(ordinal: 1, model: geminiRequest.model, candidate: nil,
            responseID: nil, usage: .init(inputTokens: 10),
            outcome: .failed(.provider(.transport, nil)), duration: .seconds(1))
        let wrapped = ProviderRequestPolicyProvider(wrapping: PolicyEventProvider(event: .requestAttempt(report), calls: calls),
            policy: try .init())
        var reports: [ModelRequestAttempt] = []
        do {
            for try await event in wrapped.stream(request: geminiRequest) {
                if case .requestAttempt(let value) = event { reports.append(value) }
            }
        } catch let error as ModelProviderError { #expect(error.kind == .transport) }
        #expect(reports == [report])
    }
}
