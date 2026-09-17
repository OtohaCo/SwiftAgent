import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentLoopContractTests {
    @Test func malformedUnknownAndInvalidBatchMembersNeverExecuteAnyTool() async throws {
        let valid = ToolCall(id: .init(rawValue: "a"), name: "add", argumentsJSON: #"{"lhs":2,"rhs":3}"#, completeness: .complete)
        let invalid = [
            ToolCall(id: .init(rawValue: "b"), name: "add", argumentsJSON: "{", completeness: .complete),
            ToolCall(id: .init(rawValue: "b"), name: "missing", argumentsJSON: "{}", completeness: .complete),
            ToolCall(id: .init(rawValue: "b"), name: "add", argumentsJSON: #"{"lhs":true,"rhs":3}"#, completeness: .complete),
            ToolCall(id: .init(rawValue: "b"), name: "add", argumentsJSON: #"{"lhs":9223372036854775808,"rhs":0}"#, completeness: .complete),
        ]
        for bad in invalid {
            let log = EffectLog()
            let provider = ScriptedProvider { request, turn in
                turn == 1 ? toolResponse(request, [valid, bad]) : textResponse(request, "Unexpected")
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
            await #expect(throws: (any Error).self) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget()) }
            #expect(await log.names.isEmpty)
            #expect(await provider.log.requests.count == 1)
        }
    }

    @Test func interruptionRetainsPartialCallsWithoutDispatchOrSuccess() async throws {
        let call = ToolCall(id: .init(rawValue: "partial"), name: "add", argumentsJSON: "{")
        for reason in [StopReason.maxOutputTokens, .unknown("interrupted")] {
            let log = EffectLog()
            let provider = ScriptedProvider { request, _ in toolResponse(request, [call], stop: reason) }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
            let result = try await loop.run(messages: [], sessionID: UUID(), budget: testBudget())
            #expect(result.outcome == .incomplete(reason))
            #expect(result.response.toolCalls == [call])
            #expect(result.history.isEmpty)
            #expect(await log.names.isEmpty)
            #expect(await provider.log.requests.count == 1)
        }
    }

    @Test func refusalAndModelCancellationAreNotNormalCompletion() async throws {
        let refused = ScriptedProvider { request, _ in textResponse(request, "Cannot help", stop: .refusal) }
        let loop = AgentLoop(model: fixtureModel, provider: refused, tools: try ToolRegistry(tools: []))
        #expect(try await loop.run(messages: [], sessionID: UUID(), budget: testBudget()).outcome == .refused)
        let cancelled = ScriptedProvider { request, _ in textResponse(request, "", stop: .cancelled) }
        let other = AgentLoop(model: fixtureModel, provider: cancelled, tools: try ToolRegistry(tools: []))
        await #expect(throws: CancellationError.self) { try await other.run(messages: [], sessionID: UUID(), budget: testBudget()) }
    }

    @Test func responseCannotSilentlyChangeModelIdentity() async throws {
        let provider = ScriptedProvider { request, _ in
            textResponse(.init(model: .init(provider: request.model.provider, name: "other"), messages: []), "Wrong model")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        await #expect(throws: (any Error).self) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget()) }
    }

    @Test func incompatibleProviderIsRejectedBeforeTheRequestAndSchemaIsPreserved() async throws {
        let registry = try ToolRegistry(tools: [AnyAgentTool(AddTool(log: EffectLog()))])
        let missing = ScriptedProvider(descriptor: .init(id: "fixture", capabilities: [.streaming])) { request, _ in
            textResponse(request, "Unexpected")
        }
        let incompatible = AgentLoop(model: fixtureModel, provider: missing, tools: registry)
        await #expect(throws: (any Error).self) { try await incompatible.run(messages: [], sessionID: UUID(), budget: testBudget()) }
        #expect(await missing.log.requests.isEmpty)
        let wrongID = AgentLoop(model: .init(provider: "other", name: "test"), provider: missing, tools: try ToolRegistry(tools: []))
        await #expect(throws: (any Error).self) { try await wrongID.run(messages: [], sessionID: UUID(), budget: testBudget()) }
        #expect(await missing.log.requests.isEmpty)
        let schema = StructuredOutputSchema(name: "answer", schema: .object(["type": .string("object")]))
        let provider = ScriptedProvider { request, _ in textResponse(request, #"{"answer":5}"#) }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        _ = try await loop.run(messages: [], sessionID: UUID(), budget: testBudget(), structuredOutput: schema)
        #expect(await provider.log.requests.first?.structuredOutput == schema)
    }

    @Test func missingTerminalAndTrailingEventsCannotDispatchEvenCompletedTools() async throws {
        for trailing in [false, true] {
            let log = EffectLog()
            let provider = ScriptedProvider { request, _ in
                let events = toolResponse(request, [addition("1")])
                return trailing ? events + [.textDelta("unexpected")] : Array(events.dropLast())
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
            await #expect(throws: ModelStreamError.self) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget()) }
            #expect(await log.names.isEmpty)
        }
    }

    @Test func executorErrorStopsBatchWithoutAnotherProviderTurn() async throws {
        let log = EffectLog()
        let overflow = ToolCall(id: .init(rawValue: "overflow"), name: "add",
                                argumentsJSON: "{\"lhs\":\(Int.max),\"rhs\":1}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [overflow, addition("after")]) : textResponse(request, "Unexpected")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
        await #expect(throws: FixtureError.self) { try await loop.run(messages: [], sessionID: UUID(), budget: testBudget()) }
        #expect(await log.names == ["add"])
        #expect(await provider.log.requests.count == 1)
    }

    @Test func interruptedContentIsPreservedWithoutDanglingToolMessages() async throws {
        let call = addition("proposal")
        let messages: [ModelMessage] = [.user([.text("Compute")])]
        for reason in [StopReason.refusal, .maxOutputTokens] {
            let log = EffectLog()
            let provider = ScriptedProvider { request, _ in
                var events = toolResponse(request, [call], stop: reason)
                events.insert(.textDelta("Partial answer"), at: 1)
                events[events.count - 1] = .responseCompleted(.init(
                    info: .init(id: "response", model: request.model), content: [.text("Partial answer")],
                    toolCalls: [call], stopReason: reason
                ))
                return events
            }
            let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
            let result = try await loop.run(messages: messages, sessionID: UUID(), budget: testBudget())
            #expect(result.history == messages + [.assistant(content: [.text("Partial answer")], toolCalls: [])])
            #expect(result.response.toolCalls == [call])
            #expect(result.outcome == (reason == .refusal ? .refused : .incomplete(reason)))
            #expect(await log.names.isEmpty)
        }
    }
}
