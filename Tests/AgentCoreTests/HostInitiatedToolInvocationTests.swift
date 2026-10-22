@testable import AgentCore
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
        #expect(text.contains(MoveClipTool.name) && text.contains("The user moved clip 2 in the timeline.") && text.contains(#""moved":true"#))
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
        #expect(try await session.conversationSnapshot() == before)
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
        #expect(try await session.conversationSnapshot().messages.allSatisfy { if case .user = $0 { false } else { true } }, "nothing was committed")
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
