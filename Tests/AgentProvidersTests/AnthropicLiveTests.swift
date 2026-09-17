import AgentCore
import AgentModels
import AgentTools
import AgentProviders
import Foundation
import Testing

@Suite(.serialized)
struct AnthropicLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFT_AGENT_ANTHROPIC_LIVE"] == "1"), arguments: [false, true])
    func realCloudToolRoundPreservesResultsAndSignedThinking(thinking: Bool) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["ANTHROPIC_API_KEY"], !key.isEmpty,
              let base = URL(string: environment["ANTHROPIC_BASE_URL"] ?? "https://api.anthropic.com") else {
            throw ModelProviderError(kind: .authentication, message: "Opted-in cloud credentials are unavailable.")
        }
        let endpoint = base.lastPathComponent == "v1" ? base.appendingPathComponent("messages") : base.appendingPathComponent("v1/messages")
        let model = environment["SWIFT_AGENT_ANTHROPIC_MODEL"] ?? "claude-haiku-4-5-20251001"
        let provider = try AnthropicProvider(apiKey: key, endpoint: endpoint, maximumOutputTokens: 2_048,
                                             thinking: thinking ? .enabled(budgetTokens: 1_024) : .disabled)
        let execution = ProviderExecutionProbe()
        let agent = try Agent(model: .init(provider: "anthropic", name: model), provider: provider,
                              tools: [ProviderCalculator(probe: execution)],
                              instructions: "Use calculator exactly once for arithmetic. Do not compute the answer yourself. After its tool result, return the sum using the requested JSON schema.",
                              structuredOutput: .init(name: "sum", schema: ToolSchema.object(properties: ["sum": .integer], required: ["sum"]).json),
                              maxModelTurns: 3, maxToolCalls: 1, runTimeout: .seconds(90))
        let run = try await agent.makeSession().run("Use calculator to add 2 and 3, then report its sum.")
        var phases: [String] = []
        var signedStates = 0
        for await event in run.events {
            switch event {
            case .turnStarted: phases.append("model")
            case .toolStarted: phases.append("toolStarted")
            case .toolCompleted: phases.append("toolCompleted")
            case .model(.providerContinuation(let state)):
                if case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: state.payload),
                   case .array(let content) = object["content"], content.contains(where: { block in
                       guard case .object(let fields) = block, fields["type"] == .string("thinking"),
                             case .string(let signature) = fields["signature"] else { return false }
                       return !signature.isEmpty
                   }) { signedStates += 1 }
            case .runFinished(.result): phases.append("result")
            default: break
            }
        }
        print("Cloud live trace (thinking=\(thinking)): \(phases.joined(separator: " -> ")); Core calls: \(await execution.count)")
        let result = try await run.wait()
        #expect(result.outcome == .completed)
        #expect(result.modelTurns == 2)
        #expect(result.toolCalls == 1)
        #expect(await execution.count == 1)
        #expect(phases == ["model", "toolStarted", "toolCompleted", "model", "result"])
        let text = result.response.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == .object(["sum": .number(5)]))
        if thinking { #expect(signedStates > 0) }
        #expect((result.response.usage.inputTokens ?? 0) > 0)
        #expect((result.response.usage.outputTokens ?? 0) > 0)
    }
}
