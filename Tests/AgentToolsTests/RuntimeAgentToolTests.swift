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
            #expect(throws: ToolRegistryError.self, "\(arguments)") {
                do {
                    _ = try registry.prepare(call, context: context)
                } catch let error as ToolRegistryError {
                    guard case .invalidArguments = error else { throw TestFailure.wrongError("\(error)") }
                    throw error
                }
            }
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

    /// A name that comes from the instance is one every model API accepts: letters, digits, "_" and
    /// "-", at most 64. Tools named in code keep whatever names they had.
    @Test func aRuntimeNameMustBePortable() throws {
        for name in ["", "  ", " app_echo", "app.echo", "app echo", "app\necho", "应用", String(repeating: "a", count: 65)] {
            #expect(throws: ToolInvocationError.invalidDefinition, "\(name)") { try AnyAgentTool(EchoTool(name: name, policy: try policy())) }
        }
        for name in ["a", "app_echo-2", String(repeating: "a", count: 64)] {
            #expect(try AnyAgentTool(EchoTool(name: name, policy: try policy())).definition.name == name)
        }
    }

    @Test func twoRuntimeToolsCannotShareAName() throws {
        let tool = try AnyAgentTool(EchoTool(name: "app_echo", policy: try policy()))
        let twin = try AnyAgentTool(EchoTool(name: "app_echo", policy: try policy()))
        #expect(throws: ToolRegistryError.duplicateName("app_echo")) { try ToolRegistry(tools: [tool, twin]) }
    }

    /// What a runtime tool answers is checked against its definition's output schema.
    @Test func outputIsCheckedAgainstTheRuntimeSchema() async throws {
        let registry = try ToolRegistry(tools: [AnyAgentTool(EchoTool(name: "app_echo", policy: try policy(), answer: .object(["other": .string("x")])))])
        let call = ToolCall(id: context.callID, name: "app_echo", argumentsJSON: #"{"text":"hi"}"#, completeness: .complete)
        do {
            _ = try await registry.prepare(call, context: context).invoke()
            Issue.record("an answer outside the schema was accepted")
        } catch let error as ToolRegistryError {
            guard case .invalidOutput = error else { Issue.record("\(error)"); return }
        }
    }

    /// A definition without an output schema cannot be registered.
    @Test func aRuntimeToolNeedsAnOutputSchema() throws {
        let tool = try AnyAgentTool(EchoTool(name: "app_echo", policy: try policy(), outputSchema: nil))
        do {
            _ = try ToolRegistry(tools: [tool])
            Issue.record("a tool without an output schema was registered")
        } catch let error as ToolRegistryError {
            guard case .invalidSchema(tool: "app_echo", _) = error else { Issue.record("\(error)"); return }
        }
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

    private let answer: JSONValue?

    init(
        name: String, policy: ToolPolicy, log: EchoLog? = nil, allow: Bool = true, answer: JSONValue? = nil,
        outputSchema: JSONValue? = ToolSchema.object(properties: ["echo": .string], required: ["echo"]).json
    ) {
        runtimeDefinition = ModelToolDefinition(
            name: name, description: "Echo the text",
            inputSchema: ToolSchema.object(properties: ["text": .string], required: ["text"]).json,
            outputSchema: outputSchema
        )
        self.policy = policy
        self.log = log
        self.allow = allow
        self.answer = answer
    }

    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization {
        allow ? .allowed : .denied
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        await log?.add(runtimeDefinition.name)
        guard case .object(let fields) = input, let text = fields["text"] else { throw ToolInvocationError.invalidArguments }
        return ToolResult(output: answer ?? .object(["echo": text]))
    }
}

private actor RecordingAdmission: ToolMutationAdmission {
    private(set) var names: [String] = []

    func admit(_ request: ToolMutationAdmissionRequest) async throws -> ToolMutationAdmissionResult {
        names.append(request.name)
        return .admitted
    }
}

private enum TestFailure: Error {
    case wrongError(String)
}
