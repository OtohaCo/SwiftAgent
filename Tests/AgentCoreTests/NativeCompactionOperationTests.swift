import AgentJournalFileStore
import AgentTools
import AgentModels
import Foundation
import Testing
@testable import AgentCore

@Suite struct NativeCompactionOperationTests {
    @Test func automaticToolFactsAndCheckpointUseOnePublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let barrier = NativeCompactionBarrier()
        let provider = NativeOperationFixture(generationBarrier: barrier, automaticToolResponse: true)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "native-tool",
                                                                   supportsNativeContext: true, fault: { _ in })
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider,
                              tools: [AddTool(log: EffectLog())], configuration: .init(instructions: "root"))
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("source")
        let observer = Task {
            do { _ = try await run.wait() }
            catch { Issue.record(error); await barrier.signalEntered() }
        }
        await barrier.waitEntered()
        // Startup and the complete tool-result publication. A third batch would mean the
        // tool facts became durable before their dependent native context checkpoint.
        #expect(await journal.storageMetrics()?.committedBatches == 2)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) != nil)
        #expect(try await session.conversationSnapshot().messages.count == 4)
        await barrier.release()
        _ = try await run.wait(); try await run.waitForDrain()
        await observer.value
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session.id) != nil)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history.count == 4)
        try await reopened.close()
    }
    @Test(arguments: ["success", "conflict"], [false, true])
    func nativeSettlementAndEffectLedgerPublishTogether(_ mode: String, _ audited: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "native-settlement",
            supportsAuthorizationAudit: audited, supportsConfirmedNoEffect: true, supportsNativeContext: true, fault: { _ in })
        let counts = NoEffectCounts(), file = directory.appendingPathComponent("effect")
        let calls = [ToolCall(id: .init(rawValue: "native-add"), name: "add", argumentsJSON: #"{"lhs":2,"rhs":3}"#, completeness: .complete),
            ToolCall(id: .init(rawValue: "native-mutation"), name: "no_effect_file", argumentsJSON: "{}", completeness: .complete)]
        let provider = NativeOperationFixture(automaticToolCalls: calls)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider,
            tools: [AddTool(log: EffectLog()), try NoEffectFileTool(file: file, counts: counts, mode: mode)],
            configuration: audited ? .init(authorization: auditTestConfiguration()) : .init())
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("source", operationID: "native-settlement")
        _ = try await run.wait(); try await run.waitForDrain()
        #expect(await counts.executions == 1)
        #expect(await counts.effects == (mode == "success" ? 1 : 0))
        #expect(try await journal.pendingMutations().isEmpty)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) != nil)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session.id) != nil)
        let facts = try await reopened.latestCheckpoint(sessionID: session.id)?.history ?? []
        #expect(facts.count == 5)
        #expect(facts.contains { if case .tool(let result) = $0 { result.callID == calls[1].id && result.isError == (mode == "conflict") } else { false } })
        #expect((try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: calls[1].id) != nil) == (mode == "conflict"))
        if audited { #expect(try await !reopened.auditRecords(matching: .init(runID: run.id)).records.isEmpty) }
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func nativeNoEffectPublicationFailureHasNoHalfCheckpoint(_ unknown: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = NativeSettlementFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "native-fault",
            supportsAuthorizationAudit: true, supportsConfirmedNoEffect: true, supportsNativeContext: true, fault: { try fault.check($0) })
        let call = ToolCall(id: .init(rawValue: "native-mutation"), name: "no_effect_file", argumentsJSON: "{}", completeness: .complete)
        let counts = NoEffectCounts(), provider = NativeOperationFixture(automaticToolCalls: [call])
        let session = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider,
            tools: [try NoEffectFileTool(file: directory.appendingPathComponent("effect"), counts: counts, beforeReturn: { fault.arm() })],
            configuration: .init(authorization: auditTestConfiguration())).makeSession(journal: journal)
        let run = try await session.run("source", operationID: "native-fault")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await counts.effects == 0); #expect(await counts.executions == 1)
        #expect(await provider.requests.count == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let native = try await reopened.nativeContextCheckpoint(sessionID: session.id)
        let proof = try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: call.id)
        #expect((native != nil) == unknown); #expect((proof != nil) == unknown)
        let facts = try await reopened.latestCheckpoint(sessionID: session.id)?.history ?? []
        #expect(facts.count == (unknown ? 3 : 1))
        #expect(try await reopened.pendingMutations().map(\.state) == (unknown ? [] : [.needsReconciliation]))
        try await reopened.close()
    }
    @Test func idleCompactPreservesCanonicalAndNextRunUsesNativeWindow() async throws {
        let provider = NativeOperationFixture()
        let model = ModelID(provider: "native-fixture", name: "model")
        let agent = try Agent(model: model, provider: provider, instructions: "root constraint")
        let journal = AgentJournal(), id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        let first = try await session.run("original full source")
        _ = try await first.wait(); try await first.waitForDrain()
        let original = try await session.conversationSnapshot().messages
        let operation = try await session.compact(mode: .openAIStandalone)
        let result = try await operation.wait(); try await operation.waitForDrain()
        #expect(result.checkpoint != nil)
        #expect(try await session.conversationSnapshot().messages == original)
        let second = try await session.run("next question")
        _ = try await second.wait(); try await second.waitForDrain()
        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(requests[1].nativeContext == result.checkpoint)
        #expect(requests[1].messages == [.system("root constraint"), .user([.text("next question")])])
        let restored = try agent.makeSession(id: id, journal: journal)
        let third = try await restored.run("after reconstruction")
        _ = try await third.wait(); try await third.waitForDrain()
        #expect(await provider.requests.last?.nativeContext == result.checkpoint)
        #expect(try await journal.latestCheckpoint(sessionID: id)?.history.count == 7)
    }
    @Test func completeNoSummaryIsNotFinalAnswerOrCheckpoint() async throws {
        let provider = NativeOperationFixture(noSummary: true)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider)
        let journal = AgentJournal(), session = try agent.makeSession(journal: journal)
        let run = try await session.run("input"); _ = try await run.wait(); try await run.waitForDrain()
        let prior = try await session.conversationSnapshot()
        let operation = try await session.compact(mode: .openAIStandalone)
        #expect(try await operation.wait().checkpoint == nil)
        try await operation.waitForDrain()
        #expect(try await session.conversationSnapshot() == prior)
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == nil)
    }
    @Test func cancelledLogicalOperationRetainsWriterUntilPhysicalDrain() async throws {
        let barrier = NativeCompactionBarrier()
        let provider = NativeOperationFixture(barrier: barrier)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider)
        let journal = AgentJournal(), id = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        let run = try await session.run("original"); _ = try await run.wait(); try await run.waitForDrain()
        let operation = try await session.compact(mode: .openAIStandalone)
        await barrier.waitEntered()
        await operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.wait() }
        await #expect(throws: AgentSessionError.runInProgress) { try await session.run("blocked") }
        let replacement = try agent.makeSession(id: id, journal: journal)
        await #expect(throws: AgentSessionError.runInProgress) { try await replacement.run("also blocked") }
        #expect(try await journal.nativeContextCheckpoint(sessionID: id) == nil)
        await barrier.release()
        try await operation.waitForDrain()
        let next = try await replacement.run("safe continuation")
        _ = try await next.wait(); try await next.waitForDrain()
        #expect(await provider.requests.count == 2)
    }

    @Test func admittedRunUsesSameCompactExecutorAndPublishesBeforeGeneration() async throws {
        let provider = NativeOperationFixture()
        let model = ModelID(provider: "native-fixture", name: "model")
        let binding = try AgentModelBinding(profileID: "native", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "fixture", apiDialect: "fixture"),
            nativeContextPolicy: .init(compactBeforeGeneration: .openAIStandalone))
        let agent = try Agent(model: model, provider: provider)
        let journal = AgentJournal(), session = try agent.makeSession(journal: journal)
        let run = try await session.run("input retained canonically", using: binding)
        var compactUsage = 0
        for await event in run.events {
            if case .compaction(_, _, .usage(let usage)) = event { compactUsage += usage.inputTokens ?? 0 }
        }
        let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.outcome == .completed)
        #expect(compactUsage == 12)
        #expect(await provider.requests.count == 1)
        #expect(await provider.requests.first?.nativeContext != nil)
        #expect(await provider.requests.first?.messages.isEmpty == true)
        #expect(try await session.conversationSnapshot().messages.count == 2)
    }
    @Test func automaticMaintenancePublishesAndContinuesWithoutFinalAnswer() async throws {
        let provider = NativeOperationFixture(maintenanceResponses: 1)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider)
        let journal = AgentJournal(), session = try agent.makeSession(journal: journal)
        let run = try await session.run("long source")
        let result = try await run.wait(); try await run.waitForDrain()
        #expect(result.outcome == .completed)
        #expect(result.modelTurns == 2)
        #expect(await provider.requests.last?.nativeContext != nil)
        #expect(try await session.conversationSnapshot().messages.count == 2)
    }
    @Test func repeatedMaintenanceIsBoundedAndNeverCompletesRun() async throws {
        let provider = NativeOperationFixture(maintenanceResponses: 20)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider)
        let session = try agent.makeSession()
        let run = try await session.run("source")
        await #expect(throws: ModelProviderError.self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await provider.requests.count == 5)
        #expect(try await session.conversationSnapshot().messages.count == 1)
    }

    @Test func maintenanceSummaryDoesNotDisableDeadlineForFollowingAnswer() async throws {
        let barrier = NativeCompactionBarrier()
        let provider = NativeOperationFixture(maintenanceResponses: 1, generationBarrier: barrier)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider)
        let journal = AgentJournal(), session = try agent.makeSession(journal: journal)
        let run = try await session.run("source", budget: .init(maxModelTurns: 8, maxToolCalls: 0,
                                                                deadline: .now.advanced(by: .milliseconds(300))))
        await barrier.waitEntered()
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await run.wait() }
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) != nil)
        #expect(try await session.conversationSnapshot().messages.count == 1)
        await barrier.release()
        try await run.waitForDrain()
        #expect(try await session.conversationSnapshot().messages.count == 1)
    }

    @Test func maintenanceCannotPublishUnacceptedClientToolProposal() async throws {
        let provider = NativeOperationFixture(maintenanceResponses: 1, maintenanceToolProposal: true)
        let agent = try Agent(model: .init(provider: "native-fixture", name: "model"), provider: provider)
        let journal = AgentJournal(), session = try agent.makeSession(journal: journal)
        let run = try await session.run("source")
        await #expect(throws: ModelProviderError.self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == nil)
        #expect(try await session.conversationSnapshot().messages.count == 1)
        #expect(await provider.requests.count == 1)
    }

}

