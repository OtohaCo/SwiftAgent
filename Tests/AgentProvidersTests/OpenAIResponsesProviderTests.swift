import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct OpenAIResponsesProviderTests {
    @Test func reasoningSummaryAndIncompleteLimitUseProviderNeutralEvents() async throws {
        let reasoning = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-r","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-r","type":"reasoning","summary":[]}}"#),
            ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"rs-r","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs-r","output_index":0,"summary_index":0,"delta":"Checked constraints."}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs-r","type":"reasoning","summary":[{"type":"summary_text","text":"Checked constraints."}]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg-r","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-r","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-r","output_index":1,"content_index":0,"delta":"Partial"}"#),
            ("response.incomplete", #"{"type":"response.incomplete","response":{"id":"resp-r","model":"fixture","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"rs-r","type":"reasoning","summary":[{"type":"summary_text","text":"Checked constraints."}]},{"id":"msg-r","type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"Partial","annotations":[]}]}],"usage":{"input_tokens":7,"output_tokens":5,"output_tokens_details":{"reasoning_tokens":2},"total_tokens":12}}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "key", reasoningSummary: .concise,
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [reasoning]))
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: .init(provider: "openai", name: "fixture"),
                                                               messages: [.user([.text("Think")])])) {
            try accumulator.append(event)
        }
        let response = try accumulator.finish()
        #expect(response.content == [.reasoning("Checked constraints."), .text("Partial")])
        #expect(response.stopReason == .maxOutputTokens)
        #expect(response.usage == .init(inputTokens: 7, outputTokens: 5, reasoningTokens: 2))
    }

    @Test func textStreamUsesStatelessResponsesContractAndNormalizesUsage() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(
            apiKey: "fixture-key",
            maximumOutputTokens: 1_024,
            reasoningEffort: .medium,
            reasoningSummary: .concise,
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
        )
        let request = ModelRequest(
            model: .init(provider: "openai", name: "fixture"),
            messages: [.system("Be concise"), .developer("Use verified facts"), .user([.text("Hi")])]
        )
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) { try accumulator.append(event) }
        let response = try accumulator.finish()
        #expect(response.content == [.text("Hello")])
        #expect(response.stopReason == .endTurn)
        #expect(response.usage == .init(inputTokens: 5, outputTokens: 3, cachedInputTokens: 2,
                                        reasoningTokens: 1))

        let sent = try #require(await probe.requests.first)
        #expect(sent.url?.path == "/v1/responses")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(sent.httpBody)) else {
            Issue.record("Missing request object"); return
        }
        #expect(body["model"] == .string("fixture"))
        #expect(body["stream"] == .bool(true))
        #expect(body["store"] == .bool(false))
        #expect(body["previous_response_id"] == nil)
        #expect(body["conversation"] == nil)
        #expect(body["max_output_tokens"] == .number(1_024))
        #expect(body["reasoning"] == .object(["effort": .string("medium"), "summary": .string("concise")]))
        #expect(body["include"] == .array([.string("reasoning.encrypted_content")]))
        #expect(provider.descriptor.capabilities.contains(.reasoning))
        #expect(body["input"] == .array([
            .object(["type": .string("message"), "role": .string("system"), "content": .string("Be concise")]),
            .object(["type": .string("message"), "role": .string("developer"), "content": .string("Use verified facts")]),
            .object(["type": .string("message"), "role": .string("user"), "content": .string("Hi")]),
        ]))
        try OpenAIResponsesRequestContract.validate(.object(body))
    }

    @Test func reasoningConfigurationAcceptsFutureWireValuesWithoutEnumExpansion() async throws {
        let effort = OpenAIReasoningEffort(rawValue: "future_effort")
        let summary = OpenAIReasoningSummary(rawValue: "future_summary")
        #expect(String(decoding: try JSONEncoder().encode(effort), as: UTF8.self) == #""future_effort""#)
        #expect(try JSONDecoder().decode(OpenAIReasoningSummary.self, from: Data(#""future_summary""#.utf8)) == summary)
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: effort,
            reasoningSummary: summary,
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
        )
        for try await _ in provider.stream(request: .init(
            model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])]
        )) {}
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self,
            from: #require(await probe.requests.first?.httpBody)) else { Issue.record("Missing body"); return }
        #expect(body["reasoning"] == .object([
            "effort": .string("future_effort"), "summary": .string("future_summary"),
        ]))
    }

    @Test func disabledReasoningEffortUsesTheOpenAINoneWireValue() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(
            apiKey: "fixture-key", reasoningEffort: .disabled,
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture])
        )
        for try await _ in provider.stream(request: .init(
            model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])]
        )) {}
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self,
            from: #require(await probe.requests.first?.httpBody)) else { Issue.record("Missing body"); return }
        #expect(body["reasoning"] == .object(["effort": .string("none")]))
    }

    @Test func encryptedReasoningAndFunctionItemIdentityRoundTripThroughAgent() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(
            apiKey: "fixture-key", reasoningEffort: .medium, reasoningSummary: .concise,
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAIReasoningToolFixture, openAITextFixture])
        )
        let result = try await Agent(
            model: .init(provider: "openai", name: "fixture"), provider: provider,
            tools: [ProviderCalculator()]
        ).makeSession().run("Add 2 and 3").wait()
        #expect(result.outcome == .completed)

        let requests = await probe.requests
        guard requests.count == 2,
              case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody)),
              case .array(let input) = body["input"] else { Issue.record("Missing second request input"); return }
        #expect(input.contains(.object([
            "type": .string("reasoning"), "id": .string("rs-1"),
            "summary": .array([.object(["type": .string("summary_text"), "text": .string("Checked inputs.")])]),
            "encrypted_content": .string("encrypted-reasoning"),
        ])))
        #expect(input.contains(.object([
            "type": .string("function_call"), "id": .string("fc-1"), "call_id": .string("call-1"),
            "name": .string("calculator"), "arguments": .string(#"{"a":2,"b":3}"#),
            "status": .string("completed"),
        ])))
    }

    @Test func missingEncryptedReasoningCompletesWithoutProviderContinuation() async throws {
        let fixture = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-reasoning","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-1","type":"reasoning","summary":[]}}"#),
            ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"rs-1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#),
            ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","output_index":0,"summary_index":0,"delta":"Checked inputs."}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked inputs."}]}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":1,"delta":"{\"a\":2,\"b\":3}"}"#),
            ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-1","output_index":1,"arguments":"{\"a\":2,\"b\":3}"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp-reasoning","model":"fixture","status":"completed","output":[{"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked inputs."}]},{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}],"usage":{"input_tokens":8,"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2}}}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key", reasoningEffort: .medium,
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [fixture]))
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Add")])]
        )) { try accumulator.append(event) }
        let response = try accumulator.finish()
        #expect(response.toolCalls.count == 1)
        #expect(!response.content.contains { if case .providerContinuation = $0 { true } else { false } })
    }

    @Test func continuationPreservesProviderItemOrder() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let calls = [
            ToolCall(id: .init(rawValue: "call-1"), name: "first", argumentsJSON: #"{"value":1}"#,
                     completeness: .complete),
            ToolCall(id: .init(rawValue: "call-2"), name: "second", argumentsJSON: #"{"value":2}"#,
                     completeness: .complete),
        ]
        let items: [JSONValue] = [
            .object(["type": .string("function_call"), "id": .string("fc-1"),
                     "call_id": .string("call-1"), "name": .string("first"),
                     "arguments": .string(#"{"value":1}"#), "status": .string("completed")]),
            .object(["type": .string("reasoning"), "id": .string("rs-1"),
                     "summary": .array([.object(["type": .string("summary_text"),
                                                "text": .string("considered")])]),
                     "encrypted_content": .string("encrypted")]),
            .object(["type": .string("function_call"), "id": .string("fc-2"),
                     "call_id": .string("call-2"), "name": .string("second"),
                     "arguments": .string(#"{"value":2}"#), "status": .string("completed")]),
        ]
        let candidate = try OpenAIResponsesContinuation.make(
            items: items, content: [.reasoning("considered")], calls: calls, model: model
        )
        let continuation = try #require(candidate)
        let body = try OpenAIResponsesRequestEncoder.encode(.init(
            model: model,
            messages: [.assistant(content: [.reasoning("considered"), .providerContinuation(continuation)],
                                  toolCalls: calls)]
        ), maximumOutputTokens: 100, reasoningEffort: .medium, reasoningSummary: nil)
        guard case .object(let object) = body, case .array(let input) = object["input"] else {
            Issue.record("Missing input"); return
        }
        #expect(input == items)
    }

    @Test func finalOutputIgnoresBenignStatusAndSummaryExpansion() async throws {
        let fixture = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-tool","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
            ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"{\"a\":2,\"b\":3}"}"#),
            ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-1","output_index":0,"arguments":"{\"a\":2,\"b\":3}"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp-tool","model":"fixture","status":"completed","output":[{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"finalized","future_metadata":{"safe":true}}],"usage":{"input_tokens":5,"output_tokens":4}}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [fixture]))
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(
            model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Add")])]
        )) { try accumulator.append(event) }
        #expect(try accumulator.finish().toolCalls.count == 1)
    }

    @Test func refusalContentTerminatesAsRefusalInsteadOfInvalidResponse() async throws {
        let fixture = providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-refusal","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-refusal","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-refusal","output_index":0,"content_index":0,"part":{"type":"refusal","refusal":""}}"#),
            ("response.refusal.delta", #"{"type":"response.refusal.delta","item_id":"msg-refusal","output_index":0,"content_index":0,"delta":"I cannot help with that."}"#),
            ("response.refusal.done", #"{"type":"response.refusal.done","item_id":"msg-refusal","output_index":0,"content_index":0,"refusal":"I cannot help with that."}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-refusal","type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"I cannot help with that."}]}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp-refusal","model":"fixture","status":"completed","output":[{"id":"msg-refusal","type":"message","role":"assistant","status":"completed","content":[{"type":"refusal","refusal":"I cannot help with that."}]}],"usage":{"input_tokens":5,"output_tokens":6}}}"#),
        ])
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [fixture]))
        let result = try await Agent(model: .init(provider: "openai", name: "fixture"), provider: provider)
            .makeSession().run("Disallowed request").wait()
        #expect(result.outcome == .refused)
        #expect(result.response.content.first == .text("I cannot help with that."))
        #expect(result.response.content.contains { part in
            if case .providerContinuation(let continuation) = part {
                return continuation.format == OpenAIResponsesContinuation.format
            }
            return false
        })
    }

    @Test func toolRoundUsesCallIDAndReturnsOutputThroughCanonicalTranscript() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAIToolFixture, openAITextFixture])
        )
        let result = try await Agent(
            model: .init(provider: "openai", name: "fixture"), provider: provider,
            tools: [ProviderCalculator()]
        ).makeSession().run("Add 2 and 3").wait()
        #expect(result.toolCalls == 1)
        #expect(result.modelTurns == 2)
        let requests = await probe.requests
        #expect(requests.count == 2)
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self, from: #require(requests.last?.httpBody)),
              case .array(let input) = body["input"] else { Issue.record("Missing input"); return }
        #expect(input.contains(.object([
            "type": .string("function_call"), "call_id": .string("call-1"),
            "name": .string("calculator"), "arguments": .string(#"{"a":2,"b":3}"#),
        ])))
        #expect(input.contains(.object([
            "type": .string("function_call_output"), "call_id": .string("call-1"),
            "output": .string(#"{"sum":5}"#),
        ])))
    }

    @Test func structuredOutputAndHostToolsUseResponsesShapes() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        let schema = ToolSchema.object(properties: ["answer": .string], required: ["answer"]).json
        let tool = ModelToolDefinition(name: "lookup", description: "Look up a record", inputSchema: schema)
        let request = ModelRequest(model: .init(provider: "openai", name: "fixture"), messages: [.user([.text("Hi")])],
                                   tools: [tool], structuredOutput: .init(name: "answer", description: "Answer", schema: schema))
        for try await _ in provider.stream(request: request) {}
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self,
            from: #require(await probe.requests.first?.httpBody)) else { Issue.record("Missing body"); return }
        #expect(body["tools"] == .array([.object([
            "type": .string("function"), "name": .string("lookup"), "description": .string("Look up a record"),
            "parameters": schema, "strict": .bool(false),
        ])]))
        #expect(body["text"] == .object(["format": .object([
            "type": .string("json_schema"), "name": .string("answer"), "description": .string("Answer"),
            "schema": schema, "strict": .bool(true),
        ])]))
        try OpenAIResponsesRequestContract.validate(.object(body))
    }

    @Test func assistantHistoryUsesEasyMessageAndRecoverableErrorsUseDocumentedEnvelope() async throws {
        let probe = ProviderRequestProbe()
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: probe, bodies: [openAITextFixture]))
        let request = ModelRequest(model: .init(provider: "openai", name: "fixture"), messages: [
            .assistant(content: [.text("Earlier")], toolCalls: []),
            .tool(.init(callID: .init(rawValue: "call-error"), content: [.text("Not found")], isError: true)),
            .user([.text("Continue")]),
        ])
        for try await _ in provider.stream(request: request) {}
        guard case .object(let body) = try JSONDecoder().decode(JSONValue.self,
            from: #require(await probe.requests.first?.httpBody)),
              case .array(let input) = body["input"] else { Issue.record("Missing input"); return }
        #expect(input[0] == .object([
            "type": .string("message"), "role": .string("assistant"), "content": .string("Earlier"),
        ]))
        guard case .object(let errorItem) = input[1],
              errorItem["type"] == .string("function_call_output"),
              errorItem["call_id"] == .string("call-error"),
              case .string(let output) = errorItem["output"] else { Issue.record("Missing error output"); return }
        #expect(try JSONValue.decodeToolArguments(output) == .object([
            "content": .string("Not found"), "is_error": .bool(true),
        ]))
        try OpenAIResponsesRequestContract.validate(.object(body))
    }

    @Test func nativeContinuationPreservesMessageMetadataAndMultipleParts() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "lookup",
                            argumentsJSON: #"{"id":"A"}"#, completeness: .complete)
        let items: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([.object(["type": .string("summary_text"), "text": .string("Checked.")])]),
                "encrypted_content": .string("encrypted"),
            ]),
            .object([
                "type": .string("message"), "id": .string("msg-1"), "role": .string("assistant"),
                "status": .string("completed"), "phase": .string("commentary"),
                "content": .array([
                    .object(["type": .string("output_text"), "text": .string("Found "),
                             "annotations": .array([.object([
                                 "type": .string("url_citation"), "url": .string("https://example.com"),
                                 "title": .string("Example"), "start_index": .number(0), "end_index": .number(5),
                             ])])]),
                    .object(["type": .string("output_text"), "text": .string("A"),
                             "annotations": .array([])]),
                ]),
            ]),
            .object([
                "type": .string("function_call"), "id": .string("fc-1"), "call_id": .string("call-1"),
                "name": .string("lookup"), "arguments": .string(#"{"id":"A"}"#),
            ]),
        ]
        let content: [ModelContent] = [.reasoning("Checked."), .text("Found A")]
        let continuation = try #require(try OpenAIResponsesContinuation.make(
            items: items, content: content, calls: [call], model: model
        ))
        #expect(continuation.format == OpenAIResponsesContinuation.format)
        let restored = try #require(try OpenAIResponsesContinuation.restore(
            content: content + [.providerContinuation(continuation)], calls: [call], model: model
        ))
        #expect(restored.items == items)

        let body = try OpenAIResponsesRequestEncoder.encode(.init(
            model: model,
            messages: [.assistant(content: content + [.providerContinuation(continuation)], toolCalls: [call])]
        ), maximumOutputTokens: 100, reasoningEffort: .medium, reasoningSummary: nil)
        guard case .object(let object) = body, case .array(let input) = object["input"] else {
            Issue.record("Missing input"); return
        }
        #expect(input == items)
        try OpenAIResponsesRequestContract.validate(.object(object))
    }

    @Test func requestContractRejectsNativeOutputMessageWithoutIdentity() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let body = try OpenAIResponsesRequestEncoder.encode(.init(
            model: model,
            messages: [.assistant(content: [.text("Earlier")], toolCalls: [])]
        ), maximumOutputTokens: 100, reasoningEffort: nil, reasoningSummary: nil)
        guard case .object(var object) = body, case .array(var input) = object["input"],
              case .object(var message) = input[0] else {
            Issue.record("Missing input"); return
        }
        message["content"] = .array([.object([
            "type": .string("output_text"), "text": .string("Earlier"), "annotations": .array([]),
        ])])
        input[0] = .object(message)
        object["input"] = .array(input)
        #expect(throws: OpenAIResponsesRequestContract.Violation.self) {
            try OpenAIResponsesRequestContract.validate(.object(object))
        }
    }

    @Test func requestContractDoesNotRequireFunctionToolStrictField() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let tool = ModelToolDefinition(name: "lookup", description: "Look up",
                                       inputSchema: .object(["type": .string("string")]))
        let body = try OpenAIResponsesRequestEncoder.encode(.init(
            model: model, messages: [.user([.text("Hi")])], tools: [tool]
        ), maximumOutputTokens: 100, reasoningEffort: nil, reasoningSummary: nil)
        guard case .object(var object) = body, case .array(var tools) = object["tools"],
              case .object(var function) = tools[0] else { Issue.record("Missing tool"); return }
        function.removeValue(forKey: "strict")
        tools[0] = .object(function)
        object["tools"] = .array(tools)
        try OpenAIResponsesRequestContract.validate(.object(object))
    }

    @Test func reasoningContinuationDoesNotRequireFunctionCalls() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let item = JSONValue.object([
            "type": .string("reasoning"), "id": .string("rs-1"),
            "summary": .array([.object(["type": .string("summary_text"), "text": .string("Considered.")])]),
            "encrypted_content": .string("encrypted"),
        ])
        let message = JSONValue.object([
            "type": .string("message"), "id": .string("msg-1"), "role": .string("assistant"),
            "status": .string("completed"),
            "content": .array([.object(["type": .string("output_text"), "text": .string("Answer"),
                                        "annotations": .array([])])]),
        ])
        let content: [ModelContent] = [.reasoning("Considered."), .text("Answer")]
        let continuation = try #require(try OpenAIResponsesContinuation.make(
            items: [item, message], content: content, calls: [], model: model
        ))
        let restored = try #require(try OpenAIResponsesContinuation.restore(
            content: content + [.providerContinuation(continuation)], calls: [], model: model
        ))
        #expect(restored.items == [item, message])
    }

    @Test func legacyContinuationWithoutNativeMessageIdentityMigratesSafely() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "lookup",
                            argumentsJSON: #"{"id":"A"}"#, completeness: .complete)
        let payload = JSONValue.object([
            "items": .array([
                .object([
                    "type": .string("reasoning"), "id": .string("rs-1"),
                    "summary": .array([.object(["type": .string("summary_text"),
                                               "text": .string("Considered.")])]),
                    "encrypted_content": .string("encrypted"),
                ]),
                .object([
                    "type": .string("message"), "role": .string("assistant"),
                    "content": .array([.object(["type": .string("output_text"), "text": .string("Found")])]),
                ]),
                .object([
                    "type": .string("function_call"), "id": .string("fc-1"), "call_id": .string("call-1"),
                    "name": .string("lookup"), "arguments": .string(#"{"id":"A"}"#),
                    "status": .string("completed"),
                ]),
            ]),
            "visible_reasoning": .array([.string("Considered.")]),
        ])
        let state = ModelProviderContinuation(
            model: model, format: OpenAIResponsesContinuation.legacyFormat,
            payload: try JSONEncoder().encode(payload)
        )
        let restored = try #require(try OpenAIResponsesContinuation.restore(
            content: [.reasoning("Considered."), .text("Found"), .providerContinuation(state)],
            calls: [call], model: model
        ))
        #expect(restored.items[1] == .object([
            "type": .string("message"), "role": .string("assistant"), "content": .string("Found"),
        ]))
    }

    @Test func tamperedContinuationTextAndCallsFailClosed() throws {
        let model = ModelID(provider: "openai", name: "fixture")
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "lookup",
                            argumentsJSON: #"{"id":"A"}"#, completeness: .complete)
        let items: [JSONValue] = [
            .object([
                "type": .string("reasoning"), "id": .string("rs-1"),
                "summary": .array([.object(["type": .string("summary_text"),
                                           "text": .string("Considered.")])]),
                "encrypted_content": .string("encrypted"),
            ]),
            .object([
                "type": .string("message"), "id": .string("msg-1"), "role": .string("assistant"),
                "status": .string("completed"),
                "content": .array([.object(["type": .string("output_text"), "text": .string("Found"),
                                            "annotations": .array([])])]),
            ]),
            .object([
                "type": .string("function_call"), "id": .string("fc-1"),
                "call_id": .string("call-1"), "name": .string("lookup"),
                "arguments": .string(#"{"id":"A"}"#), "status": .string("completed"),
            ]),
        ]
        let continuation = try #require(try OpenAIResponsesContinuation.make(
            items: items, content: [.reasoning("Considered."), .text("Found")],
            calls: [call], model: model
        ))
        let cases: [([ModelContent], [ToolCall])] = [
            ([.reasoning("Considered."), .text("Tampered"), .providerContinuation(continuation)], [call]),
            ([.reasoning("Considered."), .text("Found"), .providerContinuation(continuation)], []),
        ]
        for (content, calls) in cases {
            #expect(throws: ModelProviderError.self) {
                try OpenAIResponsesContinuation.restore(content: content, calls: calls, model: model)
            }
        }
    }
}

private let openAIReasoningToolFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-reasoning","model":"fixture","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"rs-1","type":"reasoning","summary":[]}}"#),
    ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"rs-1","output_index":0,"summary_index":0,"part":{"type":"summary_text","text":""}}"#),
    ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"rs-1","output_index":0,"summary_index":0,"delta":"Checked inputs."}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked inputs."}],"encrypted_content":"encrypted-reasoning"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
    ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":1,"delta":"{\"a\":2,\"b\":3}"}"#),
    ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-1","output_index":1,"arguments":"{\"a\":2,\"b\":3}"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":1,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-reasoning","model":"fixture","status":"completed","output":[{"id":"rs-1","type":"reasoning","summary":[{"type":"summary_text","text":"Checked inputs."}],"encrypted_content":"encrypted-reasoning"},{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}],"usage":{"input_tokens":8,"output_tokens":7,"output_tokens_details":{"reasoning_tokens":2}}}}"#),
])
