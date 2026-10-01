import AgentModels
import AgentTools
import Foundation
import Testing

/// A registry can hold tools that are callable once declared to the model but not declared from the
/// start ("deferred"). A tool result can name deferred tools to declare from the next model request on.
struct ToolDeclarationTests {
    private let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"))

    private func policy() throws -> ToolPolicy {
        try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: .notRequired)
    }

    private func registry(declaring declared: [String] = []) throws -> ToolRegistry {
        try ToolRegistry(tools: [
            AnyAgentTool(DeclaringTool(name: "find_tools", policy: try policy(), declares: declared)),
            AnyAgentTool(DeclaringTool(name: "web_fetch", policy: try policy())),
            AnyAgentTool(DeclaringTool(name: "web_search", policy: try policy())),
        ], deferred: ["web_fetch", "web_search"])
    }

    private func call(_ name: String) -> ToolCall {
        ToolCall(id: context.callID, name: name, argumentsJSON: #"{"text":"x"}"#, completeness: .complete)
    }

    @Test func onlyToolsThatAreNotDeferredAreDeclaredFromTheStart() throws {
        let registry = try registry()
        #expect(registry.initiallyDeclaredNames == ["find_tools"])
        #expect(registry.definitions(declared: registry.initiallyDeclaredNames).map(\.name) == ["find_tools"])
        #expect(registry.definitions(declared: ["find_tools", "web_fetch"]).map(\.name) == ["find_tools", "web_fetch"])
        #expect(registry.definitions.map(\.name) == ["find_tools", "web_fetch", "web_search"], "every registered tool")
    }

    @Test func aRegistryWithoutDeferredToolsDeclaresEveryTool() throws {
        let registry = try ToolRegistry(tools: [AnyAgentTool(DeclaringTool(name: "web_fetch", policy: try policy()))])
        #expect(registry.initiallyDeclaredNames == ["web_fetch"])
    }

    @Test func deferringAToolThatIsNotRegisteredIsRefused() throws {
        #expect(throws: ToolRegistryError.unknownTool("missing")) {
            try ToolRegistry(tools: [AnyAgentTool(DeclaringTool(name: "web_fetch", policy: try policy()))], deferred: ["missing"])
        }
    }

    /// Not declared is not callable: the call is refused exactly as one naming no registered tool.
    @Test func aCallToAToolThatIsNotDeclaredIsRefusedAsAnUnknownTool() throws {
        let registry = try registry()
        #expect(throws: ToolRegistryError.unknownTool("web_fetch")) {
            _ = try registry.prepare(call("web_fetch"), context: context, declared: registry.initiallyDeclaredNames)
        }
        #expect(throws: ToolRegistryError.unknownTool("nowhere")) {
            _ = try registry.prepare(call("nowhere"), context: context, declared: registry.initiallyDeclaredNames)
        }
        #expect(throws: ToolRegistryError.unknownTool("web_fetch"), "without a declared set, only the initial one") {
            _ = try registry.prepare(call("web_fetch"), context: context)
        }
        _ = try registry.prepare(call("web_fetch"), context: context, declared: ["find_tools", "web_fetch"])
    }

    @Test func aToolResultCarriesTheToolsItDeclares() async throws {
        let registry = try registry(declaring: ["web_fetch"])
        let result = try await registry.prepare(call("find_tools"), context: context,
                                                declared: registry.initiallyDeclaredNames).invoke()
        #expect(result.declaredTools == ["web_fetch"])
    }

    @Test func aToolResultDeclaringAnUnregisteredToolFails() async throws {
        let registry = try registry(declaring: ["web_fetch", "missing"])
        let prepared = try registry.prepare(call("find_tools"), context: context, declared: registry.initiallyDeclaredNames)
        await #expect(throws: ToolRegistryError.unknownTool("missing")) { _ = try await prepared.invoke() }
    }

    /// Names match exactly, as calls do: a canonically equivalent spelling is another name.
    @Test func declaredNamesMatchExactly() async throws {
        let decomposed = "cafe\u{301}", composed = "caf\u{E9}"
        let registry = try ToolRegistry(tools: [
            AnyAgentTool(DeclaringTool(name: "find_tools", policy: try policy(), declares: [decomposed])),
            AnyAgentTool(AccentedDeclaredTool(policy: try policy())),
        ], deferred: [composed])
        let prepared = try registry.prepare(call("find_tools"), context: context, declared: registry.initiallyDeclaredNames)
        await #expect(throws: ToolRegistryError.unknownTool(decomposed)) { _ = try await prepared.invoke() }
    }
}

/// Echoes its text and declares the tools it was made with.
private struct DeclaringTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy
    let declares: [String]

    init(name: String, policy: ToolPolicy, declares: [String] = []) {
        runtimeDefinition = ModelToolDefinition(
            name: name, description: "Echo",
            inputSchema: ToolSchema.object(properties: ["text": .string], required: ["text"]).json,
            outputSchema: ToolSchema.object(properties: ["echo": .string], required: ["echo"]).json
        )
        self.policy = policy
        self.declares = declares
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        guard case .object(let fields) = input, let text = fields["text"] else { throw ToolInvocationError.invalidArguments }
        return ToolResult(output: .object(["echo": text]), declaredTools: declares)
    }
}

/// A tool named in code with a composed accent.
private struct AccentedDeclaredTool: AgentTool {
    struct Input: Codable, Sendable { let text: String }
    struct Output: Codable, Sendable { let echo: String }
    static let name = "caf\u{E9}"
    static let description = "Echo"
    static let inputSchema = ToolSchema.object(properties: ["text": .string], required: ["text"])
    static let outputSchema = ToolSchema.object(properties: ["echo": .string], required: ["echo"])
    let policy: ToolPolicy

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(echo: input.text))
    }
}