private actor NativeOperationFixture: ModelProviderCompaction, ModelProviderRunDrain {
    nonisolated let descriptor = ModelProviderDescriptor(id: "native-fixture", capabilities: [.streaming, .multiTurn, .tools])
    nonisolated let automaticCompaction: ModelAutomaticCompaction?
    nonisolated let compactionModes: Set<ModelCompactionMode> = [.openAIStandalone]
    let automaticToolCalls: [ToolCall]?
    let automaticToolResponse: Bool
    let noSummary: Bool
    let barrier: NativeCompactionBarrier?
    let maintenanceResponses: Int
    let maintenanceToolProposal: Bool
    let generationBarrier: NativeCompactionBarrier?
    var requests: [ModelRequest] = []
    init(noSummary: Bool = false, barrier: NativeCompactionBarrier? = nil, maintenanceResponses: Int = 0, generationBarrier: NativeCompactionBarrier? = nil, maintenanceToolProposal: Bool = false, automaticToolResponse: Bool = false, automaticToolCalls: [ToolCall]? = nil) { self.automaticToolCalls = automaticToolCalls; self.automaticToolResponse = automaticToolResponse || automaticToolCalls != nil; self.maintenanceToolProposal = maintenanceToolProposal; self.noSummary = noSummary; self.barrier = barrier; self.maintenanceResponses = maintenanceResponses; self.generationBarrier = generationBarrier; self.automaticCompaction = maintenanceResponses > 0 || automaticToolResponse || automaticToolCalls != nil ? try! .init(mode: .anthropicThreshold, triggerInputTokens: 50_000) : nil }
    nonisolated func validateCompaction(request: ModelCompactionRequest) throws {}
    nonisolated func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { c in
            Task {
                if let barrier { await barrier.block() }
                let info = ResponseInfo(id: "compact", model: request.request.model)
                var state: ModelProviderContinuation?
                if !noSummary {
                    let transition = ModelNativeContextTransition(mode: request.mode, source: request.request.nativeContextSource!,
                        replayPosition: 0, invocationID: request.invocationID, responseID: info.id)
                    state = .init(model: info.model, format: "fixture-native", payload: Data("opaque".utf8), contextTransition: transition)
                }
                c.yield(.usage(.init(inputTokens: 12, outputTokens: 2)))
                c.yield(.completed(.init(info: info, continuation: state, usage: .init(inputTokens: 12, outputTokens: 2))))
                c.finish()
                await barrier?.finish()
            }
        }
    }
    func waitForCompactionToDrain(sessionID: UUID, operationID: UUID) async { await barrier?.waitFinished() }
    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { c in
            Task {
                let ordinal = await record(request)
                let info = ResponseInfo(id: UUID().uuidString, model: request.model)
                c.yield(.responseStarted(info))
                if ordinal <= maintenanceResponses {
                    let transition = ModelNativeContextTransition(mode: .anthropicThreshold, source: request.nativeContextSource!,
                        replayPosition: 0, invocationID: request.invocationID!, responseID: info.id)
                    let state = ModelProviderContinuation(model: info.model, format: "fixture-native", payload: Data("opaque".utf8), contextTransition: transition)
                    c.yield(.providerContinuation(state))
                    var calls: [ToolCall] = []
                    if maintenanceToolProposal {
                        let call = ToolCall(id: .init(rawValue: "unaccepted"), name: "outside_registry", argumentsJSON: "{}", completeness: .complete)
                        c.yield(.toolCallStarted(call.id, name: call.name)); c.yield(.toolCallArgumentsDelta(call.id, "{}")); c.yield(.toolCallCompleted(call))
                        calls = [call]
                    }
                    c.yield(.responseCompleted(.init(info: info, content: [.providerContinuation(state)], toolCalls: calls, stopReason: .unknown("compaction"))))
                    c.finish(); return
                }
                if automaticToolResponse && ordinal == 1 {
                    let transition = ModelNativeContextTransition(mode: .anthropicThreshold, source: request.nativeContextSource!,
                        replayPosition: 0, invocationID: request.invocationID!, responseID: info.id)
                    let state = ModelProviderContinuation(model: info.model, format: "fixture-native", payload: Data("opaque".utf8), contextTransition: transition)
                    let call = ToolCall(id: .init(rawValue: "native-add"), name: "add", argumentsJSON: #"{"lhs":2,"rhs":3}"#, completeness: .complete)
                    let calls = automaticToolCalls ?? [call]
                    c.yield(.providerContinuation(state))
                    for call in calls {
                        c.yield(.toolCallStarted(call.id, name: call.name)); c.yield(.toolCallArgumentsDelta(call.id, call.argumentsJSON)); c.yield(.toolCallCompleted(call))
                    }
                    c.yield(.responseCompleted(.init(info: info, content: [.providerContinuation(state)], toolCalls: calls, stopReason: .toolCalls)))
                    c.finish(); return
                }
                if let generationBarrier { await generationBarrier.block() }
                c.yield(.textDelta("answer"))
                c.yield(.responseCompleted(.init(info: info, content: [.text("answer")], stopReason: .endTurn))); c.finish()
                await generationBarrier?.finish()
            }
        }
    }
    func waitForRunToDrain(sessionID: UUID, runID: UUID) async { await generationBarrier?.waitFinished() }
    func record(_ request: ModelRequest) -> Int { requests.append(request); return requests.count }
}

private actor NativeCompactionBarrier {
    private var entered = false, released = false, finished = false
    private var enterWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    func block() async {
        entered = true; enterWaiters.forEach { $0.resume() }; enterWaiters.removeAll()
        if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func signalEntered() { entered = true; enterWaiters.forEach { $0.resume() }; enterWaiters.removeAll() }
    func waitEntered() async { if !entered { await withCheckedContinuation { enterWaiters.append($0) } } }
    func release() { released = true; releaseWaiter?.resume(); releaseWaiter = nil }
    func finish() { finished = true; finishWaiters.forEach { $0.resume() }; finishWaiters.removeAll() }
    func waitFinished() async { if !finished { await withCheckedContinuation { finishWaiters.append($0) } } }
}

private final class NativeSettlementFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let unknown: Bool
    init(unknown: Bool) { self.unknown = unknown }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        let eligible: Bool
        if unknown { if case .afterCurrentReplace = stage { eligible = true } else { eligible = false } }
        else { if case .beforeAppend = stage { eligible = true } else { eligible = false } }
        guard eligible else { return }
        if lock.withLock({ let value = armed; armed = false; return value }) {
            throw AgentJournalError.persistenceUnavailable("native settlement publication fixture")
        }
    }
}
