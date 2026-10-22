@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// ADR 0011: a tool call the Host makes outside a model turn (a user's change in an embedded panel) goes through the same
/// capability snapshot and the same guarantees as a model's call: tool authorization, durable mutation admission, the
/// Journal, Receipt validation and reconciliation. Formal history says the Host made it; the next Run's model sees it.
/// The model can never make a call in the Host's name.
struct HostInitiatedToolInvocationTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("host-invocation-\(UUID().uuidString)")
    }

    private func binding(_ session: AgentSession, _ tools: [AgentCapabilityTool]) async throws -> AgentCapabilityBinding {
        try await session.bindCapabilities(identity: "panel", version: "1", backendInstanceID: "fixture", backendVersion: "1",
                                           allowedResources: [.global, .named(.init(namespace: "timeline.clip", id: "clip-2"))],
                                           tools: tools)
    }

    /// A Host call's outcome, once it also drained, as a Host closing its Journal afterwards needs.
    private func invoke(_ session: AgentSession, _ call: AgentHostToolCall, capabilities: AgentCapabilityBinding,
                        operationID: String?) async throws -> AgentHostInvocationResult {
        let invocation = try await session.invokeHostTool(call, capabilities: capabilities, operationID: operationID)
        do {
            let result = try await invocation.wait()
            try await invocation.waitForDrain()
            return result
        } catch {
            try? await invocation.waitForDrain()
            throw error
        }
    }

    private func silentProvider() -> ScriptedProvider {
        ScriptedProvider { request, _ in textResponse(request, "unused") }
    }

    @Test func aHostCallRunsTheMutationWithIntentAndReceiptAndNoModel() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let probe = HostMutationProbe()
        let provider = silentProvider()
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: probe))])

        let result = try await invoke(session, 
            AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#, note: "The user moved clip 2 in the timeline."),
            capabilities: capabilities, operationID: "ui-drag-1"
        )

        #expect(await probe.count == 1)
        #expect(await probe.sawDurableIntent, "the intent is durable before the executor runs")
        #expect(result.call.id.rawValue.hasPrefix(AgentHostToolCall.callIDPrefix))
        #expect(result.result.isError == false)
        let receipt = try #require(result.receipt)
        #expect(receipt.effect == .mutation)
        #expect(try await journal.pendingMutations().isEmpty)
        #expect(try await journal.mutationStatus(identity: receipt.receipt.operationID)?.state == .settled)
        #expect(await provider.log.requests.isEmpty, "no model is asked")

        // Formal history says the Host made the call; no assistant message proposes it.
        let history = try await session.conversationSnapshot().messages
        let notice = try #require(history.last)
        guard case .user(let content) = notice, case .text(let text)? = content.first else { Issue.record("a user-side notice is expected"); return }
        #expect(text.hasPrefix(AgentHostToolCall.historyHeader))
        #expect(text.contains(MoveClipTool.name) && text.contains(#""moved":true"#))
        #expect(history.contains { if case .user(let content) = $0, case .text(let request)? = content.first {
            request.hasPrefix(AgentHostToolCall.historyHeader) && request.contains("The user moved clip 2 in the timeline.") } else { false } })
        #expect(!history.contains { if case .assistant(_, let calls) = $0 { calls.contains { $0.id == result.call.id } } else { false } })
        #expect(result.conversationRevision == (try await session.conversationSnapshot().revision))
        try await journal.close()
    }

    @Test func theNextRunsModelSeesWhatTheHostDid() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let provider = silentProvider()
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: HostMutationProbe()))])

        _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#),
                                             capabilities: capabilities, operationID: "ui-drag-1")
        let run = try await session.run("What changed?", capabilities: capabilities)
        _ = try await run.wait()
        try await run.waitForDrain()

        let messages = try #require(await provider.log.requests.first?.messages)
        #expect(messages.contains {
            if case .user(let content) = $0, case .text(let text)? = content.first { text.hasPrefix(AgentHostToolCall.historyHeader) } else { false }
        })
        try await journal.close()
    }

    @Test func aCallTheToolDoesNotAuthorizeIsNotExecutedAndChangesNothing() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let probe = HostMutationProbe()
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession(journal: journal)
        let capabilities = try await binding(session, [
            AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: probe, authorization: .denied)),
        ])
        let before = try await session.conversationSnapshot()

        await #expect(throws: (any Error).self) {
            _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#),
                                                 capabilities: capabilities, operationID: "ui-drag-1")
        }

        #expect(await probe.count == 0)
        #expect(await probe.authorizations == 1, "the tool's own authorization was asked")
        #expect(try await session.conversationSnapshot().messages.dropLast(2) == before.messages[...], "only the Host's request and its outcome were added")
        try await journal.close()
    }

    @Test func onlyAToolOfThisSessionsBindingCanBeCalled() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let agent = try Agent(model: fixtureModel, provider: silentProvider())
        let session = try agent.makeSession(journal: journal)
        let other = try agent.makeSession(journal: AgentJournal())
        let tool = AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: HostMutationProbe()))
        let own = try await binding(session, [tool])
        let foreign = try await binding(other, [tool])

        await #expect(throws: ToolRegistryError.unknownTool("delete_everything")) {
            _ = try await invoke(session, AgentHostToolCall(name: "delete_everything", argumentsJSON: "{}"), capabilities: own, operationID: "x")
        }
        await #expect(throws: AgentCapabilityError.sessionMismatch) {
            _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":1}"#),
                                                 capabilities: foreign, operationID: "x")
        }
        await own.revoke()
        await #expect(throws: AgentCapabilityError.revoked) {
            _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":1}"#),
                                                 capabilities: own, operationID: "x")
        }
        try await journal.close()
    }

    @Test func aMutationNeedsAStableOperationIDSoARetryIsNotASecondEffect() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let probe = HostMutationProbe()
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession(journal: journal)
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: probe))])
        let call = AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#)

        await #expect(throws: AgentHostInvocationError.operationIDRequired) {
            _ = try await invoke(session, call, capabilities: capabilities, operationID: nil)
        }
        let first = try await invoke(session, call, capabilities: capabilities, operationID: "ui-drag-1")
        let again = try await invoke(session, call, capabilities: capabilities, operationID: "ui-drag-1")

        #expect(await probe.count == 1, "the same operation is replayed, not executed twice")
        #expect(again.receipt?.receipt == first.receipt?.receipt)
        try await journal.close()
    }

    @Test func aMutationWhoseOutcomeIsUnknownGoesToReconciliationAndIsNotRepeated() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let probe = HostMutationProbe()
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession(journal: journal)
        let capabilities = try await binding(session, [
            AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: probe, failsAfterEffect: true)),
        ])
        let call = AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#)

        await #expect(throws: (any Error).self) { _ = try await invoke(session, call, capabilities: capabilities, operationID: "ui-drag-1") }
        #expect(try await journal.pendingMutations().map(\.state) == [.needsReconciliation])
        #expect(try await journal.pendingMutations().first?.intent.call.id.rawValue.hasPrefix(AgentHostToolCall.callIDPrefix) == true)

        await #expect(throws: AgentJournalError.mutationRequiresReconciliation) {
            _ = try await invoke(session, call, capabilities: capabilities, operationID: "ui-drag-1")
        }
        #expect(await probe.count == 1, "never executed again before reconciliation")
        try await journal.close()
    }

    @Test func aHostCallWaitsForNoRunAndIsRefusedWhileOneIsActive() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let gate = HostGate()
        let provider = ScriptedProvider { request, _ in
            await gate.wait()
            return textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: HostMutationProbe()))])
        let run = try await session.run("Go", capabilities: capabilities)

        await #expect(throws: AgentSessionError.runInProgress) {
            _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#),
                                                 capabilities: capabilities, operationID: "ui-drag-1")
        }
        await gate.open()
        _ = try await run.wait()
        try await run.waitForDrain()
        try await journal.close()
    }

    @Test func revokingTheBindingCancelsAHostCallUnderWay() async throws {
        let gate = HostGate()
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession()
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "wait", version: "1", tool: try WaitingReadTool(gate: gate, cooperative: true))])

        let call = Task { try await invoke(session, AgentHostToolCall(name: WaitingReadTool.name, argumentsJSON: "{}"),
                                                           capabilities: capabilities, operationID: nil) }
        await gate.waitUntilEntered()
        await capabilities.revoke()

        await #expect(throws: (any Error).self) { _ = try await call.value }
        #expect(await gate.sawCancellation)
        #expect(try await session.conversationSnapshot().messages.allSatisfy {
            if case .user(let content) = $0, case .text(let text)? = content.first { !text.contains("Result") } else { true }
        }, "no result was committed")
    }

    /// A Host call past its deadline ends, but its executor still owns the Session until it returns: the next Run waits.
    @Test func aTimedOutHostCallKeepsTheSessionUntilItsExecutorReturns() async throws {
        let gate = HostGate()
        let provider = silentProvider()
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "wait", version: "1", tool: try WaitingReadTool(gate: gate, cooperative: false))])

        let invocation = try await session.invokeHostTool(AgentHostToolCall(name: WaitingReadTool.name, argumentsJSON: "{}"), capabilities: capabilities,
            operationID: nil, budget: try AgentBudget(maxModelTurns: 1, maxToolCalls: 1, deadline: .now.advanced(by: .milliseconds(200))))
        await #expect(throws: AgentLoopError.deadlineExceeded) { _ = try await invocation.wait() }
        let next = Task { try await session.run("Next", budget: try testBudget()) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await provider.log.requests.isEmpty, "the next Run has not started")
        await gate.open()
        try await invocation.waitForDrain()
        let run = try await next.value
        _ = try await run.wait()
        #expect(await provider.log.requests.count == 1)
    }

    /// Review 2026-10-22: journals that keep Run records (schema 9 and later, the newest included) admit the Host call as a
    /// Run, with a record whose formal input is the Host's request and a terminal.
    @Test(arguments: [false, true])
    func aJournalThatKeepsRunRecordsRecordsTheHostCallAsARun(newest: Bool) async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = newest
            ? try AgentIncrementalJournal.createForIncompleteContextHandoff(at: url, operationDomain: "host-records")
            : try AgentIncrementalJournal.create(at: url, operationDomain: "host-records", supportsRunRecords: true)
        let probe = HostMutationProbe()
        let provider = silentProvider()
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: probe))])

        let result = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#),
                                      capabilities: capabilities, operationID: "ui-drag-1")

        #expect(await probe.count == 1)
        guard case .terminal(let record, .completed) = try await session.runRecord(runID: result.runID) else {
            Issue.record("the Host call has no completed Run record"); return
        }
        #expect(record.sessionID == session.id)
        // The next model Run still works on the same Journal.
        let run = try await session.run("What changed?", capabilities: capabilities)
        _ = try await run.wait()
        try await run.waitForDrain()
        #expect(await provider.log.requests.count == 1)
        try await journal.close()
    }

    /// Review 2026-10-22: a Host mutation reconciled later is settled in history as the Host's, never as an assistant call.
    @Test func reconcilingAHostMutationKeepsItTheHosts() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession(journal: journal)
        let capabilities = try await binding(session, [
            AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: HostMutationProbe(), failsAfterEffect: true)),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#),
                                 capabilities: capabilities, operationID: "ui-drag-1")
        }
        let pending = try #require(try await journal.pendingMutations(sessionID: session.id).first)

        try await journal.reconcileMutation(pending, receipt: ToolReceipt(operationID: pending.intent.idempotencyKey, status: .succeeded,
            confirmedTargets: [.init(namespace: "timeline.clip", id: "clip-2")], revision: "r2"), output: .object(["moved": .bool(true)]))

        let history = try #require(try await journal.latestCheckpoint(sessionID: session.id)?.history)
        #expect(!history.contains { if case .assistant(_, let calls) = $0 { calls.contains { $0.id == pending.intent.call.id } } else { false } })
        #expect(!history.contains { if case .tool(let result) = $0 { result.callID == pending.intent.call.id } else { false } })
        guard case .user(let content)? = history.last, case .text(let text)? = content.first else { Issue.record("a Host notice is expected"); return }
        #expect(text.hasPrefix(AgentHostToolCall.historyHeader) && text.contains("reconciled") && text.contains(#""moved":true"#))
        try await journal.close()
    }

    /// Review 2026-10-22: history says what the Host asked, what came of it, and that a retry replayed an earlier result.
    @Test func historySaysTheRequestTheResultAndAReplay() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession(journal: journal)
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: HostMutationProbe()))])
        let call = AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#, note: "The user moved clip 2.")

        _ = try await invoke(session, call, capabilities: capabilities, operationID: "ui-drag-1")
        _ = try await invoke(session, call, capabilities: capabilities, operationID: "ui-drag-1")

        let notices = try await session.conversationSnapshot().messages.compactMap { message -> String? in
            if case .user(let content) = message, case .text(let text)? = content.first, text.hasPrefix(AgentHostToolCall.historyHeader) { return text }
            return nil
        }
        #expect(notices.count == 4, "a request and a result for each call")
        #expect(notices[0].contains("asked to run") && notices[0].contains("The user moved clip 2.") && !notices[0].contains("Result"))
        #expect(notices[1].contains("Result") && !notices[1].contains("replayed"))
        #expect(notices[3].contains("replayed") && notices[3].contains("not run again"))
        try await journal.close()
    }

    /// Review 2026-10-22: a call that did not run leaves the request and says nothing was changed.
    @Test func aRefusedCallSaysNothingChanged() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = try makeTestJournal(at: url)
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession(journal: journal)
        let capabilities = try await binding(session, [
            AgentCapabilityTool(id: "move", version: "1", tool: try MoveClipTool(journal: journal, probe: HostMutationProbe(), authorization: .denied)),
        ])
        await #expect(throws: (any Error).self) {
            _ = try await invoke(session, AgentHostToolCall(name: MoveClipTool.name, argumentsJSON: #"{"clip":"clip-2","at":12}"#),
                                 capabilities: capabilities, operationID: "ui-drag-1")
        }
        guard case .user(let content)? = try await session.conversationSnapshot().messages.last, case .text(let text)? = content.first else {
            Issue.record("a Host notice is expected"); return
        }
        #expect(text.hasPrefix(AgentHostToolCall.historyHeader) && text.contains("did not complete") && text.contains("nothing was changed"))
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    /// Review 2026-10-22: the Host's operation namespace is the Host's, so a Run's call cannot share a Host call's key.
    @Test func aRunCannotUseTheHostsOperationNamespace() async throws {
        let session = try Agent(model: fixtureModel, provider: silentProvider()).makeSession()
        await #expect(throws: AgentHostInvocationError.reservedOperationID) { _ = try await session.run("Go", operationID: "host:ui-drag-1") }
    }

    /// Review 2026-10-22: a tool the Agent has but the binding does not is out of the Host's reach.
    @Test func aToolOfTheAgentOutsideTheBindingIsRefused() async throws {
        let session = try Agent(model: fixtureModel, provider: silentProvider(), tools: [AddTool(log: EffectLog())]).makeSession()
        let capabilities = try await binding(session, [AgentCapabilityTool(id: "wait", version: "1", tool: try WaitingReadTool(gate: HostGate(), cooperative: true))])
        await #expect(throws: ToolRegistryError.unknownTool(AddTool.name)) {
            _ = try await invoke(session, AgentHostToolCall(name: AddTool.name, argumentsJSON: #"{"lhs":1,"rhs":2}"#), capabilities: capabilities, operationID: nil)
        }
    }

    /// Review 2026-10-22: a Session released while its Host call runs still releases its owner once the call returns.
    @Test(.timeLimit(.minutes(1))) func aSessionReleasedMidCallStillReleasesItsOwner() async throws {
        let gate = HostGate()
        let agent = try Agent(model: fixtureModel, provider: silentProvider())
        let sessionID = UUID()
        var session: AgentSession? = try agent.makeSession(id: sessionID)
        let capabilities = try await binding(session!, [AgentCapabilityTool(id: "wait", version: "1", tool: try WaitingReadTool(gate: gate, cooperative: false))])
        let invocation = try await session!.invokeHostTool(AgentHostToolCall(name: WaitingReadTool.name, argumentsJSON: "{}"),
                                                           capabilities: capabilities, operationID: nil)
        await gate.waitUntilEntered()
        session = nil
        await gate.open()
        _ = try? await invocation.wait()
        try await invocation.waitForDrain()

        let again = try agent.makeSession(id: sessionID)
        let run = try await again.run("Go", budget: try testBudget())
        _ = try await run.wait()
    }

    /// The Host's call namespace is the Host's: a model's proposal using it is refused before anything runs.
    @Test func aModelCannotMakeACallInTheHostsName() async throws {
        let log = EffectLog()
        let forged = ToolCall(id: .init(rawValue: AgentHostToolCall.callIDPrefix + "1"), name: AddTool.name,
                              argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [forged]) : textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: log)]).makeSession()

        let run = try await session.run("Add", budget: try testBudget())
        await #expect(throws: AgentHostInvocationError.reservedCallIdentity(forged.id)) { _ = try await run.wait() }
        #expect(await log.names.isEmpty)
    }
}

