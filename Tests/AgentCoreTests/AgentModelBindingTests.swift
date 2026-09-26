import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AgentModelBindingTests {
    @Test func sameSessionCanSelectAnImmutableBindingForTheNextRun() async throws {
        let defaultProvider = ScriptedProvider { request, _ in textResponse(request, "default") }
        let alternateProvider = ScriptedProvider { request, _ in textResponse(request, "alternate") }
        let session = try Agent(model: fixtureModel, provider: defaultProvider).makeSession()

        let first = try await session.run("first")
        _ = try await first.wait()

        let alternateModel = ModelID(provider: "fixture", name: "alternate")
        let binding = try AgentModelBinding(
            profileID: "alternate",
            profileRevision: "1",
            model: alternateModel,
            provider: alternateProvider,
            deployment: deployment("alternate")
        )
        let second = try await session.run("second", using: binding)
        let result = try await second.wait()

        #expect(second.binding.profileID == "alternate")
        #expect(result.response.info.model == alternateModel)
        let requests = await alternateProvider.log.requests
        #expect(requests.count == 1)
        #expect(requests[0].model == alternateModel)
        #expect(requests[0].messages == [
            .user([.text("first")]),
            .assistant(content: [.text("default")], toolCalls: []),
            .user([.text("second")]),
        ])
    }

    @Test func localPreflightFailureDoesNotAppendInputOrJournalState() async throws {
        let provider = ScriptedProvider(
            descriptor: .init(id: "fixture", capabilities: [.streaming]),
            respond: { request, _ in textResponse(request, "unused") }
        )
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(
            profileID: "no-multiturn",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("limited")
        )

        let first = try await session.run("first")
        _ = try await first.wait()
        let before = try await session.conversationSnapshot()
        await #expect(throws: AgentLoopError.unsupportedCapabilities(.multiTurn)) {
            try await session.run("must not append", using: binding, expectedConversationRevision: before.revision)
        }
        #expect(await session.history == before.messages)
        #expect(await session.activeRunID == nil)
    }

    @Test func projectionChangesTheRequestWithoutReplacingCanonicalHistory() async throws {
        let defaultProvider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let provider = ScriptedProvider { request, _ in
            #expect(request.messages == [.developer("Projected context"), .user([.text("second")])])
            return textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: defaultProvider).makeSession()
        let first = try await session.run("first")
        _ = try await first.wait()
        let binding = try AgentModelBinding(
            profileID: "projection",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("projection"),
            projector: FixedProjector(messages: [.developer("Projected context"), .user([.text("second")])])
        )

        let second = try await session.run("second", using: binding)
        _ = try await second.wait()

        #expect(await session.history == [
            .user([.text("first")]),
            .assistant(content: [.text("done")], toolCalls: []),
            .user([.text("second")]),
            .assistant(content: [.text("done")], toolCalls: []),
        ])
    }

    @Test func staleConversationRevisionIsRejectedBeforeHistoryChanges() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let snapshot = try await session.conversationSnapshot()
        let first = try await session.run("first")
        _ = try await first.wait()
        let binding = try AgentModelBinding(
            profileID: "default",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("default")
        )

        await #expect(throws: AgentModelBindingError.staleConversationRevision) {
            try await session.run("stale", using: binding, expectedConversationRevision: snapshot.revision)
        }
        #expect(await session.history.last == .assistant(content: [.text("done")], toolCalls: []))
    }

    @Test func opaqueContinuationCannotCrossDeploymentWithoutExplicitHandoff() async throws {
        let continuation = ModelProviderContinuation(
            model: fixtureModel,
            format: "fixture.opaque.v1",
            payload: Data([1, 2, 3])
        )
        let sourceProvider = ScriptedProvider { request, _ in
            let info = ResponseInfo(id: "opaque", model: request.model)
            return [
                .responseStarted(info),
                .textDelta("source"),
                .providerContinuation(continuation),
                .responseCompleted(.init(
                    info: info,
                    content: [.text("source"), .providerContinuation(continuation)],
                    stopReason: .endTurn
                )),
            ]
        }
        let targetProvider = ScriptedProvider { request, _ in textResponse(request, "target") }
        let session = try Agent(model: fixtureModel, provider: sourceProvider).makeSession()
        let source = try AgentModelBinding(
            profileID: "source",
            profileRevision: "1",
            model: fixtureModel,
            provider: sourceProvider,
            deployment: deployment("source")
        )
        let first = try await session.run("first", using: source)
        _ = try await first.wait()
        let target = try AgentModelBinding(
            profileID: "target",
            profileRevision: "1",
            model: fixtureModel,
            provider: targetProvider,
            deployment: deployment("target")
        )

        await #expect(throws: AgentModelBindingError.incompatibleContinuation) {
            try await session.run("strict", using: target)
        }
        let handoff = try AgentModelBinding(
            profileID: "target-handoff",
            profileRevision: "1",
            model: fixtureModel,
            provider: targetProvider,
            deployment: deployment("target"),
            projector: AgentSemanticHandoffProjector()
        )
        let second = try await session.run("handoff", using: handoff)
        _ = try await second.wait()
        let targetRequest = try #require(await targetProvider.log.requests.first)
        #expect(targetRequest.messages.contains { message in
            guard case .assistant(let content, _) = message else { return false }
            return content.contains { if case .providerContinuation = $0 { true } else { false } }
        } == false)
    }

    @Test func switchingBackToTheOriginalBindingRestoresOnlyItsScopedContinuation() async throws {
        let continuation = ModelProviderContinuation(
            model: fixtureModel,
            format: "fixture.opaque.v1",
            payload: Data([4, 2])
        )
        let providerA = ScriptedProvider { request, turn in
            if turn == 1 {
                let info = ResponseInfo(id: "a-1", model: request.model)
                return [
                    .responseStarted(info),
                    .textDelta("A1"),
                    .providerContinuation(continuation),
                    .responseCompleted(.init(
                        info: info,
                        content: [.text("A1"), .providerContinuation(continuation)],
                        stopReason: .endTurn
                    )),
                ]
            }
            return textResponse(request, "A2")
        }
        let providerB = ScriptedProvider { request, _ in
            #expect(request.messages.contains { message in
                guard case .assistant(let content, _) = message else { return false }
                return content.contains { if case .providerContinuation = $0 { true } else { false } }
            } == false)
            return textResponse(request, "B1")
        }
        let session = try Agent(model: fixtureModel, provider: providerA).makeSession()
        let a = try AgentModelBinding(
            profileID: "a",
            profileRevision: "1",
            model: fixtureModel,
            provider: providerA,
            deployment: deployment("a")
        )
        let b = try AgentModelBinding(
            profileID: "b",
            profileRevision: "1",
            model: fixtureModel,
            provider: providerB,
            deployment: deployment("b"),
            projector: AgentSemanticHandoffProjector()
        )

        _ = try await session.run("first", using: a).wait()
        _ = try await session.run("second", using: b).wait()
        _ = try await session.run("third", using: a).wait()

        let finalRequest = try #require(await providerA.log.requests.last)
        #expect(finalRequest.messages.contains { message in
            guard case .assistant(let content, _) = message else { return false }
            return content.contains { part in
                guard case .providerContinuation(let state) = part else { return false }
                return state.origin?.serviceInstanceID == "a"
            }
        })
    }

    @Test func scopedContinuationSurvivesDurableRestartForTheSameBinding() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-binding-restart-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let sessionID = UUID()
        let continuation = ModelProviderContinuation(
            model: fixtureModel,
            format: "fixture.opaque.v1",
            payload: Data([7, 2])
        )
        let provider = ScriptedProvider { request, turn in
            if turn == 1 {
                let info = ResponseInfo(id: "restart-1", model: request.model)
                return [
                    .responseStarted(info),
                    .textDelta("first"),
                    .providerContinuation(continuation),
                    .responseCompleted(.init(
                        info: info,
                        content: [.text("first"), .providerContinuation(continuation)],
                        stopReason: .endTurn
                    )),
                ]
            }
            let restored = request.messages.compactMap { message -> ModelProviderContinuation? in
                guard case .assistant(let content, _) = message else { return nil }
                return content.compactMap { part in
                    guard case .providerContinuation(let value) = part else { return nil }
                    return value
                }.first
            }.first
            #expect(restored?.origin?.serviceInstanceID == "durable")
            #expect(restored?.origin?.configurationRevision == "7")
            return textResponse(request, "second")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let binding = try AgentModelBinding(
            profileID: "durable",
            profileRevision: "7",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("durable")
        )

        let firstJournal = try makeTestJournal(at: url)
        let firstSession = try agent.makeSession(
            id: sessionID,
            journal: firstJournal
        )
        let first = try await firstSession.run("first", using: binding)
        _ = try await first.wait()
        try await first.waitForDrain()
        try await firstJournal.close()

        let restoredSession = try agent.makeSession(
            id: sessionID,
            journal: openTestJournal(at: url)
        )
        let second = try await restoredSession.run("second", using: binding)
        #expect(try await second.wait().outcome == .completed)
        try await second.waitForDrain()
    }

    @Test func resolvedReadOnlyFailureProjectionReplacesOnlyACompleteClosedGroup() async throws {
        let failed = ToolCall(
            id: .init(rawValue: "failed"),
            name: "lookup",
            argumentsJSON: #"{"query":"too broad"}"#,
            completeness: .complete
        )
        let resolved = ToolCall(
            id: .init(rawValue: "resolved"),
            name: "lookup",
            argumentsJSON: #"{"query":"specific"}"#,
            completeness: .complete
        )
        let canonical: [ModelMessage] = [
            .user([.text("Find it")]),
            .assistant(content: [], toolCalls: [failed]),
            .tool(.init(callID: failed.id, content: [.text(String(repeating: "broad ", count: 50))], isError: true)),
            .assistant(content: [], toolCalls: [resolved]),
            .tool(.init(callID: resolved.id, content: [.json(.object(["value": .string("found")]))], isError: false)),
            .assistant(content: [.text("Found it")], toolCalls: []),
        ]
        let projector = AgentResolvedReadOnlyToolProjector(spans: [
            .init(failedCallID: failed.id, resolvedByCallID: resolved.id, summary: "The broad query failed; use the specific query."),
        ])
        let projection = try await projector.project(.init(
            canonicalMessages: canonical,
            model: fixtureModel,
            sessionID: UUID(),
            runID: UUID(),
            conversationRevision: 7,
            contextEpoch: 3,
            modelTurn: 1
        ))

        #expect(projection.messages == [
            .user([.text("Find it")]),
            .user([.text("Host context summary for a resolved read-only tool: The broad query failed; use the specific query.")]),
            .assistant(content: [], toolCalls: [resolved]),
            .tool(.init(callID: resolved.id, content: [.json(.object(["value": .string("found")]))], isError: false)),
            .assistant(content: [.text("Found it")], toolCalls: []),
        ])
        #expect(canonical[1] == .assistant(content: [], toolCalls: [failed]))
    }

    @Test func tokenBudgetRejectsOverflowBeforeARequestCanStart() {
        #expect(throws: AgentModelBindingError.invalidTokenBudget) {
            try AgentContextTokenBudget(
                maximumContextTokens: Int.max,
                reservedOutputTokens: Int.max,
                reservedReasoningTokens: 1,
                estimator: FixedTokenEstimator(inputTokens: 0)
            )
        }
    }

    @Test func tokenBudgetIncludesMessagesToolsAndStructuredOutputAndRejectsNegativeEstimates() async throws {
        let estimator = RecordingTokenEstimator(inputTokens: -1)
        let budget = try AgentContextTokenBudget(
            maximumContextTokens: 100,
            reservedOutputTokens: 10,
            reservedReasoningTokens: 5,
            reservedProtocolTokens: 2,
            estimator: estimator
        )
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let tool = try AddTool(log: EffectLog())
        let configuration = AgentConfiguration(structuredOutput: .init(
            name: "answer",
            description: "A structured answer",
            schema: .object(["type": .string("string")]),
            strict: true
        ))
        let session = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: configuration
        ).makeSession()
        let binding = try AgentModelBinding(
            profileID: "budget",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("budget"),
            tokenBudget: budget
        )

        await #expect(throws: AgentModelBindingError.invalidTokenEstimate) {
            try await session.run("measure me", using: binding)
        }
        let input = try #require(await estimator.inputs.first)
        #expect(input.messages.last == .user([.text("measure me")]))
        #expect(input.tools.map(\.name) == ["add"])
        #expect(input.structuredOutput?.name == "answer")
        #expect(await session.history.contains(.user([.text("measure me")])) == false)
    }

    @Test func tokenBudgetRejectsAnOversizedProjectedRequestBeforeHistoryChanges() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let budget = try AgentContextTokenBudget(
            maximumContextTokens: 100,
            reservedOutputTokens: 20,
            reservedReasoningTokens: 10,
            reservedProtocolTokens: 5,
            estimator: FixedTokenEstimator(inputTokens: 66)
        )
        let binding = try AgentModelBinding(
            profileID: "budget",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("budget"),
            tokenBudget: budget
        )

        await #expect(throws: AgentModelBindingError.contextBudgetExceeded(
            estimatedInputTokens: 66,
            availableInputTokens: 65
        )) {
            try await session.run("must not append", using: binding)
        }
        #expect(await session.history.contains(.user([.text("must not append")])) == false)
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func preflightReservationRejectsOverlapAndCancellationReleasesIdentity() async throws {
        let gate = CancellableProjectionGate()
        let startupReleased = AsyncSignal()
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(
            startupReleaseDidFinish: { _ in await startupReleased.signal() }
        )
        let blocked = try AgentModelBinding(
            profileID: "blocked",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("blocked"),
            projector: BlockingProjector(gate: gate)
        )

        let first = Task { try await session.run("first", using: blocked) }
        await gate.waitUntilBlocked()
        await #expect(throws: AgentSessionError.runInProgress) {
            try await session.run("overlap")
        }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await startupReleased.wait()

        #expect(await session.activeRunID == nil)
        #expect(await session.history.contains(.user([.text("first")])) == false)
        let next = try await session.run("next")
        _ = try await next.wait()
    }

    @Test func cancellationAfterNonCooperativePreflightDoesNotCommitUserInput() async throws {
        let gate = NonCooperativeProjectionGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(
            profileID: "non-cooperative",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("non-cooperative"),
            projector: NonCooperativeBlockingProjector(gate: gate)
        )

        let task = Task { try await session.run("must not commit", using: binding) }
        await gate.waitUntilBlocked()
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await session.history.contains(.user([.text("must not commit")])) == false)
        #expect(await session.activeRunID == nil)
    }

    @Test func projectorExceedingRunDeadlineDoesNotCommitInput() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-preflight-projector-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let gate = NonCooperativeProjectionGate()
        let startupReleased = AsyncSignal()
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(
            journal: journal,
            startupReleaseDidFinish: { _ in await startupReleased.signal() }
        )
        let binding = try AgentModelBinding(
            profileID: "deadline-projector",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("deadline-projector"),
            projector: NonCooperativeBlockingProjector(gate: gate)
        )
        let budget = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0,
                                     deadline: .now.advanced(by: .milliseconds(100)))

        let first = Task { try await session.run("must not commit", using: binding, budget: budget) }
        await gate.waitUntilBlocked()
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: AgentSessionError.runInProgress) {
            try await session.run("overlap")
        }

        await gate.release()
        await gate.waitUntilFinished()
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await first.value }
        await startupReleased.wait()
        #expect(await session.history == [])
        #expect(await session.activeRunID == nil)
        #expect(await provider.log.requests.isEmpty)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)

        let next = try await session.run("next")
        _ = try await next.wait()
    }

    @Test func tokenEstimatorExceedingRunDeadlineDoesNotCommitInput() async throws {
        let gate = NonCooperativeEstimatorGate()
        let startupReleased = AsyncSignal()
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(
            startupReleaseDidFinish: { _ in await startupReleased.signal() }
        )
        let tokenBudget = try AgentContextTokenBudget(
            maximumContextTokens: 100,
            reservedOutputTokens: 10,
            estimator: NonCooperativeTokenEstimator(gate: gate)
        )
        let binding = try AgentModelBinding(
            profileID: "deadline-estimator",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("deadline-estimator"),
            tokenBudget: tokenBudget
        )
        let budget = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0,
                                     deadline: .now.advanced(by: .milliseconds(100)))

        let first = Task { try await session.run("must not commit", using: binding, budget: budget) }
        await gate.waitUntilBlocked()
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: AgentSessionError.runInProgress) {
            try await session.run("overlap")
        }

        await gate.release()
        await gate.waitUntilFinished()
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await first.value }
        await startupReleased.wait()
        #expect(await session.history == [])
        #expect(await session.activeRunID == nil)
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func latePreflightResultCannotCommitAfterDeadline() async throws {
        let gate = NonCooperativeProjectionGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(
            profileID: "late-preflight",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("late-preflight"),
            projector: NonCooperativeBlockingProjector(gate: gate)
        )
        let budget = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0,
                                     deadline: .now.advanced(by: .milliseconds(100)))

        let first = Task { try await session.run("late result", using: binding, budget: budget) }
        await gate.waitUntilBlocked()
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await first.value }

        await gate.release()
        await gate.waitUntilFinished()
        #expect(await session.history == [])
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func latePreflightRetainsCleanupUntilTheSessionIdentityCanBeReused() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-preflight-late-release-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let sessionID = UUID()
        let gate = NonCooperativeProjectionGate()
        let startupReleased = AsyncSignal()
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let first: Task<AgentRun, Error>
        do {
            let session = try Agent(model: fixtureModel, provider: provider).makeSession(
                id: sessionID,
                journal: journal,
                startupReleaseDidFinish: { _ in await startupReleased.signal() }
            )
            let binding = try AgentModelBinding(
                profileID: "late-release",
                profileRevision: "1",
                model: fixtureModel,
                provider: provider,
                deployment: deployment("late-release"),
                projector: NonCooperativeBlockingProjector(gate: gate)
            )
            let budget = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0,
                                         deadline: .now.advanced(by: .milliseconds(100)))
            first = Task { try await session.run("must not commit", using: binding, budget: budget) }
        }

        await gate.waitUntilBlocked()
        try await Task.sleep(for: .milliseconds(150))
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await first.value }

        await gate.release()
        await gate.waitUntilFinished()
        await startupReleased.wait()

        let replacement = try Agent(model: fixtureModel, provider: provider).makeSession(
            id: sessionID,
            journal: journal
        )
        let next = try await replacement.run("next")
        _ = try await next.wait()
    }

    @Test func cancelledPreflightRemainsCancellationWithDeadlineWrapper() async throws {
        let gate = CancellableProjectionGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(
            profileID: "cancelled-preflight",
            profileRevision: "1",
            model: fixtureModel,
            provider: provider,
            deployment: deployment("cancelled-preflight"),
            projector: BlockingProjector(gate: gate)
        )
        let budget = try AgentBudget(maxModelTurns: 1, maxToolCalls: 0,
                                     deadline: .now.advanced(by: .seconds(5)))
        let first = Task { try await session.run("cancel me", using: binding, budget: budget) }
        await gate.waitUntilBlocked()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await session.history == [])
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func duplicateToolCallIDsAreRejectedBeforeProviderExecution() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let duplicateID = ToolCallID(rawValue: "duplicate")
        let messages: [ModelMessage] = [
            .assistant(content: [], toolCalls: [
                ToolCall(id: duplicateID, name: "first", argumentsJSON: "{}", completeness: .complete),
                ToolCall(id: duplicateID, name: "second", argumentsJSON: "{}", completeness: .complete),
            ]),
        ]

        await #expect(throws: AgentModelBindingError.invalidProjection) {
            _ = try await loop.preflight(
                messages: messages,
                sessionID: UUID(),
                runID: UUID(),
                conversationRevision: 1,
                structuredOutput: nil
            )
        }
    }

    @Test func replacementRunWaitsForTheCapturedProviderToPhysicallyDrain() async throws {
        let drain = ProviderDrainGate()
        let replacementWait = AsyncSignal()
        let firstProvider = DrainingScriptedProvider(gate: drain)
        let secondProvider = ScriptedProvider { request, _ in textResponse(request, "second") }
        let session = try Agent(model: fixtureModel, provider: firstProvider).makeSession(
            drainWaitDidBegin: { _ in Task { await replacementWait.signal() } }
        )
        let firstBinding = try AgentModelBinding(
            profileID: "first",
            profileRevision: "1",
            model: fixtureModel,
            provider: firstProvider,
            deployment: deployment("first")
        )
        let secondBinding = try AgentModelBinding(
            profileID: "second",
            profileRevision: "1",
            model: fixtureModel,
            provider: secondProvider,
            deployment: deployment("second")
        )

        let first = try await session.run("first", using: firstBinding)
        _ = try await first.wait()
        await drain.waitUntilDrainBegins()
        let replacement = Task { try await session.run("second", using: secondBinding) }
        await replacementWait.wait()
        #expect(await secondProvider.log.requests.isEmpty)

        await drain.release()
        let second = try await replacement.value
        _ = try await second.wait()
        #expect(await secondProvider.log.requests.count == 1)
    }

    @Test func pendingDrainIsBoundedByTheNextRunDeadline() async throws {
        let drain = ProviderDrainGate()
        let provider = DrainingScriptedProvider(gate: drain)
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()

        let first = try await session.run("first")
        #expect(try await first.wait().outcome == .completed)
        await drain.waitUntilDrainBegins()

        let budget = try AgentBudget(
            maxModelTurns: 1,
            maxToolCalls: 0,
            deadline: .now.advanced(by: .milliseconds(100))
        )
        await #expect(throws: AgentLoopError.deadlineExceeded) {
            _ = try await session.run("deadline", budget: budget)
        }

        await drain.release()
        try await first.waitForDrain()
        let next = try await session.run("after drain")
        #expect(try await next.wait().outcome == .completed)
    }

    @Test func expiredRunBudgetDoesNotCommitInput() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-admission-deadline-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let sessionID = UUID()
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(
            id: sessionID,
            journal: journal
        )
        let budget = try AgentBudget(
            maxModelTurns: 1,
            maxToolCalls: 0,
            deadline: .now.advanced(by: .milliseconds(-1))
        )
        await #expect(throws: AgentLoopError.deadlineExceeded) {
            _ = try await session.run("blocked before admission", budget: budget)
        }
        #expect(await session.history.isEmpty)
        #expect(await session.activeRunID == nil)
        #expect(await provider.log.requests.isEmpty)

        let next = try await session.run("after admission wait")
        #expect(try await next.wait().outcome == .completed)
    }

    @Test func expiredMemoryStartupAdmissionDoesNotPublishAFrame() async throws {
        let journal = AgentJournal()
        var didThrowDeadline = false
        do {
            try await journal.appendStartupCheckpoint(
                [.userMessage("expired before memory admission")],
                sessionID: UUID(),
                runID: UUID(),
                deadline: .now.advanced(by: .milliseconds(-1)),
                durability: .memory
            )
        } catch AgentJournalStartupAdmissionError.deadlineExceeded {
            didThrowDeadline = true
        } catch {
            Issue.record("unexpected startup admission error: \(error)")
        }
        #expect(didThrowDeadline)
        #expect(try await journal.latestCheckpoint(sessionID: UUID())?.history == nil)
    }

    @Test func admittedStartupCheckpointSurvivesFailureBeforeFirstLoopCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-admitted-checkpoint-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let sessionID = UUID()
        let journal = try makeTestJournal(at: url)
        let failure = ModelProviderError(kind: .rateLimited, message: "fixture failure")
        let failing = ScriptedProvider { _, _ in throw failure }
        let firstSession = try Agent(model: fixtureModel, provider: failing).makeSession(
            id: sessionID,
            journal: journal
        )

        let run = try await firstSession.run("recover after provider failure")
        await #expect(throws: ModelProviderError.self) { try await run.wait() }
        try await run.waitForDrain()
        try await journal.close()

        let restartedJournal = try openTestJournal(at: url)
        let restarted = try Agent(model: fixtureModel, provider: failing).makeSession(
            id: sessionID,
            journal: restartedJournal
        )
        let snapshot = try await restarted.conversationSnapshot()
        #expect(snapshot.messages == [.user([.text("recover after provider failure")])])
    }
}

