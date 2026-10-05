import AgentCore
import AgentModels
import AgentTools
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentProviders

struct ResponsesContinuationIntegrityTests {
    @Test(arguments: DeepSeekReasoningMetadata.allCases)
    func deepSeekDocumentedReasoningMetadataRemainsReplayable(
        metadata: DeepSeekReasoningMetadata
    ) throws {
        let model = ModelID(provider: "deepseek", name: "deepseek-flash")
        var reasoning: [String: JSONValue] = [
            "type": .string("reasoning"),
            "id": .string("rs-1"),
            "status": .string("completed"),
            "content": .array([.object([
                "type": .string("reasoning_text"),
                "text": .string("Considered."),
            ])]),
        ]
        metadata.apply(to: &reasoning)
        let items: [JSONValue] = [
            .object(reasoning),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]
        let content: [ModelContent] = [.reasoning("Considered."), .text("Answer")]

        let continuation = try #require(try DeepSeekResponsesContinuation.make(
            items: items,
            content: content,
            calls: [],
            model: model
        ))
        let body = try DeepSeekResponsesRequestEncoder.encode(
            .init(model: model, messages: [
                .assistant(content: content + [.providerContinuation(continuation)], toolCalls: []),
                .user([.text("Continue")]),
            ]),
            maximumOutputTokens: 100,
            reasoningEffort: .high
        )
        guard case .object(let object) = body, case .array(let input) = object["input"] else {
            Issue.record("Missing input")
            return
        }
        #expect(Array(input.prefix(items.count)) == [
            deepSeekReasoning(id: "rs-1", text: "Considered."),
            nativeMessage(id: "msg-1", text: "Answer"),
        ])
    }

    @Test func deepSeekOutputOnlyReasoningMetadataIsNotReplayed() throws {
        let model = ModelID(provider: "deepseek", name: "deepseek-flash")
        let item = JSONValue.object([
            "type": .string("reasoning"),
            "id": .string("rs-1"),
            "status": .string("completed"),
            "content": .array([.object([
                "type": .string("reasoning_text"),
                "text": .string("Considered."),
            ])]),
            "summary": .object(["private": .string("output-only")]),
            "encrypted_content": .string("openai-only-state"),
        ])

        let continuation = try #require(try DeepSeekResponsesContinuation.make(
            items: [item],
            content: [.reasoning("Considered.")],
            calls: [],
            model: model
        ))
        let restored = try #require(try DeepSeekResponsesContinuation.restore(
            content: [.reasoning("Considered."), .providerContinuation(continuation)],
            calls: [],
            model: model
        ))

        #expect(restored.items == [deepSeekReasoning(id: "rs-1", text: "Considered.")])
    }

    @Test func deepSeekToolCallWithoutReasoningIsReplayedAsItWasReturned() throws {
        let model = ModelID(provider: "deepseek", name: "deepseek-flash")
        let call = deepSeekCalculatorCall(id: "call-2")
        let item = deepSeekFunctionCall(id: "fc-2", callID: "call-2")

        let continuation = try #require(try DeepSeekResponsesContinuation.make(
            items: [item], content: [], calls: [call], model: model
        ))
        let body = try DeepSeekResponsesRequestEncoder.encode(
            .init(model: model, messages: [
                .user([.text("Add")]),
                .assistant(content: [.providerContinuation(continuation)], toolCalls: [call]),
                .tool(.init(callID: call.id, content: [.text(#"{"sum":5}"#)], isError: false)),
            ], tools: [deepSeekCalculatorDefinition]),
            maximumOutputTokens: 100,
            reasoningEffort: .high
        )
        guard case .object(let object) = body, case .array(let input) = object["input"] else {
            Issue.record("Missing input")
            return
        }
        #expect(input == [
            .object(["type": .string("message"), "role": .string("user"), "content": .string("Add")]),
            item,
            .object(["type": .string("function_call_output"), "call_id": .string("call-2"),
                     "output": .string(#"{"sum":5}"#)]),
        ])
    }

    @Test func deepSeekContinuationWithoutReasoningMustStillMatchTheTurn() throws {
        let model = ModelID(provider: "deepseek", name: "deepseek-flash")
        let call = deepSeekCalculatorCall(id: "call-2")
        let item = deepSeekFunctionCall(id: "fc-2", callID: "call-2")
        let otherCall = deepSeekCalculatorCall(id: "call-3")

        // Text-only turns without reasoning still carry no continuation.
        #expect(try DeepSeekResponsesContinuation.make(
            items: [nativeMessage(id: "msg-1", text: "Answer")], content: [.text("Answer")],
            calls: [], model: model
        ) == nil)
        // A stored function call must still match the canonical call.
        let continuation = try #require(try DeepSeekResponsesContinuation.make(
            items: [item], content: [], calls: [call], model: model
        ))
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesContinuation.restore(
                content: [.providerContinuation(continuation)], calls: [otherCall], model: model
            )
        }
        // A continuation without reasoning cannot stand in for reasoning the turn had.
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesContinuation.restore(
                content: [.reasoning("Reason"), .providerContinuation(continuation)], calls: [call], model: model
            )
        }
        // A continuation with neither reasoning nor tool calls is not one SwiftAgent writes.
        let textOnly = try deepSeekContinuation(model: model, items: [nativeMessage(id: "msg-1", text: "Answer")])
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesContinuation.restore(
                content: [.text("Answer"), .providerContinuation(textOnly)], calls: [], model: model
            )
        }
        // An empty reasoning item is malformed.
        let emptyReasoning = try deepSeekContinuation(model: model, items: [
            .object(["type": .string("reasoning"), "id": .string("rs-1"), "content": .array([])]), item,
        ])
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesContinuation.restore(
                content: [.providerContinuation(emptyReasoning)], calls: [call], model: model
            )
        }
    }

    @Test func deepSeekThinkingToolCallFromAnotherModelIsStillRefused() throws {
        let model = ModelID(provider: "deepseek", name: "deepseek-flash")
        let call = deepSeekCalculatorCall(id: "call-2")
        for owner in [ModelID(provider: "deepseek", name: "deepseek-other"), ModelID(provider: "openai", name: "deepseek-flash")] {
            let foreign = try deepSeekContinuation(model: owner, items: [deepSeekFunctionCall(id: "fc-2", callID: "call-2")])
            do {
                _ = try DeepSeekResponsesRequestEncoder.encode(
                    .init(model: model, messages: [
                        .user([.text("Add")]),
                        .assistant(content: [.providerContinuation(foreign)], toolCalls: [call]),
                        .tool(.init(callID: call.id, content: [.text(#"{"sum":5}"#)], isError: false)),
                    ], tools: [deepSeekCalculatorDefinition]),
                    maximumOutputTokens: 100,
                    reasoningEffort: .high
                )
                Issue.record("Expected foreign continuation refusal for \(owner)")
            } catch let error as ModelProviderError {
                #expect(error.kind == .invalidRequest)
            }
        }
    }

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

        let continuation = try #require(try OpenAIResponsesContinuation.make(
            items: items,
            content: [.reasoning("Reason"), .text("Answer")],
            calls: [],
            model: model
        ))
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesContinuation.restore(
                content: [.text("Answer"), .reasoning("Reason"), .providerContinuation(continuation)],
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

        let continuation = try #require(try DeepSeekResponsesContinuation.make(
            items: items,
            content: [.reasoning("Reason"), .text("Answer")],
            calls: [],
            model: model
        ))
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesContinuation.restore(
                content: [.text("Answer"), .reasoning("Reason"), .providerContinuation(continuation)],
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
        let openAIContinuation = try #require(try OpenAIResponsesContinuation.make(
            items: openAIItems,
            content: [.reasoning("Rea"), .reasoning("son"), .text("Answer")],
            calls: [],
            model: openAIModel
        ))
        #expect(try OpenAIResponsesContinuation.restore(
            content: [.reasoning("Reason"), .text("Answer"), .providerContinuation(openAIContinuation)],
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
        let deepSeekContinuation = try #require(try DeepSeekResponsesContinuation.make(
            items: deepSeekItems,
            content: [.reasoning("Rea"), .reasoning("son"), .text("Answer")],
            calls: [],
            model: deepSeekModel
        ))
        #expect(try DeepSeekResponsesContinuation.restore(
            content: [.reasoning("Reason"), .text("Answer"), .providerContinuation(deepSeekContinuation)],
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
        let openAIContinuation = try #require(try OpenAIResponsesContinuation.make(
            items: openAIItems,
            content: [.reasoning("Reason"), .text("Answer")],
            calls: [],
            model: openAIModel
        ))
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesContinuation.restore(
                content: [
                    .reasoning("Rea"), .text("Answer"), .reasoning("son"),
                    .providerContinuation(openAIContinuation),
                ],
                calls: [],
                model: openAIModel
            )
        }

        let deepSeekModel = ModelID(provider: "deepseek", name: "deepseek-flash")
        let deepSeekItems: [JSONValue] = [
            deepSeekReasoning(id: "rs-1", text: "Reason"),
            nativeMessage(id: "msg-1", text: "Answer"),
        ]
        let deepSeekContinuation = try #require(try DeepSeekResponsesContinuation.make(
            items: deepSeekItems,
            content: [.reasoning("Reason"), .text("Answer")],
            calls: [],
            model: deepSeekModel
        ))
        #expect(throws: ModelProviderError.self) {
            try DeepSeekResponsesContinuation.restore(
                content: [
                    .reasoning("Rea"), .text("Answer"), .reasoning("son"),
                    .providerContinuation(deepSeekContinuation),
                ],
                calls: [],
                model: deepSeekModel
            )
        }
    }

    @Test func interleavedVisibleContentRoundTripsInPublishedOrder() throws {
        let openAIModel = ModelID(provider: "openai", name: "fixture")
        let openAIContent: [ModelContent] = [.text("A"), .reasoning("B"), .text("C")]
        let openAIContinuation = try #require(try OpenAIResponsesContinuation.make(
            items: [nativeMessage(id: "msg-1", text: "AC"), .object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([.object([
                    "type": .string("summary_text"), "text": .string("B"),
                ])]),
                "encrypted_content": .string("encrypted"),
            ])],
            content: openAIContent,
            calls: [],
            model: openAIModel
        ))
        #expect(try OpenAIResponsesContinuation.restore(
            content: openAIContent + [.providerContinuation(openAIContinuation)],
            calls: [],
            model: openAIModel
        ) != nil)

        let deepSeekModel = ModelID(provider: "deepseek", name: "deepseek-flash")
        let deepSeekContent: [ModelContent] = [.text("A"), .reasoning("B"), .text("C")]
        let deepSeekContinuation = try #require(try DeepSeekResponsesContinuation.make(
            items: [nativeMessage(id: "msg-1", text: "AC"), deepSeekReasoning(id: "rs-1", text: "B")],
            content: deepSeekContent,
            calls: [],
            model: deepSeekModel
        ))
        #expect(try DeepSeekResponsesContinuation.restore(
            content: deepSeekContent + [.providerContinuation(deepSeekContinuation)],
            calls: [],
            model: deepSeekModel
        ) != nil)
    }

    @Test func continuationsWithoutOrderedContentFieldRemainReadable() throws {
        let openAIModel = ModelID(provider: "openai", name: "fixture")
        let openAIContent: [ModelContent] = [.reasoning("Reason"), .text("Answer")]
        let currentOpenAI = try #require(try OpenAIResponsesContinuation.make(
            items: [.object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([.object([
                    "type": .string("summary_text"), "text": .string("Reason"),
                ])]),
                "encrypted_content": .string("encrypted"),
            ]), nativeMessage(id: "msg-1", text: "Answer")],
            content: openAIContent,
            calls: [],
            model: openAIModel
        ))
        let oldOpenAI = try removingOrderedContentField(from: currentOpenAI)
        #expect(try OpenAIResponsesContinuation.restore(
            content: openAIContent + [.providerContinuation(oldOpenAI)],
            calls: [],
            model: openAIModel
        ) != nil)

        let deepSeekModel = ModelID(provider: "deepseek", name: "deepseek-flash")
        let deepSeekContent: [ModelContent] = [.reasoning("Reason"), .text("Answer")]
        let currentDeepSeek = try #require(try DeepSeekResponsesContinuation.make(
            items: [deepSeekReasoning(id: "rs-1", text: "Reason"),
                    nativeMessage(id: "msg-1", text: "Answer")],
            content: deepSeekContent,
            calls: [],
            model: deepSeekModel
        ))
        let oldDeepSeek = try removingOrderedContentField(from: currentDeepSeek)
        #expect(try DeepSeekResponsesContinuation.restore(
            content: deepSeekContent + [.providerContinuation(oldDeepSeek)],
            calls: [],
            model: deepSeekModel
        ) != nil)
    }

    @Test func deepSeekInterleavedItemsPreserveCanonicalContentOrder() async throws {
        let provider = try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [deepSeekInterleavedFixture]
            )
        )
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "deepseek", name: "deepseek-flash"),
            messages: [.user([.text("Interleave")])]
        )) {
            try accumulator.append(event)
        }
        let response = try accumulator.finish()
        #expect(Array(response.content.prefix(3)) == [.text("A"), .reasoning("B"), .text("C")])
        #expect(response.content.contains { if case .providerContinuation = $0 { true } else { false } })
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

    @Test func deepSeekThinkingWithAvailableToolsAcceptsPlainTextWithoutAToolCall() async throws {
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

        let result = try await session.run("Answer without a tool").wait()

        #expect(result.response.content.contains(.text("Answer")))
        #expect(await session.history.contains { message in
            guard case .assistant(let content, let calls) = message else { return false }
            return content.contains(.text("Answer")) && calls.isEmpty
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

enum DeepSeekReasoningMetadata: String, CaseIterable, Sendable {
    case emptySummary
    case nullEncryptedContent

    func apply(to item: inout [String: JSONValue]) {
        switch self {
        case .emptySummary:
            item["summary"] = .array([])
        case .nullEncryptedContent:
            item["encrypted_content"] = .null
        }
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

private func removingOrderedContentField(
    from continuation: ModelProviderContinuation
) throws -> ModelProviderContinuation {
    var object = try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: continuation.payload))
    object.removeValue(forKey: "visible_content_order")
    return .init(
        model: continuation.model,
        format: continuation.format,
        payload: try JSONEncoder().encode(JSONValue.object(object))
    )
}

private let deepSeekInterleavedFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-interleaved","model":"deepseek-flash","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"rs-1","type":"reasoning","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"rs-1","output_index":1,"content_index":0,"part":{"type":"reasoning_text","text":""}}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"A"}"#),
    ("response.reasoning_text.delta", #"{"type":"response.reasoning_text.delta","item_id":"rs-1","output_index":1,"content_index":0,"delta":"B"}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"C"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"AC","annotations":[]}]}}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"rs-1","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"B"}]}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-interleaved","model":"deepseek-flash","status":"completed","output":[{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"AC","annotations":[]}]},{"id":"rs-1","type":"reasoning","status":"completed","content":[{"type":"reasoning_text","text":"B"}]}],"usage":{"input_tokens":1,"output_tokens":3}}}"#),
])

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

private let deepSeekCalculatorDefinition = ModelToolDefinition(
    name: "calculator", description: "Add", inputSchema: .object([:])
)

private func deepSeekCalculatorCall(id: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: "calculator", argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
}

private func deepSeekFunctionCall(id: String, callID: String) -> JSONValue {
    .object([
        "type": .string("function_call"), "id": .string(id), "status": .string("completed"),
        "call_id": .string(callID), "name": .string("calculator"), "arguments": .string(#"{"a":2,"b":3}"#),
    ])
}

private func deepSeekContinuation(model: ModelID, items: [JSONValue]) throws -> ModelProviderContinuation {
    let payload = try JSONEncoder().encode(JSONValue.object(["items": .array(items)]))
    return .init(model: model, format: "deepseek.responses.v1", payload: payload)
}

private func continuationRequestBody(_ request: URLRequest) throws -> [String: JSONValue] {
    try ProviderJSON.object(JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody)))
}
