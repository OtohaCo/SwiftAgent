import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct NoEffectCapacityAdmissionTests {
    @Test(arguments: ["definition", "binding", "expectation", "input"])
    func staticCapacityIsRejectedBeforeIntentAndExecutor(_ mode: String) async throws {
        let directory = auditTestDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "capacity", supportsConfirmedNoEffect: true)
        let counts = NoEffectCounts()
        let raw = mode == "input" ? "{\"content\":\"" + String(repeating: "x", count: 1_048_576) + "\"}" : "{}"
        let provider = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "A"), name: "capacity", argumentsJSON: raw, completeness: .complete)]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [CapacityTool(mode: mode, counts: counts)]).makeSession(journal: journal)
        let run = try await session.run("refuse")
        await #expect(throws: (any Error).self) { try await run.wait() }; try await run.waitForDrain()
        #expect(await counts.executions == 0)
        #expect(await counts.authorizations == 0)
        #expect(await provider.log.requests.count == 1)
        #expect(try await journal.pendingMutations().isEmpty)
        #expect(try await journal.mutationStatus(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == nil)
        try await journal.close()
    }
}
private struct CapacityTool: RuntimeAgentTool {
    let mode: String; let counts: NoEffectCounts
    var runtimeDefinition: ModelToolDefinition {
        .init(name: "capacity", description: mode == "definition" ? String(repeating: "x", count: 140_000) : "Bounded fixture",
              inputSchema: ToolSchema.object(properties: ["content": .string]).json, outputSchema: ToolSchema.string.json)
    }
    let policy = try! ToolPolicy.mutation(evidence: .none, recoverableErrors: .confirmedNoEffect)
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture", id: "file")], revision: mode == "expectation" ? .exact(String(repeating: "x", count: 140_000)) : .optional)
    }
    func authorizationBinding(for input: JSONValue) throws -> ToolAuthorizationBinding {
        .init(implementationVersion: mode == "binding" ? String(repeating: "x", count: 513) : "1", backend: .init(instanceID: "local", version: "1", accountID: "fixture", credentialGeneration: "1"))
    }
    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization { await counts.authorize(); return .allowed }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        _ = await counts.entered(context)
        throw ToolNoEffectError.unavailable
    }
}
