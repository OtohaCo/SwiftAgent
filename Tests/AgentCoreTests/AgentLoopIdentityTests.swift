import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentLoopIdentityTests {
    @Test func invalidUsageCannotDispatchAnOtherwiseValidToolProposal() async throws {
        for decreased in [false, true] {
            let log = EffectLog()
            let provider = ScriptedProvider { request, _ in
                let call = addition("proposal")
                let invalid = decreased ? ModelUsage(outputTokens: 5) : ModelUsage(outputTokens: 2, reasoningTokens: 3)
                var events = toolResponse(request, [call])
                events.removeLast()
                if decreased { events.append(.usage(.init(outputTokens: 40))) }
                events.append(.usage(invalid))
                events.append(.responseCompleted(.init(info: .init(id: "response", model: request.model),
                                                        toolCalls: [call], usage: invalid, stopReason: .toolCalls)))
                return events
            }
            let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: log)]).makeSession()
            await #expect(throws: ModelStreamError.invalidUsage) { try await session.run("Add").wait() }
            #expect(await log.names.isEmpty)
            #expect(await provider.log.requests.count == 1)
        }
    }

    @Test func changedCompletionOrTerminalNeverReachesExecutor() async throws {
        let nfd = "e\u{301}", nfc = "\u{e9}"
        for terminalChange in [false, true] {
            for field in 0..<3 {
                let log = EffectLog()
                let provider = ScriptedProvider { request, _ in
                    let info = ResponseInfo(id: "identity", model: request.model)
                    let original = ToolCall(id: .init(rawValue: nfd), name: field == 1 ? "r" + nfd + "ad" : IdentityProbe.name,
                                            argumentsJSON: "{\"query\":\"\(nfd)\"}", completeness: .complete)
                    let replacement = ToolCall(id: field == 0 ? .init(rawValue: nfc) : original.id,
                                               name: IdentityProbe.name,
                                               argumentsJSON: field == 2 ? "{\"query\":\"\(nfc)\"}" : original.argumentsJSON,
                                               completeness: .complete)
                    return [.responseStarted(info), .toolCallStarted(original.id, name: original.name),
                            .toolCallArgumentsDelta(original.id, original.argumentsJSON),
                            .toolCallCompleted(terminalChange ? original : replacement),
                            .responseCompleted(.init(info: info, toolCalls: [replacement], stopReason: .toolCalls))]
                }
                let session = try Agent(model: fixtureModel, provider: provider, tools: [IdentityProbe(log: log)]).makeSession()
                let expected: ModelStreamError = terminalChange ? .responseMismatch :
                    (field == 0 ? .unknownToolCall(.init(rawValue: nfc)) : .toolCallMismatch(.init(rawValue: nfd)))
                await #expect(throws: expected) { try await session.run("Read").wait() }
                #expect(await log.names.isEmpty)
                #expect(await provider.log.requests.count == 1)
            }
        }
    }
}

private struct IdentityProbe: AgentTool {
    typealias Input = LookupTool.Input
    typealias Output = String
    static let name = "r\u{e9}ad"
    static let description = "Read a resource"
    static let inputSchema = LookupTool.inputSchema
    static let outputSchema = ToolSchema.string
    let log: EffectLog
    let policy: ToolPolicy
    init(log: EffectLog) throws {
        self.log = log
        policy = try .init(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await log.record(Self.name, context)
        return .init(output: input.query)
    }
}