private struct FixedProjector: AgentContextProjector {
    let messages: [ModelMessage]

    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        .init(
            messages: messages,
            plan: .init(
                projectionID: "fixed",
                version: "1",
                sourceRevision: input.conversationRevision,
                sourceDigest: try AgentContextProjectionSource.digest(messages: input.canonicalMessages),
                contextEpoch: input.contextEpoch,
                lossy: true,
                reason: "fixture"
            )
        )
    }
}

private struct FixedTokenEstimator: AgentContextTokenEstimator {
    let inputTokens: Int

    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        .init(inputTokens: inputTokens, accuracy: .exact)
    }
}

private actor RecordingTokenEstimator: AgentContextTokenEstimator {
    let inputTokens: Int
    private(set) var inputs: [AgentContextTokenEstimationInput] = []

    init(inputTokens: Int) {
        self.inputTokens = inputTokens
    }

    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        inputs.append(input)
        return .init(inputTokens: inputTokens, accuracy: .estimated)
    }
}

private struct BlockingProjector: AgentContextProjector {
    let gate: CancellableProjectionGate

    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        try await gate.wait()
        return try await AgentIdentityContextProjector().project(input)
    }
}

private struct NonCooperativeBlockingProjector: AgentContextProjector {
    let gate: NonCooperativeProjectionGate

    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        await gate.wait()
        let projection = try await AgentIdentityContextProjector().project(input)
        await gate.finished()
        return projection
    }
}

