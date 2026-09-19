import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct ResponsesContinuationIntegrityTests {
    @Test func openAIContinuationRejectsVisibleContentReordering() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let items: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([.object([
                    "type": .string("summary_text"), "text": .string("Reason"),
                ])]),
                "encrypted_content": .string("encrypted"),
            ]),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]

        #expect(throws: (any Error).self) {
            try OpenAIResponsesContinuation.make(
                items: items,
                content: [.text("Answer"), .reasoning("Reason")],
                calls: [],
                model: model
            )
        }
    }

    @Test func deepSeekContinuationRejectsVisibleContentReordering() throws {
        let model = ModelID(provider: "deepseek", name: "deepseek-flash")
        let items: [JSONValue] = [
            deepSeekReasoning(id: "rs-1", text: "Reason"),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]

        #expect(throws: (any Error).self) {
            try DeepSeekResponsesContinuation.make(
                items: items,
                content: [.text("Answer"), .reasoning("Reason")],
                calls: [],
                model: model
            )
        }
    }

    @Test func adjacentVisibleSegmentsCanMergeWithoutReordering() throws {
        let openAIModel = ModelID(provider: "openai", name: "fixture")
        let openAIItems: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([
                    .object(["type": .string("summary_text"), "text": .string("Rea")]),
                    .object(["type": .string("summary_text"), "text": .string("son")]),
                ]),
                "encrypted_content": .string("encrypted"),
            ]),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]
        #expect(try OpenAIResponsesContinuation.make(
            items: openAIItems,
            content: [.reasoning("Rea"), .reasoning("son"), .text("Answer")],
            calls: [],
            model: openAIModel
        ) != nil)

        let deepSeekModel = ModelID(provider: "deepseek", name: "deepseek-flash")
        let deepSeekItems: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs-1"), "status": .string("completed"),
                "content": .array([
                    .object(["type": .string("reasoning_text"), "text": .string("Rea")]),
                    .object(["type": .string("reasoning_text"), "text": .string("son")]),
                ]),
            ]),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]
        #expect(try DeepSeekResponsesContinuation.make(
            items: deepSeekItems,
            content: [.reasoning("Rea"), .reasoning("son"), .text("Answer")],
            calls: [],
            model: deepSeekModel
        ) != nil)
    }

    @Test func visibleContentCannotSplitANativeKindRunAcrossAnotherKind() throws {
        let openAIModel = ModelID(provider: "openai", name: "fixture")
        let openAIItems: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([.object([
                    "type": .string("summary_text"), "text": .string("Reason"),
                ])]),
                "encrypted_content": .string("encrypted"),
            ]),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]
        #expect(throws: (any Error).self) {
            try OpenAIResponsesContinuation.make(
                items: openAIItems,
                content: [.reasoning("Rea"), .text("Answer"), .reasoning("son")],
                calls: [],
                model: openAIModel
            )
        }

        let deepSeekModel = ModelID(provider: "deepseek", name: "deepseek-flash")
        let deepSeekItems: [JSONValue] = [
            deepSeekReasoning(id: "rs-1", text: "Reason"),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]
        #expect(throws: (any Error).self) {
            try DeepSeekResponsesContinuation.make(
                items: deepSeekItems,
                content: [.reasoning("Rea"), .text("Answer"), .reasoning("son")],
                calls: [],
                model: deepSeekModel
            )
        }
    }

    @Test(arguments: [1, 2])
    func openAIToolOnlyContinuationPreservesNativeIdentityAcrossEncoding(callCount: Int) throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let calls = (1...callCount).map { index in
            ToolCall(
                id: .init(rawValue: "call-\(index)"),
                name: "tool_\(index)",
                argumentsJSON: #"{"value":\#(index)}"#,
                completeness: .complete
            )
        }
        let items = calls.enumerated().map { offset, call in
            JSONValue.object([
                "type": .string("function_call"),
                "id": .string("fc-native-\(offset + 1)"),
                "call_id": .string(call.id.rawValue),
                "name": .string(call.name),
                "arguments": .string(call.argumentsJSON),
                "status": .string("completed"),
            ])
        }
        let continuation = try #require(try OpenAIResponsesContinuation.make(
            items: items, content: [], calls: calls, model: model
        ))
        let persisted = try JSONDecoder().decode(
            ModelProviderContinuation.self,
            from: JSONEncoder().encode(continuation)
        )
        let body = try OpenAIResponsesRequestEncoder.encode(
            .init(model: model, messages: [
                .assistant(content: [.providerContinuation(persisted)], toolCalls: calls),
                .user([.text("Continue")]),
            ]),
            maximumOutputTokens: 100,
            reasoningEffort: nil,
            reasoningSummary: nil
        )
        guard case .object(let object) = body, case .array(let input) = object["input"] else {
            Issue.record("Missing input")
            return
        }
        #expect(Array(input.prefix(items.count)) == items)
    }

    @Test func deepSeekThinkingWithToolsRejectsPlainTextWithoutReasoningInSameTurn() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [deepSeekPlainTextFixture])
        )
        let session = try Agent(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            provider: provider,
            tools: [ProviderCalculator()]
        ).makeSession()

        await #expect(throws: ModelProviderError.self) {
            _ = try await session.run("Answer without a tool").wait()
        }
        #expect(await session.history.allSatisfy { message in
            if case .assistant = message { return false }
            return true
        })
        #expect(await probe.requests.count == 1)
    }

    @Test func deepSeekThinkingTextContinuationEncodesTheNextTurn() async throws {
        let probe = ProviderRequestProbe()
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: probe,
                bodies: [deepSeekReasoningTextFixture(responseID: "resp-1"),
                         deepSeekReasoningTextFixture(responseID: "resp-2")]
            )
        )
        let session = try Agent(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            provider: provider,
            tools: [ProviderCalculator()]
        ).makeSession()

        _ = try await session.run("First").wait()
        _ = try await session.run("Second").wait()

        let requests = await probe.requests
        #expect(requests.count == 2)
        let second = try continuationRequestBody(requests[1])
        guard case .array(let input) = second["input"] else {
            Issue.record("Missing input")
            return
        }
        #expect(input.contains(deepSeekReasoning(id: "rs-resp-1", text: "Considered.")))
        #expect(input.contains(nativeMessage(id: "msg-resp-1", text: "Answer")))
    }
}

