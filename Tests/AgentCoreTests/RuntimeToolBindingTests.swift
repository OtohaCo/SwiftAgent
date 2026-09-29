import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

/// Tools defined at runtime through the Agent and a Run's capability binding: each is known by its
/// definition's name, and the model is offered that definition.
struct RuntimeToolBindingTests {
    private func readOnly() throws -> ToolPolicy {
        try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: .notRequired)
    }

    @Test func aBindingNamesEachRuntimeToolByItsDefinition() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "apps", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: [
                AgentCapabilityTool(id: "cap_record", version: "1", tool: NamedTool("cap_record", policy: try readOnly())),
                AgentCapabilityTool(id: "cap_export", version: "1", tool: NamedTool("cap_export", policy: try readOnly())),
            ])
        #expect(binding.info.tools.map(\.name) == ["cap_export", "cap_record"])

        _ = try await session.run("go", capabilities: binding).wait()
        #expect(await provider.log.requests.first?.tools.map(\.name).sorted() == ["cap_export", "cap_record"])
    }

    @Test func aRuntimeToolTakingAStaticToolsNameIsRefused() async throws {
        let session = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "done") }).makeSession()
        await #expect(throws: AgentCapabilityError.duplicateToolName) {
            _ = try await session.bindCapabilities(identity: "apps", version: "1", backendInstanceID: "fixture",
                backendVersion: "1", allowedResources: [.global], tools: [
                    AgentCapabilityTool(id: "static", version: "1", tool: StaticTool(policy: try readOnly())),
                    AgentCapabilityTool(id: "runtime", version: "1", tool: NamedTool(StaticTool.name, policy: try readOnly())),
                ])
        }
    }

    /// The model is offered the runtime definition, and a call by that name reaches the tool.
    @Test func theModelIsOfferedTheRuntimeDefinitionAndCallsIt() async throws {
        let tool = NamedTool("app_echo", policy: try readOnly())
        let provider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [ToolCall(id: .init(rawValue: "call-1"), name: "app_echo", argumentsJSON: #"{"text":"hi"}"#, completeness: .complete)])
                : textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [tool]).makeSession()

        _ = try await session.run("go", budget: try testBudget()).wait()

        let requests = await provider.log.requests
        #expect(requests.first?.tools == [tool.runtimeDefinition])
        #expect(requests.count == 2, "the tool's answer went back to the model")
    }
}

/// A tool named when it is made.
private struct NamedTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy

    init(_ name: String, policy: ToolPolicy) {
        runtimeDefinition = ModelToolDefinition(
            name: name, description: "Echo",
            inputSchema: ToolSchema.object(properties: ["text": .string], required: ["text"]).json,
            outputSchema: ToolSchema.object(properties: ["echo": .string], required: ["echo"]).json
        )
        self.policy = policy
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        guard case .object(let fields) = input, let text = fields["text"] else { throw ToolInvocationError.invalidArguments }
        return ToolResult(output: .object(["echo": text]))
    }
}

private struct StaticTool: AgentTool {
    struct Input: Codable, Sendable { let text: String }
    struct Output: Codable, Sendable { let echo: String }
    static let name = "static_echo"
    static let description = "Echo"
    static let inputSchema = ToolSchema.object(properties: ["text": .string], required: ["text"])
    static let outputSchema = ToolSchema.object(properties: ["echo": .string], required: ["echo"])
    let policy: ToolPolicy

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(echo: input.text))
    }
}
