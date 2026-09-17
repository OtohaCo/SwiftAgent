import AgentModels
import AgentTools
import Foundation
import Testing

struct ToolRegistryTests {
    private let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"))

    @Test func registrationAndPreparationPreserveTypedToolExecution() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(CalculatorTool(policy: policy))
        let registry = try ToolRegistry(tools: [tool])
        #expect(registry.definitions == [tool.definition])
        let call = ToolCall(id: context.callID, name: "calculator", argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
        let prepared = try registry.prepare(call, context: context)
        #expect(prepared.call == call)
        #expect(prepared.policy == policy)
        #expect(try await prepared.invoke().output == .object(["value": .number(5)]))
    }

    @Test func duplicateNamesCannotSilentlyReplaceRegisteredTools() throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        let tool = try AnyAgentTool(CalculatorTool(policy: policy))
        #expect(throws: (any Error).self) { try ToolRegistry(tools: [tool, tool]) }
    }

    @Test func rejectedCallShapesNeverReachExecutor() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let registry = try ToolRegistry(tools: [AnyAgentTool(RecordingTool(policy: policy, log: log))])
        let cases: [ToolCall] = [
            .init(id: context.callID, name: "recording", argumentsJSON: #"{"value":7}"#),
            .init(id: context.callID, name: "unknown", argumentsJSON: #"{"value":7}"#, completeness: .complete),
            .init(id: .init(rawValue: "wrong"), name: "recording", argumentsJSON: #"{"value":7}"#, completeness: .complete),
            .init(id: context.callID, name: "recording", argumentsJSON: #"{"value":7,}"#, completeness: .complete),
            .init(id: context.callID, name: "recording", argumentsJSON: #"{"value":7,"items":[1,]}"#, completeness: .complete),
            .init(id: context.callID, name: "recording", argumentsJSON: #"{"value":8,"value":7}"#, completeness: .complete),
            .init(id: context.callID, name: "recording", argumentsJSON: #"{"value":8,"\u0076alue":7}"#, completeness: .complete),
        ]
        for call in cases {
            await #expect(throws: (any Error).self) { try await registry.prepare(call, context: context).invoke() }
        }
        #expect(await log.contexts.isEmpty)
    }

    @Test func schemaRejectsArgumentsEvenWhenCodableWouldAcceptThem() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let registry = try ToolRegistry(tools: [AnyAgentTool(ConstrainedTool(policy: policy, log: log))])
        for raw in ["{}", #"{"count":null}"#, #"{"count":true}"#, #"{"count":1.5}"#,
                    #"{"count":0}"#, #"{"count":26}"#, #"{"count":2,"extra":1}"#] {
            let call = ToolCall(id: context.callID, name: "constrained", argumentsJSON: raw, completeness: .complete)
            await #expect(throws: (any Error).self) { try await registry.prepare(call, context: context).invoke() }
        }
        #expect(await log.contexts.isEmpty)
    }

    @Test func invalidOutputCannotEscapeAsAValidToolResult() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = ConstrainedTool(policy: policy, log: log, output: .object(["value": .string("wrong")]))
        let registry = try ToolRegistry(tools: [AnyAgentTool(tool)])
        let call = ToolCall(id: context.callID, name: "constrained", argumentsJSON: #"{"count":2}"#, completeness: .complete)
        await #expect(throws: (any Error).self) { try await registry.prepare(call, context: context).invoke() }
        #expect(await log.contexts == [context])
    }

    @Test func unsupportedSchemaIsRejectedAtRegistration() throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        #expect(throws: (any Error).self) { try ToolRegistry(tools: [AnyAgentTool(UnsupportedTool(policy: policy))]) }
    }

    @Test func preparationDoesNotBypassAuthorizationOrMutationIntegrity() async throws {
        let log = InvocationLog()
        let required = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        let mutation = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt, timeout: .seconds(1))
        for (policy, error) in [(required, ToolInvocationError.authorizationDenied), (mutation, .mutationIntegrityUnavailable)] {
            let registry = try ToolRegistry(tools: [AnyAgentTool(RecordingTool(policy: policy, log: log))])
            let call = ToolCall(id: context.callID, name: "recording", argumentsJSON: #"{"value":7}"#, completeness: .complete)
            let prepared = try registry.prepare(call, context: context)
            await #expect(throws: error) { try await prepared.invoke() }
        }
        #expect(await log.contexts.isEmpty)
    }

    @Test func queuedPreparedCallRechecksDeadline() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let registry = try ToolRegistry(tools: [AnyAgentTool(RecordingTool(policy: policy, log: log))])
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        let limited = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: context.callID, deadline: deadline)
        let call = ToolCall(id: context.callID, name: "recording", argumentsJSON: #"{"value":7}"#, completeness: .complete)
        let prepared = try registry.prepare(call, context: limited)
        try await ContinuousClock().sleep(until: deadline)
        await #expect(throws: ToolInvocationError.deadlineExceeded) {
            try await prepared.invoke(deadline: .now.advanced(by: .seconds(30)))
        }
        #expect(await log.contexts.isEmpty)
    }

    @Test func diagnosticsDistinguishInputAndOutputSchemaFailures() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let registry = try ToolRegistry(tools: [AnyAgentTool(ConstrainedTool(
            policy: policy, log: InvocationLog(), output: .object(["value": .string("bad")])
        ))])
        let badInput = ToolCall(id: context.callID, name: "constrained", argumentsJSON: #"{"count":0}"#, completeness: .complete)
        do {
            _ = try registry.prepare(badInput, context: context)
            Issue.record("Invalid arguments accepted")
        } catch ToolRegistryError.invalidArguments(let issue) {
            #expect(issue.path == "/count")
            #expect(issue.keyword == "minimum")
        }
        let validInput = ToolCall(id: context.callID, name: "constrained", argumentsJSON: #"{"count":2}"#, completeness: .complete)
        do {
            _ = try await registry.prepare(validInput, context: context).invoke()
            Issue.record("Invalid output accepted")
        } catch ToolRegistryError.invalidOutput(let issue) {
            #expect(issue.path == "/value")
            #expect(issue.keyword == "type")
        }
    }

    @Test func preparedInvocationStillPropagatesCancellationAndAuthorizationErrors() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        let registry = try ToolRegistry(tools: [AnyAgentTool(ControlledTool(base: RecordingTool(policy: policy, log: log)) { _, _ in
            throw AuthorizationFailure.unavailable
        })])
        let call = ToolCall(id: context.callID, name: "controlled", argumentsJSON: #"{"value":7}"#, completeness: .complete)
        let prepared = try registry.prepare(call, context: context)
        await #expect(throws: AuthorizationFailure.self) { try await prepared.invoke() }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let task = Task {
            for await _ in gate.stream {}
            return try await prepared.invoke()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await log.contexts.isEmpty)
    }

    @Test func malformedOutputSchemaIsRejectedBeforeRegistrationCompletes() throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        do {
            _ = try ToolRegistry(tools: [AnyAgentTool(BadOutputSchemaTool(policy: policy))])
            Issue.record("Malformed output schema accepted")
        } catch ToolRegistryError.invalidSchema(let tool, let issue) {
            #expect(tool == "bad-output-schema")
            #expect(issue.kind == .invalidSchema)
            #expect(issue.path == "/items")
        }
    }

    @Test func toolNamesAndCallIDsAreOpaqueAndRequireExactMatching() async throws {
        let log = InvocationLog()
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let registry = try ToolRegistry(tools: [AnyAgentTool(AccentedTool(policy: policy, log: log))])
        let exact = ToolContext(sessionID: context.sessionID, runID: context.runID, callID: .init(rawValue: "\u{E9}"))
        for call in [
            ToolCall(id: exact.callID, name: "cafe\u{301}", argumentsJSON: #"{"value":7}"#, completeness: .complete),
            ToolCall(id: .init(rawValue: "e\u{301}"), name: AccentedTool.name, argumentsJSON: #"{"value":7}"#, completeness: .complete),
        ] {
            await #expect(throws: (any Error).self) { try await registry.prepare(call, context: exact).invoke() }
        }
        #expect(await log.contexts.isEmpty)
    }
}

struct ConstrainedTool: AgentTool {
    typealias Input = [String: JSONValue]
    typealias Output = JSONValue
    static let name = "constrained"
    static let description = "Read resource count"
    static let inputSchema = ToolSchema.object(properties: ["count": .init(json: .object([
        "type": .string("integer"), "minimum": .number(1), "maximum": .number(25),
    ]))], required: ["count"])
    static let outputSchema = ToolSchema.object(properties: ["value": .integer], required: ["value"])
    let policy: ToolPolicy
    let log: InvocationLog
    var output: JSONValue = .object(["value": .number(7)])
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(context)
        return ToolResult(output: output)
    }
}

struct UnsupportedTool: AgentTool {
    typealias Input = String
    typealias Output = String
    static let name = "unsupported"
    static let description = "Unsupported pattern schema"
    static let inputSchema = ToolSchema(json: .object(["pattern": .string("^value$")]))
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { ToolResult(output: input) }
}

struct BadOutputSchemaTool: AgentTool {
    typealias Input = CalculatorTool.Input
    typealias Output = CalculatorTool.Output
    static let name = "bad-output-schema"
    static let description = CalculatorTool.description
    static let inputSchema = CalculatorTool.inputSchema
    static let outputSchema = ToolSchema(json: .object(["items": .string("wrong")]))
    let policy: ToolPolicy
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try await CalculatorTool(policy: policy).execute(input, context: context)
    }
}

struct AccentedTool: AgentTool {
    typealias Input = RecordingTool.Input
    typealias Output = RecordingTool.Output
    static let name = "caf\u{E9}"
    static let description = RecordingTool.description
    static let inputSchema = RecordingTool.inputSchema
    static let outputSchema = RecordingTool.outputSchema
    let policy: ToolPolicy
    let log: InvocationLog
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try await RecordingTool(policy: policy, log: log).execute(input, context: context)
    }
}