private actor HostGate {
    private var opened = false
    private var entered = false
    private(set) var sawCancellation = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        enter()
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func enter() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func cancelled() { sawCancellation = true }
    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A read-only tool that waits: until cancelled when cooperative, or until the gate opens whatever happens.
private struct WaitingReadTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let done: Bool }
    static let name = "wait_for_panel"
    static let description = "Wait for the panel"
    static let inputSchema = ToolSchema.object(properties: [:], required: [])
    static let outputSchema = ToolSchema.object(properties: ["done": .boolean], required: ["done"])
    let gate: HostGate
    let cooperative: Bool
    let policy: ToolPolicy

    init(gate: HostGate, cooperative: Bool) throws {
        self.gate = gate
        self.cooperative = cooperative
        policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(30), authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        if cooperative {
            await gate.enter()
            do { try await Task.sleep(for: .seconds(30)) } catch { await gate.cancelled(); throw error }
        } else {
            await gate.wait()
        }
        return ToolResult(output: .init(done: true))
    }
}

private actor HostMutationProbe {
    private(set) var count = 0
    private(set) var authorizations = 0
    private(set) var sawDurableIntent = false
    func authorized() { authorizations += 1 }
    func record(journal: AgentJournal, callID: ToolCallID) async {
        count += 1
        sawDurableIntent = (try? await journal.pendingMutations().contains { $0.intent.call.id == callID && $0.state == .intent }) == true
    }
}

