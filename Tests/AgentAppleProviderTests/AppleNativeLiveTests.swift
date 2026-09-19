#if canImport(FoundationModels)
import AgentCore
import AgentModels
import AgentTools
import AgentAppleProvider
import Foundation
import FoundationModels
import Testing

@Suite(.serialized)
struct AppleNativeLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_AGENT_APPLE_LIVE"] == "1"))
    func truncatedNativeGenerationCannotExecuteAPartialToolPlan() async throws {
        if #available(macOS 26, iOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw ModelProviderError(kind: .unavailable, message: "Opted-in Apple model is unavailable.")
            }
            let log = CalculatorLog()
            let provider = try AppleFoundationProvider(maximumResponseTokens: 1)
            let agent = try Agent(
                model: AppleFoundationProvider.modelID,
                provider: provider,
                tools: [LiveCalculator(log: log)],
                configuration: AgentConfiguration(
                    instructions: "Use calculator for arithmetic. Never invent the result.",
                    runTimeout: .seconds(30)
                )
            )
            let run = try await agent.makeSession().run("Use calculator to add 19 and 23.")
            var completed = 0
            for await event in run.events {
                if case .model(.toolCallCompleted) = event { completed += 1 }
                if case .model(.responseCompleted) = event { completed += 1 }
            }
            do {
                _ = try await run.wait()
                Issue.record("A one-token partial plan must not complete")
            } catch { #expect((error as? ModelProviderError)?.kind == .invalidResponse) }
            #expect(completed == 0)
            #expect(await log.inputs.isEmpty)
        } else {
            throw ModelProviderError(kind: .unavailable, message: "Apple live proof requires a supported OS.")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_AGENT_APPLE_LIVE"] == "1"))
    func actualModelProposesCalculatorAndReceivesOnlyCoreExecutedResult() async throws {
        if #available(macOS 26, iOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw ModelProviderError(kind: .unavailable, message: "Opted-in Apple model is unavailable.")
            }
            let log = CalculatorLog()
            let provider = try AppleFoundationProvider(maximumResponseTokens: 1_024)
            let agent = try Agent(
                model: AppleFoundationProvider.modelID,
                provider: provider,
                tools: [LiveCalculator(log: log)],
                configuration: AgentConfiguration(
                    instructions: "Always use calculator exactly once for arithmetic. Never calculate yourself. After receiving its result, answer with that number and do not call it again.",
                    maxModelTurns: 3,
                    maxToolCalls: 1,
                    runTimeout: .seconds(90)
                )
            )
            let run = try await agent.makeSession().run("Use calculator to add 19 and 23, then tell me the result.")
            var phases: [String] = []
            for await event in run.events {
                switch event {
                case .turnStarted: phases.append("model")
                case .toolStarted: phases.append("toolStarted")
                case .toolCompleted: phases.append("toolCompleted")
                case .runFinished(.result): phases.append("result")
                default: break
                }
            }
            print("Apple live trace: \(phases.joined(separator: " -> ")); Core calculator calls: \(await log.inputs.count)")
            let result = try await run.wait()
            #expect(result.outcome == .completed)
            #expect(result.modelTurns == 2)
            #expect(result.toolCalls == 1)
            #if compiler(>=6.4)
            if #available(macOS 27, iOS 27, *) {
                #expect((result.response.usage.inputTokens ?? 0) > 0)
                #expect((result.response.usage.outputTokens ?? 0) > 0)
                #expect(result.response.usage.cachedInputTokens != nil)
                #expect(result.response.usage.reasoningTokens != nil)
            }
            #endif
            #expect(await log.inputs == [[19, 23]])
            #expect(phases == ["model", "toolStarted", "toolCompleted", "model", "result"])
            #expect(result.history.contains { message in
                if case .tool(let output) = message { return output.content == [.json(.object(["result": .number(42)]))] }
                return false
            })
            #expect(result.response.content.contains { if case .text(let text) = $0 { text.contains("42") } else { false } })
            print("Apple live proof: \(phases.joined(separator: " -> ")); Core calculator calls: \(await log.inputs.count)")
        } else {
            throw ModelProviderError(kind: .unavailable, message: "Apple live proof requires a supported OS.")
        }
    }

    #if compiler(>=6.4)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_AGENT_APPLE_PCC_LIVE"] == "1"))
    func privateCloudModelProposesCalculatorWithoutOwningToolExecution() async throws {
        if #available(macOS 27, iOS 27, *) {
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                throw ModelProviderError(kind: .unavailable, message: "Opted-in Apple PCC model is unavailable.")
            }
            let log = CalculatorLog()
            let provider = try AppleFoundationProvider.privateCloudCompute(maximumResponseTokens: 1_024)
            let agent = try Agent(
                model: AppleFoundationProvider.privateCloudComputeModelID,
                provider: provider,
                tools: [LiveCalculator(log: log)],
                configuration: AgentConfiguration(
                    instructions: "Always use calculator exactly once for arithmetic, then answer from its real result.",
                    maxModelTurns: 3,
                    maxToolCalls: 1,
                    runTimeout: .seconds(90)
                )
            )
            let run = try await agent.makeSession().run("Use calculator to add 19 and 23, then tell me the result.")
            for await _ in run.events {}
            let result = try await run.wait()
            #expect(result.outcome == .completed)
            #expect(result.modelTurns == 2)
            #expect(result.toolCalls == 1)
            #expect(await log.inputs == [[19, 23]])
            #expect(result.response.content.contains { content in
                if case .text(let text) = content { return text.contains("42") }
                return false
            })
        } else {
            throw ModelProviderError(kind: .unavailable, message: "Apple PCC live proof requires macOS or iOS 27.")
        }
    }
    #endif
}

private actor CalculatorLog {
    private(set) var inputs: [[Int]] = []
    func record(_ a: Int, _ b: Int) { inputs.append([a, b]) }
}

private struct LiveCalculator: AgentTool {
    struct Input: Codable, Sendable { let a: Int; let b: Int }
    struct Output: Codable, Sendable { let result: Int }
    static let name = "calculator"
    static let description = "Add integers a and b and return their sum."
    static let inputSchema = ToolSchema.object(properties: ["a": .integer, "b": .integer], required: ["a", "b"])
    static let outputSchema = ToolSchema.object(properties: ["result": .integer], required: ["result"])
    let policy: ToolPolicy
    let log: CalculatorLog
    init(log: CalculatorLog) throws {
        self.log = log
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(2), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let (sum, overflow) = input.a.addingReportingOverflow(input.b)
        guard !overflow else { throw ModelProviderError(kind: .invalidRequest, message: "Calculator overflow.") }
        await log.record(input.a, input.b)
        return .init(output: .init(result: sum))
    }
}
#endif
