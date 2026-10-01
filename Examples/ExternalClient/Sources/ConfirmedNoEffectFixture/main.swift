import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main public struct ConfirmedNoEffectFixture {
    public static func main() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "corrected"
        let counts = try await runFixture(mode: mode)
        print(String(decoding: try JSONEncoder().encode(counts), as: UTF8.self))
    }

    /// Public SDK consumer; never directly calls execute or constructs an internal ledger.
    public static func runFixture(mode: String = "corrected") async throws -> [String: Int] {
        guard ["corrected", "default", "unknown"].contains(mode) else { throw FixtureFailure.invalidMode }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftAgent-no-effect-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "fixture-no-effect", supportsConfirmedNoEffect: true)
        let file = directory.appendingPathComponent("controlled.txt")
        let counter = Counter(); let authorizer = HostAuthorizer()
        let provider = FixtureProvider(counter: counter)
        let agent = try Agent(model: .init(provider: "fixture", name: "controlled"), provider: provider,
            tools: [ControlledWrite(file: file, counter: counter, mode: mode)],
            configuration: .init(authorization: .init(mode: .requiredAudit, authorizer: authorizer,
                identity: .init(securityDomain: "fixture", subjectID: "synthetic-user", actingSubjectID: "fixture-agent",
                    backend: .init(instanceID: "temporary-file", version: "1", accountID: "fixture", credentialGeneration: "1")))))
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("Write the controlled file", operationID: "stable-business-operation")
        let result: AgentLoopResult?
        do { result = try await run.wait() }
        catch { guard mode != "corrected" else { throw error }; result = nil }
        try await run.waitForDrain()
        let proof = try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A"))
        let pending = try await journal.pendingMutations().count
        let history = try await session.conversationSnapshot()
        let facts = try await journal.auditRecords(matching: .init(runID: run.id))
        let aborted = facts.records.filter { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation && r.settlementSource == .executor }; return false }.count
        let settled = facts.records.filter { if case .result(let r) = $0.fact { return r.kind == .settlement }; return false }.count
        var counts = await counter.values
        counts["enterpriseAuthorization"] = await authorizer.calls
        counts["abort"] = aborted; counts["settlement"] = settled; counts["Receipt"] = result?.receipts.count ?? 0
        var intents = 0
        for callID in ["A", "B"] {
            if try await journal.mutationStatus(sessionID: session.id, runID: run.id, callID: .init(rawValue: callID)) != nil { intents += 1 }
        }
        counts["intent"] = intents
        counts["invocations"] = Set(facts.records.map { $0.links.invocationID }).count
        counts["authorizationApplied"] = facts.records.filter { if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared }; return false }.count
        counts["finalAdmission"] = facts.records.filter { if case .disposition(let d) = $0.fact { return d.state == .runtimeAdmitted }; return false }.count
        counts["pending"] = pending; counts["proof"] = proof == nil ? 0 : 1
        if mode == "corrected" {
            guard counts["executorEntered"] == 2, counts["fileEffects"] == 1, aborted == 1, settled == 1,
                  try String(contentsOf: file, encoding: .utf8) == "written once" else { throw FixtureFailure.badCounts }
        } else {
            guard counts["executorEntered"] == 1, counts["fileEffects"] == 0, pending == 1, proof == nil else { throw FixtureFailure.badCounts }
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == proof,
              try await reopened.latestCheckpoint(sessionID: session.id)?.history == history.messages else { throw FixtureFailure.badRecovery }
        try await reopened.close()
        return counts
    }
}
private enum FixtureFailure: Error { case invalidMode, badCounts, badRecovery, uncertain }
private actor Counter {
    var values = ["providerRequests": 0, "toolAuthorization": 0, "executorEntered": 0, "noEffectConfirmation": 0, "fileEffects": 0]
    func count(_ key: String) -> Int { values[key, default: 0] += 1; return values[key]! }
}
private actor HostAuthorizer: AgentAuthorizer {
    var calls = 0
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        calls += 1
        return .init(request: request, outcome: .allow,
            subject: .init(issuer: "fixture-host", subjectID: "exact-action-rule", type: .automatedPolicy),
            policy: .init(id: "fixture-only", version: "1"), validFor: .seconds(30), reasonCode: "controlled")
    }
}
private struct FixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools])
    let counter: Counter
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await counter.count("providerRequests")
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info))
            if turn < 3 {
                let call = ToolCall(id: .init(rawValue: turn == 1 ? "A" : "B"), name: "controlled_write", argumentsJSON: "{}", completeness: .complete)
                if turn == 2 { guard case .tool(let result)? = request.messages.last, result.isError, result.callID.rawValue == "A" else { throw FixtureFailure.badRecovery } }
                try emit(.toolCallStarted(call.id, name: call.name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else { try emit(.textDelta("done")); try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn))) }
        }
    }
}
private struct ControlledWrite: RuntimeAgentTool {
    let runtimeDefinition = ModelToolDefinition(name: "controlled_write", description: "Controlled temporary file only",
        inputSchema: ToolSchema.object(properties: [:]).json, outputSchema: ToolSchema.string.json)
    var policy: ToolPolicy { try! .mutation(evidence: .none, recoverableErrors: mode == "default" ? .failClosed : .confirmedNoEffect) }
    let file: URL; let counter: Counter; let mode: String
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "fixture", id: "controlled")]) }
    func authorizationBinding(for input: JSONValue) throws -> ToolAuthorizationBinding {
        .init(implementationVersion: "fixture-v1", backend: .init(instanceID: "temporary-file", version: "1", accountID: "fixture", credentialGeneration: "1"))
    }
    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization { _ = await counter.count("toolAuthorization"); return .allowed }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        let attempt = await counter.count("executorEntered")
        if attempt == 1 {
            if mode == "unknown" { throw FixtureFailure.uncertain }
            let confirmation = try context.confirmNoEffect(receipt: .init(operationID: context.idempotencyKey!, status: .failed,
                confirmedTargets: [], failure: .conflict), error: .init(code: "conflict", message: "Version condition refused before any write."),
                wholeOperationHadNoEffect: true, noOutstandingEffects: true, basis: "fixture whole operation: version check before any write")
            _ = await counter.count("noEffectConfirmation")
            throw confirmation
        }
        try Data("written once".utf8).write(to: file); _ = await counter.count("fileEffects")
        return .init(output: .string("written"), receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture", id: "controlled")]))
    }
}