private struct HostFixtureError: Error {}

/// Moves a clip in a fixture timeline: a mutation with a Receipt, its own authorization and, when asked, a failure after
/// its effect, as an executor that cannot say what happened.
private struct MoveClipTool: AgentTool {
    struct Input: Codable, Sendable { let clip: String; let at: Int }
    struct Output: Codable, Sendable { let moved: Bool }
    static let name = "move_clip"
    static let description = "Move a clip in the timeline"
    static let inputSchema = ToolSchema.object(properties: ["clip": .string, "at": .integer], required: ["clip", "at"])
    static let outputSchema = ToolSchema.object(properties: ["moved": .boolean], required: ["moved"])
    let journal: AgentJournal
    let probe: HostMutationProbe
    let answer: ToolAuthorization
    let failsAfterEffect: Bool
    let policy: ToolPolicy

    init(journal: AgentJournal, probe: HostMutationProbe, authorization answer: ToolAuthorization = .allowed, failsAfterEffect: Bool = false) throws {
        self.journal = journal
        self.probe = probe
        self.answer = answer
        self.failsAfterEffect = failsAfterEffect
        policy = try .mutation(authorization: .required, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "timeline.clip", id: input.clip))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "timeline.clip", id: input.clip)], revision: .present)
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        await probe.authorized()
        return answer
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record(journal: journal, callID: context.callID)
        if failsAfterEffect { throw HostFixtureError() }
        return ToolResult(output: .init(moved: true), receipt: ToolReceipt(
            operationID: context.idempotencyKey ?? "", status: .succeeded,
            confirmedTargets: [.init(namespace: "timeline.clip", id: input.clip)], revision: "r2"))
    }
}
