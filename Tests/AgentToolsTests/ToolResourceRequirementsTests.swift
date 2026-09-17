import AgentModels
import AgentTools
import Foundation
import Testing

struct ToolResourceRequirementsTests {
    @Test func preparedCallBindsResourcesFromValidatedTypedInput() throws {
        let registry = try ToolRegistry(tools: [AnyAgentTool(ResourceSelector())])
        let call = ToolCall(id: .init(rawValue: "call"), name: ResourceSelector.name,
                            argumentsJSON: #"{"id":"drawing-1"}"#, completeness: .complete)
        let prepared = try registry.prepare(call, context: .init(sessionID: UUID(), runID: UUID(), callID: call.id))
        #expect(prepared.resources == [.named(.init(namespace: "document", id: "drawing-1"))])
    }

    @Test func invalidResourceDeclarationsFailDuringPreparation() throws {
        let invalid = EvidenceReference(namespace: "document", id: " ")
        for (resources, expected) in [([ToolResource](), ToolResourceError.empty),
                                       ([.global, .global], .duplicate), ([.named(invalid)], .invalidReference(invalid))] {
            let registry = try ToolRegistry(tools: [AnyAgentTool(ResourceSelector(override: resources))])
            let call = ToolCall(id: .init(rawValue: "call"), name: ResourceSelector.name,
                                argumentsJSON: #"{"id":"drawing-1"}"#, completeness: .complete)
            #expect(throws: expected) { try registry.prepare(call, context: .init(sessionID: UUID(), runID: UUID(), callID: call.id)) }
        }
    }
}

private struct ResourceSelector: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "resource_selector"
    static let description = "Read a document"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let override: [ToolResource]?
    init(override: [ToolResource]? = nil) throws {
        self.override = override
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: .notRequired)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        override ?? [.named(.init(namespace: "document", id: input.id))]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { .init(output: input.id) }
}
