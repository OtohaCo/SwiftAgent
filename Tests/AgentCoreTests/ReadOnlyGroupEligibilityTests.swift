import Testing
import Foundation
import AgentModels
import AgentTools
@testable import AgentCore
import AgentJournalFileStore

@Suite struct ReadOnlyGroupEligibilityTests {
    // Deliberately constructed projector inputs, separate from SDK execution below.
    @Test(arguments: [false, true]) func unprovedFailedOrMixedGroupIsNeverRemoved(mixed: Bool) async throws {
        let failed = ToolCall(id: .init(rawValue: "failed"), name: mixed ? "search" : "write", argumentsJSON: "{}", completeness: .complete)
        let write = ToolCall(id: .init(rawValue: "write"), name: "write", argumentsJSON: "{}", completeness: .complete)
        let resolved = ToolCall(id: .init(rawValue: "resolved"), name: mixed ? "search" : "write", argumentsJSON: "{}", completeness: .complete)
        let failure = ToolResultMessage(callID: failed.id, content: [.text("error")], isError: true)
        let success = ToolResultMessage(callID: resolved.id, content: [.text("found")], isError: false)
        var messages: [ModelMessage] = [.user([.text("search")]), .assistant(content: [], toolCalls: mixed ? [failed, write] : [failed]), .tool(failure)]
        if mixed { messages.append(.tool(.init(callID: write.id, content: [.text("written")], isError: false))) }
        messages += [.assistant(content: [], toolCalls: [resolved]), .tool(success), .user([.text("next")])]
        var proofs: [ToolCallID: AgentContextVerifiedReadOnlyResult] = [:]
        if mixed { // Even genuine anchor proofs cannot certify the mutation sibling.
            proofs[failed.id] = .init(toolName: failed.name, sourceDigest: try AgentContextProjectionSource.digest(messages: [.tool(failure)]))
            proofs[resolved.id] = .init(toolName: resolved.name, sourceDigest: try AgentContextProjectionSource.digest(messages: [.tool(success)]))
        }
        let input = AgentContextProjectionInput(canonicalMessages: messages, model: fixtureModel,
            sessionID: UUID(), runID: UUID(), conversationRevision: 1, contextEpoch: 1, modelTurn: 1,
            verifiedReadOnlyResults: proofs)
        await #expect(throws: AgentContextProjectionError.unresolvedReadOnlySpan(failed.id)) {
            try await AgentResolvedReadOnlyToolProjector(spans: [.init(failedCallID: failed.id, resolvedByCallID: resolved.id, summary: "resolved")]).project(input)
        }
        #expect(try await AgentResolvedReadOnlyToolProjector(spans: []).project(input).messages == messages)
    }
    @Test(arguments: [false, true]) func actualSessionRepairPreservesMutationSiblingAndRestoredHistory(mixed: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("readonly-group-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("effect")
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "readonly-group")
        let failed = ToolCall(id: .init(rawValue: "failed"), name: "search", argumentsJSON: #"{"missing":true}"#, completeness: .complete)
        let resolved = ToolCall(id: .init(rawValue: "resolved"), name: "search", argumentsJSON: #"{"missing":false}"#, completeness: .complete)
        let write = ToolCall(id: .init(rawValue: "write"), name: "write", argumentsJSON: "{}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, mixed ? [failed, write] : [failed])
            case 2: return toolResponse(request, [resolved])
            default: return textResponse(request, "done")
            }
        }
        var tools: [any AgentTool] = [try GroupSearch()]
        if mixed { tools.append(try GroupWrite(file: file)) }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: tools)
        let session = try agent.makeSession(journal: journal)
        let first = try await session.run("search and write", budget: testBudget(), operationID: "group-operation")
        let result = try await first.wait()
        try await first.waitForDrain()
        let canonical = try await session.conversationSnapshot().messages
        #expect(result.receipts.count == (mixed ? 1 : 0))
        if mixed {
            #expect(try String(contentsOf: file, encoding: .utf8) == "effect")
            let receipt = try #require(result.receipts.first).receipt
            #expect(try await journal.mutationStatus(identity: receipt.operationID)?.receipt == receipt)
        }
        let projector = AgentResolvedReadOnlyToolProjector(spans: [.init(failedCallID: failed.id, resolvedByCallID: resolved.id, summary: "specific search succeeded")])
        let binding = try AgentModelBinding(profileID: "repair", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: .init(serviceInstanceID: "local", endpointScope: "fixture", apiDialect: "fixture"),
            projector: projector)
        if !mixed {
            let missingRequirements = try AgentModelBinding(profileID: "opaque-wrapper", profileRevision: "1", model: fixtureModel,
                provider: provider, deployment: .init(serviceInstanceID: "local", endpointScope: "fixture", apiDialect: "fixture"),
                projector: GroupWrapper(wrapped: projector, forward: false))
            await #expect(throws: AgentContextProjectionError.unresolvedReadOnlySpan(failed.id)) {
                try await session.run("missing forwarding", using: missingRequirements)
            }
        }
        let forwarded = try AgentModelBinding(profileID: "forwarded", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: .init(serviceInstanceID: "local", endpointScope: "fixture", apiDialect: "fixture"),
            projector: GroupWrapper(wrapped: projector, forward: true))
        if mixed {
            await #expect(throws: AgentContextProjectionError.unresolvedReadOnlySpan(failed.id)) {
                try await session.run("next", using: forwarded)
            }
            #expect(try await session.conversationSnapshot().messages == canonical)
            #expect(await provider.log.requests.count == 3)
        } else {
            let next = try await session.run("next", using: forwarded)
            _ = try await next.wait(); try await next.waitForDrain()
            let sent = try #require(await provider.log.requests.last)
            #expect(!sent.messages.contains { if case .assistant(_, let calls) = $0 { return calls.contains(failed) }; return false })
            #expect(try await session.conversationSnapshot().messages.contains(canonical[1]))
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        // Current tool policy cannot recreate process-local historical execution proof.
        let restored = try agent.makeSession(id: session.id, journal: reopened)
        await #expect(throws: AgentContextProjectionError.unresolvedReadOnlySpan(failed.id)) {
            try await restored.run("restored", using: binding)
        }
        let other = try agent.makeSession(journal: reopened)
        await #expect(throws: AgentContextProjectionError.unresolvedReadOnlySpan(failed.id)) {
            try await other.run("other Session", using: binding)
        }
        try await reopened.close()
    }

}

