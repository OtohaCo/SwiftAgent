import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct QueuedPerCallTests {
    @Test(arguments: [["same", "same"], ["A", "B", "A"]])
    func independentMutations(values: [String]) async throws {
        let result = try await exercise(values, identity: .perCall)
        #expect(result.calls == values)
        #expect(result.file == values.last!)
    }
    @Test func appendSameLineTwice() async throws {
        let result = try await exercise(["line\n", "line\n"], identity: .perCall, append: true)
        #expect(result.calls == ["line\n", "line\n"])
        #expect(result.file == "line\nline\n")
    }
    @Test func legacyOperationStillReplays() async throws {
        let result = try await exercise(["A", "B", "A"], identity: .operation("stable"))
        #expect(result.calls == ["A", "B"])
        #expect(result.file == "B")
    }

    @Test func persistenceConflictAndWithdrawalPreserveIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-reopen-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try AgentIncrementalJournal.create(at: root, operationDomain: "test", supportsPerCallFollowUps: true)
        let agent = try Agent(model: .init(provider: Changes.providerID, name: "fixed"), provider: Changes(values: []))
        let id = UUID(), other = UUID()
        let session = try agent.makeSession(id: id, journal: journal)
        let input = AgentFollowUpInput(inputID: "same", text: "exact", identity: .perCall, configurationRef: "v1")
        let first = try await session.enqueueFollowUp(input)
        #expect(first.identity == .perCall && first.operationID == nil)
        #expect(try await session.enqueueFollowUp(input) == first)
        await #expect(throws: AgentFollowUpError.inputConflict) {
            try await session.enqueueFollowUp(.init(inputID: "same", text: "exact", operationID: "old", configurationRef: "v1"))
        }
        let second = try agent.makeSession(id: other, journal: journal)
        #expect(try await second.enqueueFollowUp(input).sessionID == other)
        _ = try await journal.requestMaintenance()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: root)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "same") == first)
        #expect(try await restored.withdrawFollowUp(inputID: "same") == .withdrawn)
        let withdrawn = try await restored.enqueueFollowUp(input)
        #expect(withdrawn.state == .withdrawn && withdrawn.identity == .perCall)
        try await reopened.close()
    }

    @Test func oldStoreRejectsPerCallBeforeEnqueueAndRetainsOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity-old-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try AgentIncrementalJournal.create(at: root, operationDomain: "test")
        let agent = try Agent(model: .init(provider: Changes.providerID, name: "fixed"), provider: Changes(values: []))
        let id = UUID(), session = try agent.makeSession(id: id, journal: journal)
        await #expect(throws: AgentJournalError.unsupportedFormat) {
            try await session.enqueueFollowUp(.init(inputID: "new", text: "exact", identity: .perCall, configurationRef: "v1"))
        }
        #expect(try await session.followUp(inputID: "new") == nil)
        let old = try await session.enqueueFollowUp(.init(inputID: "old", text: "exact", operationID: "stable", configurationRef: "v1"))
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: root)
        let restored = try agent.makeSession(id: id, journal: reopened)
        #expect(try await restored.followUp(inputID: "old") == old)
        #expect(old.identity == .operation("stable"))
        try await reopened.close()
    }

    @Test func independentQueuedRunsInTwoSessionsDoNotShareReceipts() async throws {
        let result = try await exercise(["same", "same"], identity: .perCall, twoSessions: true)
        #expect(result.calls == ["same", "same", "same", "same"])
        #expect(result.file == "same")
    }
    @Test func perCallWithDeferredMutationAndRequiredAudit() async throws {
        let result = try await exercise(["A", "B", "A"], identity: .perCall, deferred: true, audited: true)
        #expect(result.calls == ["A", "B", "A"] && result.file == "A")
    }
    @Test func perCallConfirmedNoEffectIsNotReplayed() async throws {
        let result = try await exercise(["reject", "reject"], identity: .perCall, noEffect: true)
        #expect(result.calls == ["reject", "reject"] && result.file.isEmpty)
    }
    private func exercise(_ values: [String], identity: AgentOperationIdentity, append: Bool = false, deferred: Bool = false, audited: Bool = false, noEffect: Bool = false, twoSessions: Bool = false) async throws -> (calls: [String], file: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("per-call-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("result")
        try Data().write(to: file)
        let journal = try AgentIncrementalJournal.create(at: root.appendingPathComponent("journal"), operationDomain: "test", supportsPerCallFollowUps: true)
        let ran = Ran(), provider = Changes(values: values, deferred: deferred)
        let agent = try Agent(model: .init(provider: Changes.providerID, name: "fixed"), provider: provider, configuration: .init(authorization: audited ? auditTestConfiguration() : .init()))
        let session = try agent.makeSession(journal: journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "perform", identity: identity, configurationRef: "v1"))
        let finished = XCTestExpectation(description: "logical finish")
        let dispatcher = try await session.startFollowUpDispatch(policy: .init(maxModelTurns: 8, maxToolCalls: 6, runTimeout: .seconds(10)), resolver: Resolver(session: session, provider: provider, tool: try ChangeTool(ran: ran, file: file, append: append, noEffect: noEffect)), onRun: { _, run in
            do { #expect(try await run.wait().outcome == .completed) }
            catch { Issue.record("Run failed: \(error)") }
            finished.fulfill()
        })
        let observed = await XCTWaiter.fulfillment(of: [finished], timeout: 15)
        await dispatcher.stop()
        try await dispatcher.waitForDrain()
        #expect(observed == .completed)
        if twoSessions {
            let second = try agent.makeSession(journal: journal)
            _ = try await second.enqueueFollowUp(.init(inputID: "one", text: "perform", identity: identity, configurationRef: "v1"))
            let finishedAgain = XCTestExpectation(description: "second Session finished")
            let another = try await second.startFollowUpDispatch(policy: .init(maxModelTurns: 8, maxToolCalls: 6, runTimeout: .seconds(10)), resolver: Resolver(session: second, provider: provider, tool: try ChangeTool(ran: ran, file: file, append: append)), onRun: { _, run in
                do { #expect(try await run.wait().outcome == .completed) }
                catch { Issue.record("second Run failed: \(error)") }
                finishedAgain.fulfill()
            })
            let observedAgain = await XCTWaiter.fulfillment(of: [finishedAgain], timeout: 15)
            await another.stop(); try await another.waitForDrain()
            #expect(observedAgain == .completed)
            let results = try await journal.readMessages(sessionID: second.id).compactMap { record -> JSONValue? in
                if case .tool(let result) = record.message, case .json(let output)? = result.content.first { return output }
                return nil
            }
            #expect(results == [.object(["run": .number(3)]), .object(["run": .number(4)])])
        }
        let outputs = try await journal.readMessages(sessionID: session.id).compactMap { record -> Int? in
            guard case .tool(let result) = record.message, case .json(let json)? = result.content.first,
                  let data = try? JSONEncoder().encode(json) else { return nil }
            return try? JSONDecoder().decode(ChangeTool.Output.self, from: data).run
        }
        if !noEffect { #expect(outputs == (identity == .perCall ? Array(1...values.count) : [1, 2, 1])) }
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
        return (ran.values, try String(contentsOf: file, encoding: .utf8))
    }
    private struct Resolver: AgentFollowUpResolver {
        let session: AgentSession
        let provider: Changes
        let tool: ChangeTool
        func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
            let scope = try await session.bindCapabilities(identity: "test", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.named(.init(namespace: "workspace", id: "project"))], tools: provider.deferred ? [.init(id: "find", version: "1", tool: Find()), .init(id: "change", version: "1", tool: tool, exposure: .deferred)] : [.init(id: "change", version: "1", tool: tool)])
            return .init(model: try AgentModelBinding(profileID: "test", profileRevision: "1", model: .init(provider: Changes.providerID, name: "fixed"), provider: provider, deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")), capabilities: scope, expectedConversationRevision: nil)
        }
    }
    /// What really ran, in order.
    private final class Ran: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        var values: [String] { lock.withLock { value } }
        func add(_ value: String) -> Int { lock.withLock { self.value.append(value); return self.value.count } }
    }

    /// Shaped like `skill_run` and `workspace_write`: a change to the project folder that needs a
    /// receipt, approved, whose identity is its arguments.
    private struct ChangeTool: AgentTool {
        struct Input: Codable, Sendable { var value: String }
        struct Output: Codable, Sendable { var run: Int }

        static let name = "change_project"
        static let description = "Make a change to the project."
        static let inputSchema = ToolSchema.object(properties: ["value": .string], required: ["value"])
        static let outputSchema = ToolSchema.object(properties: ["run": .integer], required: ["run"])

        let ran: Ran
        let file: URL
        let noEffect: Bool
        let append: Bool
        let policy: ToolPolicy

        init(ran: Ran, file: URL, append: Bool, noEffect: Bool = false) throws {
            self.noEffect = noEffect
            self.file = file; self.append = append
            self.ran = ran
            policy = try ToolPolicy(
                effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                timeout: .seconds(30), authorization: .required, evidence: .none, recoverableErrors: noEffect ? .confirmedNoEffect : .failClosed
            )
        }

        func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [] }
        func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "workspace", id: "project"))] }
        func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
            try ToolReceiptExpectation(targets: [EvidenceReference(namespace: "workspace", id: "project")], revision: .present)
        }
        func authorizationBinding(for input: Input) throws -> ToolAuthorizationBinding {
            .init(implementationVersion: "1", backend: .init(instanceID: "fixture-backend", version: "1", accountID: "fixture-account", credentialGeneration: "1"))
        }
        func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { .allowed }
        func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
            let run = ran.add(input.value)
            if noEffect {
                throw try context.confirmNoEffect(receipt: .init(operationID: context.idempotencyKey!, status: .failed, confirmedTargets: [], failure: .rejected), error: .init(code: "rejected", message: "No write"), wholeOperationHadNoEffect: true, noOutstandingEffects: true, basis: "before write")
            }
            let previous = append ? try String(contentsOf: file, encoding: .utf8) : ""
            try Data((previous + input.value).utf8).write(to: file)
            return ToolResult(
                output: Output(run: run),
                receipt: ToolReceipt(
                    operationID: context.idempotencyKey ?? context.callID.rawValue, status: .succeeded,
                    confirmedTargets: [EvidenceReference(namespace: "workspace", id: "project")], revision: "run-\(run)"
                )
            )
        }
    }

    private struct Find: AgentTool {
        struct Input: Codable, Sendable {}
        typealias Output = String
        static let name = "find"
        static let description = "Declare bound mutation"
        static let inputSchema = ToolSchema.object(properties: [:])
        static let outputSchema = ToolSchema.string
        let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
        func authorizationBinding(for input: Input) throws -> ToolAuthorizationBinding {
            .init(implementationVersion: "1", backend: .init(instanceID: "fixture-backend", version: "1", accountID: "fixture-account", credentialGeneration: "1"))
        }
        func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "workspace", id: "project"))] }
        func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
            .init(output: "found", declaredTools: [ChangeTool.name])
        }
    }
    /// Asks for the changes in `values`, one after the other, then answers.
    private struct Changes: ModelProvider {
        static let providerID = "changes-in-turn"
        let descriptor = ModelProviderDescriptor(id: providerID, capabilities: [.streaming, .multiTurn, .tools])
        let values: [String]
        var deferred = false
        

        func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
            let values = values
            return ModelEventStream.make { emit in
                let info = ResponseInfo(id: "r-\(UUID().uuidString)", model: request.model)
                try emit(.responseStarted(info))
                let user = request.messages.lastIndex { if case .user = $0 { return true }; return false } ?? 0
                let done = request.messages[user...].filter { if case .tool(let r) = $0 { return !r.callID.rawValue.hasPrefix("find") }; return false }.count
                if deferred, !request.tools.contains(where: { $0.name == ChangeTool.name }) {
                    let call = ToolCall(id: .init(rawValue: "find-\(UUID())"), name: "find", argumentsJSON: "{}", completeness: .complete)
                    try emit(.toolCallStarted(call.id, name: call.name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON)); try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls))); return
                }
                let usage = ModelUsage(inputTokens: 1, outputTokens: 1)
                guard done < values.count else {
                    try emit(.textDelta("done"))
                    try emit(.usage(usage))
                    try emit(.responseCompleted(.init(info: info, content: [.text("done")], usage: usage, stopReason: .endTurn)))
                    return
                }
                let call = ToolCall(
                    id: .init(rawValue: "change-\(UUID().uuidString)"), name: ChangeTool.name,
                    argumentsJSON: String(decoding: try JSONEncoder().encode(ChangeTool.Input(value: values[done])), as: UTF8.self), completeness: .complete
                )
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.usage(usage))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], usage: usage, stopReason: .toolCalls)))
            }
        }
    }

}
