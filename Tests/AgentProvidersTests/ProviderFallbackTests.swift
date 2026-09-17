import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
import Testing

struct ProviderFallbackTests {
    @Test func transientFailureFallsBackOnlyAfterAValidatedCandidateResponse() async throws {
        let firstProbe = RouteProviderProbe()
        let secondProbe = RouteProviderProbe()
        let first = RouteFixtureProvider(probe: firstProbe) { _, _, _ in
            throw ModelProviderError(kind: .unavailable, message: "temporary failure")
        }
        let second = RouteFixtureProvider(probe: secondProbe) { request, _, emit in
            try emitContents(textEvents(request, "backup"), emit: emit)
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [first, second],
                                           policy: .init(maxAttempts: 2))
        let request = ModelRequest(model: .init(provider: "fixture", name: "test"), messages: [.user([.text("Hi")])])

        let events = try await collectRouteEvents(route.stream(request: request))
        #expect(events == textEvents(request, "backup"))
        #expect(await firstProbe.requests.count == 1)
        #expect(await secondProbe.requests.count == 1)
    }

    @Test func partialEventsFromFailedCandidateAreNeverPublishedBeforeFallback() async throws {
        let firstProbe = RouteProviderProbe()
        let secondProbe = RouteProviderProbe()
        let first = RouteFixtureProvider(probe: firstProbe) { request, _, emit in
            let info = ResponseInfo(id: "partial", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("not published"))
            throw ModelProviderError(kind: .transport, message: "connection closed")
        }
        let second = RouteFixtureProvider(probe: secondProbe) { request, _, emit in
            try emitContents(textEvents(request, "validated"), emit: emit)
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [first, second],
                                           policy: .init(maxAttempts: 2))
        let request = ModelRequest(model: .init(provider: "fixture", name: "test"), messages: [.user([.text("Hi")])])

        let events = try await collectRouteEvents(route.stream(request: request))
        #expect(events == textEvents(request, "validated"))
        #expect(!events.contains(.textDelta("not published")))
    }

    @Test func mutationBoundaryBlocksProviderSwitchWithinTheSameRun() async throws {
        let firstProbe = RouteProviderProbe()
        let secondProbe = RouteProviderProbe()
        let call = ToolCall(id: .init(rawValue: "update-1"), name: RouteMutationTool.name,
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        let first = RouteFixtureProvider(probe: firstProbe) { request, turn, emit in
            if turn == 1 {
                try emitContents(toolEvents(request, [call]), emit: emit)
            } else {
                throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
            }
        }
        let second = RouteFixtureProvider(probe: secondProbe) { request, _, emit in
            try emitContents(textEvents(request, "fallback must not run"), emit: emit)
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [first, second],
                                           policy: .init(maxAttempts: 2))
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let agent = try Agent(model: .init(provider: "fixture", name: "test"), provider: route,
                              tools: [try RouteMutationTool()], runTimeout: .seconds(2))
        let session = agent.makeSession(journal: journal)
        let run = try await session.run("Update the listing")

        do {
            _ = try await run.wait()
            Issue.record("A fallback after a mutation boundary must fail")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .fallbackBlocked)
        }
        #expect(await firstProbe.requests.count == 2)
        #expect(await secondProbe.requests.isEmpty)
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func mutationBoundaryIsScopedToTheSessionAndRunIdentity() async throws {
        let firstProbe = RouteProviderProbe()
        let secondProbe = RouteProviderProbe()
        let transient = ModelProviderError(kind: .rateLimited, message: "retry later")
        let first = RouteFixtureProvider(probe: firstProbe) { _, _, _ in throw transient }
        let second = RouteFixtureProvider(probe: secondProbe) { request, _, emit in
            try emitContents(textEvents(request, "independent"), emit: emit)
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [first, second],
                                           policy: .init(maxAttempts: 2))
        let sessionA = UUID(), runA = UUID(), sessionB = UUID(), runB = UUID()
        await route.markMutationBoundary(sessionID: sessionA, runID: runA)

        let requestA = ModelRequest(model: .init(provider: "fixture", name: "test"), messages: [],
                                     sessionID: sessionA, runID: runA)
        await #expect(throws: ModelProviderError.self) {
            for try await _ in route.stream(request: requestA) {}
        }
        #expect(await secondProbe.requests.isEmpty)

        let requestB = ModelRequest(model: .init(provider: "fixture", name: "test"), messages: [],
                                     sessionID: sessionB, runID: runB)
        _ = try await collectRouteEvents(route.stream(request: requestB))
        #expect(await secondProbe.requests.count == 1)
        await route.clearMutationBoundary(sessionID: sessionA, runID: runA)
    }