private struct GroupSearch: AgentTool {
    struct Input: Codable, Sendable { let missing: Bool }
    typealias Output = String
    static let name = "search"
    static let description = "Controlled recoverable read"
    static let inputSchema = ToolSchema.object(properties: ["missing": .boolean], required: ["missing"])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    init() throws { policy = try .readOnly(authorization: .notRequired, recoverableErrors: .modelVisible) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        if input.missing { throw try RecoverableToolError(code: "missing", message: "Try a specific search") }
        return .init(output: "found")
    }
}
private struct GroupWrite: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "write"
    static let description = "Controlled temporary file mutation"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let file: URL
    let policy: ToolPolicy
    init(file: URL) throws { self.file = file; policy = try .mutation(authorization: .notRequired, evidence: .none) }
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "fixture", id: "file"))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "fixture", id: "file")], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        try Data("effect".utf8).write(to: file)
        return .init(output: "written", receipt: .init(operationID: context.idempotencyKey ?? "", status: .succeeded, confirmedTargets: [.init(namespace: "fixture", id: "file")], revision: "1"))
    }
}

private struct GroupWrapper: AgentContextReadOnlyGroupReferencing {
    let wrapped: AgentResolvedReadOnlyToolProjector
    let forward: Bool
    var readOnlyGroupCallIDs: [ToolCallID] { forward ? wrapped.readOnlyGroupCallIDs : [] }
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection { try await wrapped.project(input) }
}
