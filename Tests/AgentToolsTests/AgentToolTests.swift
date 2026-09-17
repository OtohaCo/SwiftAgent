import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentToolTests {
    @Test func toolAuthorUsesTypedSwiftInputAndOutput() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(2), authorization: .notRequired)
        let tool = CalculatorTool(policy: policy)
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "call-1"))
        let result = try await tool.execute(.init(a: 2, b: 3), context: context)
        #expect(result.output.value == 5)
        #expect(CalculatorTool.inputSchema.json == ToolSchema.object(
            properties: ["a": .integer, "b": .integer], required: ["a", "b"]
        ).json)
    }

    @Test func heterogeneousToolsPreserveDefinitionsAndTypedCodingKeys() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(2), authorization: .notRequired)
        let tools = [try AnyAgentTool(CalculatorTool(policy: policy)), try AnyAgentTool(SearchTool(policy: policy))]
        #expect(tools.map(\.definition.name) == ["calculator", "search"])
        #expect(tools[0].definition.inputSchema == CalculatorTool.inputSchema.json)
        #expect(tools[1].definition.outputSchema == SearchTool.outputSchema.json)
        #expect(tools[0].policy == policy)
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"))
        let outputs = try await Task.detached {
            let sum = try await tools[0].invoke(arguments: .object(["a": .number(2), "b": .number(3)]), context: context)
            let search = try await tools[1].invoke(arguments: .object(["query": .string("building")]), context: context)
            return [sum.output, search.output]
        }.value
        #expect(outputs == [.object(["value": .number(5)]), .object(["items": .array([.string("building")])])])
    }

    @Test func emptyToolIdentityIsRejectedAtRegistration() throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1))
        #expect(throws: (any Error).self) { try AnyAgentTool(UnnamedTool(policy: policy)) }
    }

    @Test func executorErrorsSurviveTypeErasure() async throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired)
        let tool = try AnyAgentTool(CalculatorTool(policy: policy))
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "overflow"))
        await #expect(throws: CalculationError.self) {
            try await tool.invoke(arguments: .object(["a": .number(Decimal(Int.max)), "b": .number(1)]), context: context)
        }
    }
}

struct CalculatorTool: AgentTool {
    struct Input: Codable, Sendable { let a: Int; let b: Int }
    struct Output: Codable, Sendable { let value: Int }
    static let name = "calculator"
    static let description = "Add two integers"
    static let inputSchema = ToolSchema.object(properties: ["a": .integer, "b": .integer], required: ["a", "b"])
    static let outputSchema = ToolSchema.object(properties: ["value": .integer], required: ["value"])
    let policy: ToolPolicy

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let (value, overflow) = input.a.addingReportingOverflow(input.b)
        guard !overflow else { throw CalculationError.overflow }
        return ToolResult(output: Output(value: value))
    }
}

enum CalculationError: Error { case overflow }

struct UnnamedTool: AgentTool {
    typealias Input = CalculatorTool.Input
    typealias Output = CalculatorTool.Output
    static let name = " \n"
    static let description = CalculatorTool.description
    static let inputSchema = CalculatorTool.inputSchema
    static let outputSchema = CalculatorTool.outputSchema
    let policy: ToolPolicy
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        try await CalculatorTool(policy: policy).execute(input, context: context)
    }
}

struct SearchTool: AgentTool {
    struct Input: Codable, Sendable {
        let searchTerm: String
        enum CodingKeys: String, CodingKey { case searchTerm = "query" }
    }
    struct Output: Codable, Sendable { let items: [String] }
    static let name = "search"
    static let description = "Search public resources"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(properties: ["items": .array(items: .string)], required: ["items"])
    let policy: ToolPolicy

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(items: [input.searchTerm]))
    }
}
