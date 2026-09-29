import AgentModels
import AgentTools
import Foundation
import Testing

/// Tools defined at runtime, for example from a Host's connector manifest or an MCP server: their
/// name, description and schemas come from the instance, and they are registered, checked, authorized
/// and executed like any other tool.
struct RuntimeAgentToolTests {
    private let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"))

    private func policy(authorization: ToolPolicy.Authorization = .notRequired) throws -> ToolPolicy {
        try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: authorization)
    }

    @Test func aToolDefinedAtRuntimeIsRegisteredUnderItsOwnDefinition() async throws {
        let tool = EchoTool(name: "app_echo", policy: try policy())
        let erased = try AnyAgentTool(tool)
        #expect(erased.definition == tool.definition)
        #expect(erased.definition.name == "app_echo")

        let registry = try ToolRegistry(tools: [erased])
        let call = ToolCall(id: context.callID, name: "app_echo", argumentsJSON: #"{"text":"hi"}"#, completeness: .complete)
        #expect(try await registry.prepare(call, context: context).invoke().output == .object(["echo": .string("hi")]))
    }

    /// One type serves many tools: each instance is its own tool.
    @Test func instancesOfOneTypeAreSeparateTools() async throws {
        let log = EchoLog()
        let registry = try ToolRegistry(tools: [
            AnyAgentTool(EchoTool(name: "app_first", policy: try policy(), log: log)),
            AnyAgentTool(EchoTool(name: "app_second", policy: try policy(), log: log)),
        ])
        #expect(registry.definitions.map(\.name) == ["app_first", "app_second"])
        let call = ToolCall(id: context.callID, name: "app_second", argumentsJSON: #"{"text":"b"}"#, completeness: .complete)
        _ = try await registry.prepare(call, context: context).invoke()
        #expect(await log.names == ["app_second"])
    }

    @Test func argumentsAreCheckedAgainstTheRuntimeSchema() async throws {
        let log = EchoLog()
        let registry = try ToolRegistry(tools: [AnyAgentTool(EchoTool(name: "app_echo", policy: try policy(), log: log))])
        for arguments in [#"{}"#, #"{"text":7}"#, #"{"text":"a","other":1}"#] {
            let call = ToolCall(id: context.callID, name: "app_echo", argumentsJSON: arguments, completeness: .complete)
            await #expect(throws: (any Error).self, "\(arguments)") { try await registry.prepare(call, context: context).invoke() }
        }
        #expect(await log.names.isEmpty)
    }

    @Test func authorizationStillGuardsARuntimeTool() async throws {
        let log = EchoLog()
        let tool = try AnyAgentTool(EchoTool(name: "app_echo", policy: try policy(authorization: .required), log: log, allow: false))
        await #expect(throws: ToolInvocationError.authorizationDenied) {
            try await tool.invoke(arguments: .object(["text": .string("hi")]), context: context)
        }
        #expect(await log.names.isEmpty)
    }

    @Test func aRuntimeToolWithoutANameIsRejected() throws {
        #expect(throws: (any Error).self) { try AnyAgentTool(EchoTool(name: "  ", policy: try policy())) }
    }

    /// A tool declared in code keeps the definition of its type.
    @Test func aStaticToolsDefinitionIsItsTypes() throws {
        let tool = CalculatorTool(policy: try policy())
        #expect(tool.definition == ModelToolDefinition(
            name: CalculatorTool.name, description: CalculatorTool.description,
            inputSchema: CalculatorTool.inputSchema.json, outputSchema: CalculatorTool.outputSchema.json
        ))
        #expect(try AnyAgentTool(tool).definition == tool.definition)
    }

    /// A runtime tool that changes something is admitted under its own name.
    @Test func aRuntimeMutationIsAdmittedUnderItsOwnName() async throws {
        let admission = RecordingAdmission()
        let policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .keyed, timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(EchoTool(name: "app_write", policy: policy))
        let context = ToolContext(
            sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c2"), idempotencyKey: "op-1",
            argumentsJSON: #"{"text":"hi"}"#, mutationAdmission: admission
        )
        // Admitted before it runs; without a Receipt the result itself is refused afterwards.
        await #expect(throws: ToolReceiptError.self) { _ = try await tool.invoke(arguments: .object(["text": .string("hi")]), context: context) }
        #expect(await admission.names == ["app_write"])
    }
}

private actor EchoLog {
    private(set) var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

/// Echoes its text; its name is given when it is made.
private struct EchoTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy
    private let log: EchoLog?
    private let allow: Bool

    init(name: String, policy: ToolPolicy, log: EchoLog? = nil, allow: Bool = true) {
        runtimeDefinition = ModelToolDefinition(
            name: name, description: "Echo the text",
            inputSchema: ToolSchema.object(properties: ["text": .string], required: ["text"]).json,
            outputSchema: ToolSchema.object(properties: ["echo": .string], required: ["echo"]).json
        )
        self.policy = policy
        self.log = log
        self.allow = allow
    }

    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization {
        allow ? .allowed : .denied
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        await log?.add(runtimeDefinition.name)
        guard case .object(let fields) = input, let text = fields["text"] else { throw ToolInvocationError.invalidArguments }
        return ToolResult(output: .object(["echo": text]))
    }
}

private actor RecordingAdmission: ToolMutationAdmission {
    private(set) var names: [String] = []

    func admit(_ request: ToolMutationAdmissionRequest) async throws -> ToolMutationAdmissionResult {
        names.append(request.name)
        return .admitted
    }
}
