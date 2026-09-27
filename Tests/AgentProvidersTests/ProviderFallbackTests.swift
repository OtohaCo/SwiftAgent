import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
import Testing

struct ProviderFallbackTests {
    @Test func routeDoesNotAdvertiseStreamingWhenItBuffersCandidateResponses() throws {
        let candidate = RouteFixtureProvider(probe: RouteProviderProbe()) { _, _, _ in }

        let route = try ModelProviderRoute(id: "fixture", candidates: [candidate])

        #expect(!route.descriptor.capabilities.contains(.streaming))
        #expect(route.descriptor.capabilities.contains(.multiTurn))
        #expect(route.descriptor.capabilities.contains(.tools))
    }

    @Test func routeRejectsCandidateFromAnotherProviderNamespace() throws {
        let candidate = RouteFixtureProvider(id: "other", probe: RouteProviderProbe()) { _, _, _ in }

        do {
            _ = try ModelProviderRoute(id: "fixture", candidates: [candidate])
            Issue.record("A route must not rewrite requests across provider namespaces")
        } catch {
            #expect(
                error as? ModelProviderFallbackPolicyError
                    == .candidateProviderIDMismatch(routeID: "fixture", candidateID: "other")
            )
        }
    }

    @Test func sameProviderRetryHonorsRetryAfter() async throws {
        let probe = RouteProviderProbe()
        let candidate = RouteFixtureProvider(probe: probe) { request, turn, emit in
            if turn == 1 {
                throw ModelProviderError(
                    kind: .rateLimited,
                    message: "retry later",
                    retryAfter: .milliseconds(120)
                )
            }
            try emitContents(textEvents(request, "retried"), emit: emit)
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [candidate],
            policy: .init(maxAttempts: 2, maxRetriesPerProvider: 1)
        )
        let request = ModelRequest(model: .init(provider: "fixture", name: "test"), messages: [])
        let clock = ContinuousClock()
        let start = clock.now

        let events = try await collectRouteEvents(route.stream(request: request))

        #expect(events == textEvents(request, "retried"))
        #expect(clock.now - start >= .milliseconds(100))
        #expect(await probe.requests.count == 2)
    }

    @Test func cancellingDuringRetryAfterStopsBeforeAnotherAttempt() async throws {
        let probe = RouteProviderProbe()
        let candidate = RouteFixtureProvider(probe: probe) { _, _, _ in
            throw ModelProviderError(
                kind: .rateLimited,
                message: "retry later",
                retryAfter: .seconds(30)
            )
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [candidate],
            policy: .init(maxAttempts: 2, maxRetriesPerProvider: 1)
        )
        let agent = try Agent(model: .init(provider: "fixture", name: "test"), provider: route)
        let run = try await agent.makeSession().run("Hi")
        await probe.waitForRequestCount(1)

        await run.cancel()

        await #expect(throws: CancellationError.self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await probe.requests.count == 1)
    }

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
        let journal = try makeTestJournal(at: url)
        let agent = try Agent(
            model: .init(provider: "fixture", name: "test"),
            provider: route,
            tools: [try RouteMutationTool()],
            configuration: AgentConfiguration(runTimeout: .seconds(2))
        )
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("Update the listing")

        do {
            _ = try await run.wait()
            Issue.record("A fallback after a mutation boundary must fail")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .fallbackBlocked)
        }
        #expect(await firstProbe.requests.count == 2)
        #expect(await secondProbe.requests.isEmpty)
        #expect(try await journal.pendingMutations().isEmpty)
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

    @Test func fallbackProviderReplaysSettledMutationWithoutExecutingAgain() async throws {
        let firstProbe = RouteProviderProbe()
        let secondProbe = RouteProviderProbe()
        let executorProbe = RouteMutationExecutorProbe()
        let primaryCall = ToolCall(
            id: .init(rawValue: "primary-call"),
            name: RouteMutationTool.name,
            argumentsJSON: #"{"id":"listing-1"}"#,
            completeness: .complete
        )
        let fallbackCall = ToolCall(
            id: .init(rawValue: "fallback-call"),
            name: RouteMutationTool.name,
            argumentsJSON: #"{"id":"listing-1"}"#,
            completeness: .complete
        )
        let first = RouteFixtureProvider(probe: firstProbe) { request, turn, emit in
            switch turn {
            case 1: try emitContents(toolEvents(request, [primaryCall]), emit: emit)
            case 2: try emitContents(textEvents(request, "first complete"), emit: emit)
            default: throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
            }
        }
        let second = RouteFixtureProvider(probe: secondProbe) { request, turn, emit in
            if turn == 1 {
                try emitContents(toolEvents(request, [fallbackCall]), emit: emit)
            } else {
                try emitContents(textEvents(request, "retry complete"), emit: emit)
            }
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [first, second],
            policy: .init(maxAttempts: 2)
        )
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try makeTestJournal(at: url)
        let agent = try Agent(
            model: .init(provider: "fixture", name: "test"),
            provider: route,
            tools: [try RouteMutationTool(probe: executorProbe)],
            configuration: AgentConfiguration(runTimeout: .seconds(2))
        )
        let session = try agent.makeSession(journal: journal)

        let firstRun = try await session.run("Update", operationID: "fallback-operation")
        let firstResult = try await firstRun.wait()
        try await firstRun.waitForDrain()
        let retryResult = try await session.run("Retry", operationID: "fallback-operation").wait()

        #expect(await executorProbe.count == 1)
        #expect(firstResult.receipts.first?.callID == primaryCall.id)
        #expect(retryResult.receipts.first?.callID == fallbackCall.id)
        #expect(retryResult.receipts.first?.receipt == firstResult.receipts.first?.receipt)
        #expect(await firstProbe.requests.count == 4)
        #expect(await secondProbe.requests.count == 2)
        #expect(try await journal.pendingMutations().isEmpty)
    }

    @Test func validatedFallbackCandidateStaysPinnedAfterMutationBoundary() async throws {
        let primaryProbe = RouteProviderProbe()
        let fallbackProbe = RouteProviderProbe()
        let executorProbe = RouteMutationExecutorProbe()
        let call = ToolCall(
            id: .init(rawValue: "fallback-mutation"),
            name: RouteMutationTool.name,
            argumentsJSON: #"{"id":"listing-1"}"#,
            completeness: .complete
        )
        let primary = RouteFixtureProvider(probe: primaryProbe) { request, turn, emit in
            if turn == 1 {
                throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
            }
            try emitContents(textEvents(request, "primary recovered"), emit: emit)
        }
        let fallback = RouteFixtureProvider(probe: fallbackProbe) { request, turn, emit in
            if turn == 1 {
                try emitContents(toolEvents(request, [call]), emit: emit)
                return
            }
            let toolResult = request.messages.compactMap { message -> ToolResultMessage? in
                if case .tool(let value) = message { return value }
                return nil
            }.last
            #expect(toolResult?.callID == call.id)
            try emitContents(textEvents(request, "fallback complete"), emit: emit)
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [primary, fallback],
            policy: .init(maxAttempts: 2)
        )
        let journalURL = temporaryJournalURL()
        defer { cleanupJournal(journalURL) }
        let journal = try makeTestJournal(at: journalURL)
        let agent = try Agent(
            model: .init(provider: "fixture", name: "test"),
            provider: route,
            tools: [try RouteMutationTool(probe: executorProbe)],
            configuration: AgentConfiguration(runTimeout: .seconds(2))
        )
        let session = try agent.makeSession(journal: journal)

        let result = try await session.run("Update", operationID: "pinned-operation").wait()

        #expect(result.outcome == .completed)
        #expect(result.receipts.count == 1)
        #expect(result.receipts.first?.callID == call.id)
        #expect(await executorProbe.count == 1)
        #expect(await primaryProbe.requests.count == 1)
        #expect(await fallbackProbe.requests.count == 2)
        #expect(try await journal.pendingMutations().isEmpty)
    }

    @Test func clearingMutationBoundaryReleasesPinnedCandidate() async throws {
        let primaryProbe = RouteProviderProbe()
        let fallbackProbe = RouteProviderProbe()
        let primary = RouteFixtureProvider(probe: primaryProbe) { request, turn, emit in
            if turn == 1 {
                throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
            }
            try emitContents(textEvents(request, "primary recovered"), emit: emit)
        }
        let fallback = RouteFixtureProvider(probe: fallbackProbe) { request, _, emit in
            try emitContents(textEvents(request, "fallback"), emit: emit)
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [primary, fallback],
            policy: .init(maxAttempts: 2)
        )
        let sessionID = UUID()
        let runID = UUID()
        let request = ModelRequest(
            model: .init(provider: "fixture", name: "test"),
            messages: [],
            sessionID: sessionID,
            runID: runID
        )

        _ = try await collectRouteEvents(route.stream(request: request))
        #expect(await primaryProbe.requests.count == 1)
        #expect(await fallbackProbe.requests.count == 1)

        await route.markMutationBoundary(sessionID: sessionID, runID: runID)
        _ = try await collectRouteEvents(route.stream(request: request))
        #expect(await primaryProbe.requests.count == 1)
        #expect(await fallbackProbe.requests.count == 2)

        await route.clearMutationBoundary(sessionID: sessionID, runID: runID)
        _ = try await collectRouteEvents(route.stream(request: request))
        #expect(await primaryProbe.requests.count == 2)
        #expect(await fallbackProbe.requests.count == 2)
    }

    @Test func validatedCandidateFinishingAfterClearCannotRestorePinnedState() async throws {
        let primaryProbe = RouteProviderProbe()
        let fallbackProbe = RouteProviderProbe()
        let fallbackEntered = RouteGate()
        let releaseFallback = RouteGate()
        let primary = RouteFixtureProvider(probe: primaryProbe) { request, turn, emit in
            if turn == 1 {
                throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
            }
            try emitContents(textEvents(request, "primary after clear"), emit: emit)
        }
        let fallback = RouteFixtureProvider(probe: fallbackProbe) { request, _, emit in
            await fallbackEntered.open()
            await releaseFallback.wait()
            try emitContents(textEvents(request, "late fallback"), emit: emit)
        }
        let route = try ModelProviderRoute(
            id: "fixture",
            candidates: [primary, fallback],
            policy: .init(maxAttempts: 2)
        )
        let sessionID = UUID()
        let runID = UUID()
        let request = ModelRequest(
            model: .init(provider: "fixture", name: "test"),
            messages: [],
            sessionID: sessionID,
            runID: runID
        )

        let lateRequest = Task { try await collectRouteEvents(route.stream(request: request)) }
        await fallbackEntered.wait()
        await route.clearMutationBoundary(sessionID: sessionID, runID: runID)
        await releaseFallback.open()
        _ = try await lateRequest.value

        await route.markMutationBoundary(sessionID: sessionID, runID: runID)
        let events = try await collectRouteEvents(route.stream(request: request))

        #expect(events == textEvents(request, "primary after clear"))
        #expect(await primaryProbe.requests.count == 2)
        #expect(await fallbackProbe.requests.count == 1)
    }

    @Test func mutationBoundaryPropagatesThroughNestedRoutes() async throws {
        let primaryProbe = RouteProviderProbe()
        let fallbackProbe = RouteProviderProbe()
        let primary = RouteFixtureProvider(probe: primaryProbe) { _, _, _ in
            throw ModelProviderError(kind: .unavailable, message: "primary unavailable")
        }
        let fallback = RouteFixtureProvider(probe: fallbackProbe) { request, _, emit in
            try emitContents(textEvents(request, "fallback"), emit: emit)
        }
        let inner = try ModelProviderRoute(
            id: "fixture",
            candidates: [primary, fallback],
            policy: .init(maxAttempts: 2)
        )
        let outer = try ModelProviderRoute(
            id: "fixture",
            candidates: [inner],
            policy: .init(maxAttempts: 1)
        )
        let sessionID = UUID()
        let runID = UUID()
        let request = ModelRequest(
            model: .init(provider: "fixture", name: "test"),
            messages: [],
            sessionID: sessionID,
            runID: runID
        )

        _ = try await collectRouteEvents(outer.stream(request: request))
        #expect(await primaryProbe.requests.count == 1)
        #expect(await fallbackProbe.requests.count == 1)

        await outer.markMutationBoundary(sessionID: sessionID, runID: runID)
        _ = try await collectRouteEvents(outer.stream(request: request))
        #expect(await primaryProbe.requests.count == 1)
        #expect(await fallbackProbe.requests.count == 2)
    }

    @Test func recoverableReadOnlyFailureContinuesOnTheCurrentProviderRoute() async throws {
        let primaryProbe = RouteProviderProbe()
        let fallbackProbe = RouteProviderProbe()
        let call = ToolCall(id: .init(rawValue: "missing-resource"), name: RouteRecoverableTool.name,
                            argumentsJSON: "{}", completeness: .complete)
        let primary = RouteFixtureProvider(probe: primaryProbe) { request, turn, emit in
            if turn == 1 {
                try emitContents(toolEvents(request, [call]), emit: emit)
                return
            }
            let result = request.messages.compactMap { message -> ToolResultMessage? in
                if case .tool(let value) = message { return value }
                return nil
            }.last
            #expect(result?.callID == call.id)
            #expect(result?.isError == true)
            try emitContents(textEvents(request, "Try another source"), emit: emit)
        }
        let fallback = RouteFixtureProvider(probe: fallbackProbe) { request, _, emit in
            try emitContents(textEvents(request, "must not run"), emit: emit)
        }
        let route = try ModelProviderRoute(id: "fixture", candidates: [primary, fallback],
                                           policy: .init(maxAttempts: 2))
        let agent = try Agent(model: .init(provider: "fixture", name: "test"), provider: route,
                              tools: [try RouteRecoverableTool()])

        let result = try await agent.makeSession().run("Find it").wait()

        #expect(result.outcome == .completed)
        #expect(await primaryProbe.requests.count == 2)
        #expect(await fallbackProbe.requests.isEmpty)
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
    private struct Waiter {
        let requestCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var requests: [ModelRequest] = []
    private var waiters: [Waiter] = []

    func record(_ request: ModelRequest) -> Int {
        requests.append(request)
        let ready = waiters.filter { $0.requestCount <= requests.count }
        waiters.removeAll { $0.requestCount <= requests.count }
        for waiter in ready { waiter.continuation.resume() }
        return requests.count
    }

    func waitForRequestCount(_ requestCount: Int) async {
        guard requests.count < requestCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(requestCount: requestCount, continuation: continuation))
        }
    }
}

private actor RouteGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor RouteMutationExecutorProbe {
    private(set) var count = 0

    func record() { count += 1 }
}

private struct RouteFixtureProvider: ModelProvider {
    let descriptor: ModelProviderDescriptor
    let probe: RouteProviderProbe
    let produce: @Sendable (ModelRequest, Int, @escaping ModelEventStream.Emit) async throws -> Void

    init(id: String = "fixture",
         probe: RouteProviderProbe,
         produce: @escaping @Sendable (ModelRequest, Int, @escaping ModelEventStream.Emit) async throws -> Void) {
        descriptor = ModelProviderDescriptor(id: id, capabilities: [.streaming, .multiTurn, .tools])
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

private struct RouteRecoverableTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String

    static let name = "route_recoverable"
    static let description = "Return a model-visible read failure"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy

    init() throws {
        policy = try .readOnly(authorization: .notRequired, recoverableErrors: .modelVisible)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        throw try RecoverableToolError(code: "not_found", message: "No result was found.")
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
    let probe: RouteMutationExecutorProbe?
    let policy: ToolPolicy

    init(probe: RouteMutationExecutorProbe? = nil) throws {
        self.probe = probe
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
        await probe?.record()
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
