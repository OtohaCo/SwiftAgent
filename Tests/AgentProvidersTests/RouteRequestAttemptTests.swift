import AgentCore
import AgentModels
import AgentProviders
import Foundation
import Testing

/// A Route asked to report its requests names every request it sends to a candidate, including the
/// ones that failed and what they reported before failing, so the Host can count retries and fallbacks.
struct RouteRequestAttemptTests {
    private static let model = ModelID(provider: "fixture", name: "test")

    @Test func aFallbackReportsTheFailedRequestWithItsUsageThenTheOneThatAnswered() async throws {
        let partial = ModelUsage(inputTokens: 1_200, cachedInputTokens: 1_000)
        let answered = ModelUsage(inputTokens: 1_300, outputTokens: 20, cachedInputTokens: 900,
                                  cacheWriteInputTokens: 300, reasoningTokens: 5)
        let diagnostic = ModelProviderError.Diagnostic(stage: .transport, reason: .connectionLost)
        let primary = AttemptFixtureProvider { request, _, emit in
            try emit(.responseStarted(.init(id: "primary-response", model: request.model)))
            try emit(.usage(partial))
            throw ModelProviderError(kind: .unavailable, message: "fixture", diagnostic: diagnostic)
        }
        let backup = AttemptFixtureProvider { request, _, emit in
            for event in answer(request, "backup", usage: answered) { try emit(event) }
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [.init(id: "primary", provider: primary),
                                                                      .init(id: "backup", provider: backup)],
                                           reportsAttempts: true)
        let request = ModelRequest(model: Self.model, messages: [.user([.text("Hi")])])
        let events = try await collect(route.stream(request: request))

        #expect(attempts(events).map(\.timeless) == [
            .init(ordinal: 1, model: Self.model, candidate: "primary", responseID: "primary-response", usage: partial,
                  outcome: .failed(.provider(.unavailable, diagnostic)), duration: .zero),
            .init(ordinal: 2, model: Self.model, candidate: "backup", responseID: "response", usage: answered,
                  outcome: .completed(.endTurn), duration: .zero),
        ])
        // The reports come first; the answer that follows is the backup's, unchanged.
        #expect(Array(events.dropFirst(2)) == answer(request, "backup", usage: answered))
    }

    @Test func aRequestThatFailsOnEveryCandidateReportsEachBeforeTheFailureIsThrown() async throws {
        let last = ModelProviderError(kind: .rateLimited, message: "fixture")
        let primary = AttemptFixtureProvider { _, _, _ in throw ModelProviderError(kind: .unavailable, message: "fixture") }
        let backup = AttemptFixtureProvider { _, _, _ in throw last }
        let route = try ModelProviderRoute(id: "fixture", candidates: [.init(id: "primary", provider: primary),
                                                                      .init(id: "backup", provider: backup)],
                                           reportsAttempts: true)
        var events: [ModelEvent] = []
        do {
            for try await event in route.stream(request: .init(model: Self.model, messages: [])) { events.append(event) }
            Issue.record("Every candidate failed")
        } catch {
            #expect(error as? ModelProviderError == last)
        }
        #expect(attempts(events).map(\.timeless) == [
            .init(ordinal: 1, model: Self.model, candidate: "primary", responseID: nil, usage: .init(),
                  outcome: .failed(.provider(.unavailable, nil)), duration: .zero),
            .init(ordinal: 2, model: Self.model, candidate: "backup", responseID: nil, usage: .init(),
                  outcome: .failed(.provider(.rateLimited, nil)), duration: .zero),
        ])
        #expect(events.count == 2)
    }

    @Test func aRetryOfTheContinuationOwnerReportsBothOfItsRequests() async throws {
        let owner = AttemptFixtureProvider { request, call, emit in
            switch call {
            case 1:
                let info = ResponseInfo(id: "continuation", model: request.model)
                let state = ModelProviderContinuation(model: request.model, format: "fixture", payload: Data("opaque".utf8))
                try emit(.responseStarted(info))
                try emit(.providerContinuation(state))
                try emit(.responseCompleted(.init(info: info, content: [.providerContinuation(state)], stopReason: .endTurn)))
            case 2:
                throw ModelProviderError(kind: .unavailable, message: "fixture")
            default:
                for event in answer(request, "again", usage: .init(inputTokens: 5)) { try emit(event) }
            }
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [.init(id: "owner", provider: owner)],
                                           policy: .init(maxAttempts: 2, maxRetriesPerProvider: 1), reportsAttempts: true)
        let sessionID = UUID(), runID = UUID()
        let first = try await collect(route.stream(request: .init(model: Self.model, messages: [], sessionID: sessionID, runID: runID)))
        let response = try #require(first.compactMap { event -> ModelResponse? in
            if case .responseCompleted(let response) = event { response } else { nil }
        }.first)
        let next = ModelRequest(model: Self.model, messages: [.assistant(content: response.content, toolCalls: [])],
                                sessionID: sessionID, runID: runID)
        let events = try await collect(route.stream(request: next))
        #expect(attempts(events).map(\.timeless) == [
            .init(ordinal: 1, model: Self.model, candidate: "owner", responseID: nil, usage: .init(),
                  outcome: .failed(.provider(.unavailable, nil)), duration: .zero),
            .init(ordinal: 2, model: Self.model, candidate: "owner", responseID: "response", usage: .init(inputTokens: 5),
                  outcome: .completed(.endTurn), duration: .zero),
        ])
    }

    @Test func aRouteNotAskedToReportKeepsItsEventsAsBefore() async throws {
        let primary = AttemptFixtureProvider { _, _, _ in throw ModelProviderError(kind: .unavailable, message: "fixture") }
        let backup = AttemptFixtureProvider { request, _, emit in
            for event in answer(request, "backup", usage: .init()) { try emit(event) }
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [.init(id: "primary", provider: primary),
                                                                      .init(id: "backup", provider: backup)])
        let request = ModelRequest(model: Self.model, messages: [])
        #expect(try await collect(route.stream(request: request)) == answer(request, "backup", usage: .init()))
    }

    @Test func aRunOverARouteRecordsEachRequestTheRouteSentExactlyOnce() async throws {
        let primary = AttemptFixtureProvider { _, _, _ in throw ModelProviderError(kind: .unavailable, message: "fixture") }
        let backup = AttemptFixtureProvider { request, _, emit in
            for event in answer(request, "backup", usage: .init(inputTokens: 8, outputTokens: 1)) { try emit(event) }
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [.init(id: "primary", provider: primary),
                                                                      .init(id: "backup", provider: backup)],
                                           reportsAttempts: true)
        var configuration = AgentConfiguration()
        configuration.reportsModelRequests = true
        let run = try await Agent(model: Self.model, provider: route, configuration: configuration).makeSession().run("Hi")
        var events: [AgentEvent] = []
        for await event in run.events { events.append(event) }
        let result = try await run.wait()
        #expect(result.response.content == [.text("backup")])
        let records = events.compactMap { event -> ModelRequestAttempt? in
            if case .model(.requestAttempt(let record)) = event { record } else { nil }
        }
        #expect(records.map(\.timeless) == [
            .init(ordinal: 1, model: Self.model, candidate: "primary", responseID: nil, usage: .init(),
                  outcome: .failed(.provider(.unavailable, nil)), duration: .zero),
            .init(ordinal: 2, model: Self.model, candidate: "backup", responseID: "response",
                  usage: .init(inputTokens: 8, outputTokens: 1), outcome: .completed(.endTurn), duration: .zero),
        ])
    }
}

private actor AttemptCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private struct AttemptFixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn, .tools])
    let counter = AttemptCounter()
    let produce: @Sendable (ModelRequest, Int, @escaping ModelEventStream.Emit) async throws -> Void

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in try await produce(request, await counter.next(), emit) }
    }
}

private func answer(_ request: ModelRequest, _ text: String, usage: ModelUsage) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    return [.responseStarted(info), .textDelta(text), .usage(usage),
            .responseCompleted(.init(info: info, content: [.text(text)], usage: usage, stopReason: .endTurn))]
}

private func collect(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> [ModelEvent] {
    var events: [ModelEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private func attempts(_ events: [ModelEvent]) -> [ModelRequestAttempt] {
    events.compactMap { if case .requestAttempt(let attempt) = $0 { attempt } else { nil } }
}

private extension ModelRequestAttempt {
    /// The record without its measured time, which a test cannot predict.
    var timeless: ModelRequestAttempt {
        .init(ordinal: ordinal, model: model, candidate: candidate, responseID: responseID, usage: usage,
              outcome: outcome, duration: .zero)
    }
}