private func nativeMessage(id: String, text: String) -> JSONValue {
    .object([
        "type": .string("message"), "id": .string(id), "role": .string("assistant"),
        "status": .string("completed"),
        "content": .array([.object([
            "type": .string("output_text"), "text": .string(text), "annotations": .array([]),
        ])]),
    ])
}

private func deepSeekReasoning(id: String, text: String) -> JSONValue {
    .object([
        "type": .string("reasoning"), "id": .string(id), "status": .string("completed"),
        "content": .array([.object([
            "type": .string("reasoning_text"), "text": .string(text),
        ])]),
    ])
}

private let deepSeekPlainTextFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-plain","model":"deepseek-flash","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-plain","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-plain","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-plain","output_index":0,"content_index":0,"delta":"Answer"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-plain","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Answer","annotations":[]}]}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-plain","model":"deepseek-flash","status":"completed","output":[{"id":"msg-plain","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Answer","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1}}}"#),
])

private func deepSeekReasoningTextFixture(responseID: String) -> Data {
    let reasoningID = "rs-\(responseID)"
    let messageID = "msg-\(responseID)"
    return providerNamedSSE([
        ("response.created", #"{"type":"response.created","response":{"id":"\#(responseID)","model":"deepseek-flash","status":"in_progress"}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"\#(reasoningID)","type":"reasoning","status":"in_progress","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"\#(reasoningID)","output_index":0,"content_index":0,"part":{"type":"reasoning_text","text":""}}"#),
        ("response.reasoning_text.delta", #"{"type":"response.reasoning_text.delta","item_id":"\#(reasoningID)","output_index":0,"content_index":0,"delta":"Considered."}"#),
        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"\#(reasoningID)","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"Considered."}]}}"#),
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"\#(messageID)","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"\#(messageID)","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
        ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"\#(messageID)","output_index":1,"content_index":0,"delta":"Answer"}"#),
        ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"\#(messageID)","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Answer","annotations":[]}]}}"#),
        ("response.completed", #"{"type":"response.completed","response":{"id":"\#(responseID)","model":"deepseek-flash","status":"completed","output":[{"id":"\#(reasoningID)","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"Considered."}]},{"id":"\#(messageID)","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Answer","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":2,"output_tokens_details":{"reasoning_tokens":1}}}}"#),
    ])
}

private func continuationRequestBody(_ request: URLRequest) throws -> [String: JSONValue] {
    try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody)))
}
