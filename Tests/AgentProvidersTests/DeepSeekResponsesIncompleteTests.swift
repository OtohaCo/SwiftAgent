import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct DeepSeekResponsesIncompleteTests {
    @Test func partialFunctionWithoutItemDoneIsIncompleteAndNeverExecutes() async throws {
        let execution = ProviderExecutionProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: .none,
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [try partialFunctionFixture()])
        )
        let result = try await Agent(
            model: deepSeekIncompleteModel,
            provider: provider,
            tools: [try ProviderCalculator(probe: execution)]
        ).makeSession().run("Add").wait()

        #expect(result.outcome == .incomplete(.maxOutputTokens))
        #expect(result.response.toolCalls == [
            .init(
                id: .init(rawValue: "call-1"),
                name: "calculator",
                argumentsJSON: #"{"a":"#,
                completeness: .incomplete
            ),
        ])
        #expect(await execution.count == 0)
    }

    @Test func partialMessageAndReasoningWithoutItemDoneRemainObservable() async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: .none,
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [partialReasoningAndMessageFixture]
            )
        )
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: deepSeekIncompleteModel,
            messages: [.user([.text("Think")])]
        )) {
            try accumulator.append(event)
        }
        let response = try accumulator.finish()

        #expect(response.stopReason == .maxOutputTokens)
        #expect(response.content == [.reasoning("Partial reason"), .text("Partial answer")])
    }

    @Test func completedAndPartialCallsInIncompleteResponseExecuteNone() async throws {
        let execution = ProviderExecutionProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: .none,
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [mixedFunctionFixture])
        )
        let result = try await Agent(
            model: deepSeekIncompleteModel,
            provider: provider,
            tools: [try ProviderCalculator(probe: execution)]
        ).makeSession().run("Add twice").wait()

        #expect(result.outcome == .incomplete(.maxOutputTokens))
        #expect(result.response.toolCalls.map(\.completeness) == [.complete, .incomplete])
        #expect(await execution.count == 0)
    }

    @Test(arguments: DeepSeekPartialTamper.allCases)
    func incompleteFinalCannotRewriteObservedPartialState(tamper: DeepSeekPartialTamper) async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: .none,
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [try partialFunctionFixture(tamper: tamper)]
            )
        )

        do {
            for try await _ in provider.stream(request: .init(
                model: deepSeekIncompleteModel,
                messages: [.user([.text("Add")])]
            )) {}
            Issue.record("Expected tampered partial response to fail")
        } catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
        }
    }
}

enum DeepSeekPartialTamper: String, CaseIterable, Sendable {
    case itemID
    case callID
    case name
    case arguments
}

private let deepSeekIncompleteModel = ModelID(provider: "deepseek", name: "deepseek-flash")

private func partialFunctionFixture(tamper: DeepSeekPartialTamper? = nil) throws -> Data {
    let finalItem: [String: JSONValue] = [
        "id": .string(tamper == .itemID ? "fc-other" : "fc-1"),
        "type": .string("function_call"),
        "call_id": .string(tamper == .callID ? "call-other" : "call-1"),
        "name": .string(tamper == .name ? "other" : "calculator"),
        "arguments": .string(tamper == .arguments ? #"{"b":"# : #"{"a":"#),
        "status": .string("incomplete"),
    ]
    return providerNamedSSE([
        ("response.created", #"{"type":"response.created","response":{"id":"resp-partial","model":"deepseek-flash","status":"in_progress"}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
        ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"{\"a\":"}"#),
        ("response.incomplete", try deepSeekFrame([
            "type": .string("response.incomplete"),
            "response": .object([
                "id": .string("resp-partial"), "model": .string("deepseek-flash"),
                "status": .string("incomplete"),
                "incomplete_details": .object(["reason": .string("max_output_tokens")]),
                "output": .array([.object(finalItem)]),
                "usage": .object(["input_tokens": .number(1), "output_tokens": .number(1)]),
            ]),
        ])),
    ])
}

private let partialReasoningAndMessageFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-partial-text","model":"deepseek-flash","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-1","type":"reasoning","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"rs-1","output_index":0,"content_index":0,"part":{"type":"reasoning_text","text":""}}"#),
    ("response.reasoning_text.delta", #"{"type":"response.reasoning_text.delta","item_id":"rs-1","output_index":0,"content_index":0,"delta":"Partial reason"}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg-1","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-1","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":1,"content_index":0,"delta":"Partial answer"}"#),
    ("response.incomplete", #"{"type":"response.incomplete","response":{"id":"resp-partial-text","model":"deepseek-flash","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"rs-1","type":"reasoning","status":"incomplete","content":[{"type":"reasoning_text","text":"Partial reason"}]},{"id":"msg-1","type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"Partial answer","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":2}}}"#),
])

private let mixedFunctionFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-mixed","model":"deepseek-flash","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
    ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"{\"a\":2,\"b\":3}"}"#),
    ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-1","output_index":0,"arguments":"{\"a\":2,\"b\":3}"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc-2","type":"function_call","call_id":"call-2","name":"calculator","arguments":"","status":"in_progress"}}"#),
    ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-2","output_index":1,"delta":"{\"a\":"}"#),
    ("response.incomplete", #"{"type":"response.incomplete","response":{"id":"resp-mixed","model":"deepseek-flash","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"},{"id":"fc-2","type":"function_call","call_id":"call-2","name":"calculator","arguments":"{\"a\":","status":"incomplete"}],"usage":{"input_tokens":1,"output_tokens":2}}}"#),
])

private func deepSeekFrame(_ object: [String: JSONValue]) throws -> String {
    String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
}