    @Test func mutationBoundaryPreventsRetryingTheCurrentProvider() async throws {
        let firstProbe = RouteProviderProbe()
        let secondProbe = RouteProviderProbe()
        let first = RouteFixtureProvider(probe: firstProbe) { _, _, _ in
            throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
        }
        let second = RouteFixtureProvider(probe: secondProbe) { request, _, emit in
            try emitContents(textEvents(request, "must not run"), emit: emit)
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [first, second],
            policy: .init(maxAttempts: 3, maxRetriesPerProvider: 2)
        )
        let sessionID = UUID()
        let runID = UUID()
        await route.markMutationBoundary(sessionID: sessionID, runID: runID)

        let request = ModelRequest(
            model: .init(provider: "fixture", name: "test"),
            messages: [],
            sessionID: sessionID,
            runID: runID
        )
        do {
            for try await _ in route.stream(request: request) {}
            Issue.record("A mutation boundary must block both retry and fallback")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .fallbackBlocked)
        }
        #expect(await firstProbe.requests.count == 1)
        #expect(await secondProbe.requests.isEmpty)
    }

    @Test func fallbackPolicyRejectsNonTransientErrorKinds() {
        for kind in [ModelProviderError.Kind.authentication, .permissionDenied, .invalidRequest,
                     .invalidResponse, .fallbackBlocked] {
            do {
                _ = try ModelProviderFallbackPolicy(retryableKinds: [kind])
                Issue.record("Non-transient provider errors must not be retryable: \(kind)")
            } catch {
                #expect((error as? ModelProviderFallbackPolicyError) == .invalidRetryableKinds)
            }
        }
    }

    @Test func cancellationAndNonTransientFailuresNeverFallback() async throws {
        for failure in [
            RouteFailure.cancellation,
            .provider(ModelProviderError(kind: .authentication, message: "invalid credentials")),
        ] {
            let firstProbe = RouteProviderProbe()
            let secondProbe = RouteProviderProbe()
            let first = RouteFixtureProvider(probe: firstProbe) { _, _, _ in
                switch failure {
                case .cancellation: throw CancellationError()
                case .provider(let error): throw error
                }
            }
            let second = RouteFixtureProvider(probe: secondProbe) { request, _, emit in
                try emitContents(textEvents(request, "must not run"), emit: emit)
            }
            let route = try ModelProviderRoute(id: "fixture", candidates: [first, second],
                                               policy: .init(maxAttempts: 2))
            let request = ModelRequest(model: .init(provider: "fixture", name: "test"), messages: [])

            do {
                for try await _ in route.stream(request: request) {}
                Issue.record("Non-retryable failure was treated as success")
            } catch is CancellationError {
                if case .cancellation = failure {} else { Issue.record("Unexpected cancellation") }
            } catch {
                #expect((error as? ModelProviderError)?.kind == .authentication)
            }
            #expect(await secondProbe.requests.isEmpty)
        }
    }
}

private enum RouteFailure {
    case cancellation
    case provider(ModelProviderError)
}

private actor RouteProviderProbe {
    private(set) var requests: [ModelRequest] = []

    func record(_ request: ModelRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

private struct RouteFixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn, .tools])
    let probe: RouteProviderProbe
    let produce: @Sendable (ModelRequest, Int, @escaping ModelEventStream.Emit) async throws -> Void

    init(probe: RouteProviderProbe,
         produce: @escaping @Sendable (ModelRequest, Int, @escaping ModelEventStream.Emit) async throws -> Void) {
        self.probe = probe
        self.produce = produce
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await probe.record(request)
            try await produce(request, turn, emit)
        }
    }
}

private func textEvents(_ request: ModelRequest, _ text: String) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    return [.responseStarted(info), .textDelta(text),
            .responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn))]
}

private func toolEvents(_ request: ModelRequest, _ calls: [ToolCall]) -> [ModelEvent] {
    let info = ResponseInfo(id: "response", model: request.model)
    var events: [ModelEvent] = [.responseStarted(info)]
    for call in calls {
        events.append(.toolCallStarted(call.id, name: call.name))
        events.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
        events.append(.toolCallCompleted(call))
    }
    events.append(.responseCompleted(.init(info: info, toolCalls: calls, stopReason: .toolCalls)))
    return events
}

private func emitContents(_ events: [ModelEvent], emit: @escaping ModelEventStream.Emit) throws {
    for event in events { try emit(event) }
}

private func collectRouteEvents(_ stream: AsyncThrowingStream<ModelEvent, Error>) async throws -> [ModelEvent] {
    var events: [ModelEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private struct RouteMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_listing"
    static let description = "Update a property listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let policy: ToolPolicy

    init() throws {
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(1), authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let receipt = ToolReceipt(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
                                  confirmedTargets: [.init(namespace: "property.listing", id: input.id)], revision: "v2")
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("swift-agent-route-\(UUID().uuidString).log")
}

private func cleanupJournal(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(atPath: url.path + ".lock")
}