private actor NonCooperativeProjectionGate {
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didFinish = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
            let observers = blockedObservers
            blockedObservers.removeAll()
            observers.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked() async {
        if !blockedWaiters.isEmpty { return }
        await withCheckedContinuation { blockedObservers.append($0) }
    }

    func release() {
        released = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func finished() {
        didFinish = true
        let waiters = finishedWaiters
        finishedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        if didFinish { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }
}

private struct NonCooperativeTokenEstimator: AgentContextTokenEstimator {
    let gate: NonCooperativeEstimatorGate

    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        await gate.wait()
        await gate.finished()
        return .init(inputTokens: 1, accuracy: .exact)
    }
}

private actor NonCooperativeEstimatorGate {
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []
    private var finishedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didFinish = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
            let observers = blockedObservers
            blockedObservers.removeAll()
            observers.forEach { $0.resume() }
        }
    }

    func waitUntilBlocked() async {
        if !blockedWaiters.isEmpty { return }
        await withCheckedContinuation { blockedObservers.append($0) }
    }

    func release() {
        released = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func finished() {
        didFinish = true
        let waiters = finishedWaiters
        finishedWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        if didFinish { return }
        await withCheckedContinuation { finishedWaiters.append($0) }
    }
}

private actor CancellableProjectionGate {
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var blockedObservers: [CheckedContinuation<Void, Never>] = []

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    let observers = blockedObservers
                    blockedObservers.removeAll()
                    observers.forEach { $0.resume() }
                }
            }
        }, onCancel: {
            Task { await self.cancel(id) }
        })
    }

    func waitUntilBlocked() async {
        if !waiters.isEmpty { return }
        await withCheckedContinuation { blockedObservers.append($0) }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private struct DrainingScriptedProvider: ModelProvider, ModelProviderRunDrain {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn])
    let gate: ProviderDrainGate

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            for event in textResponse(request, "first") { try emit(event) }
        }
    }

    func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        await gate.wait()
    }
}

private actor ProviderDrainGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var draining = false

    func wait() async {
        draining = true
        let current = observers
        observers.removeAll()
        current.forEach { $0.resume() }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilDrainBegins() async {
        if draining { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor AsyncSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func deployment(_ value: String) throws -> AgentModelDeployment {
    try .init(
        serviceInstanceID: value,
        endpointScope: "https://fixture.invalid/v1",
        apiDialect: "fixture",
        apiVersion: "1"
    )
}
