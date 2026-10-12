import AgentModels
import AgentProviders
import Foundation
import Testing

@Suite struct OpenAINativeContextTests {
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private func provider(_ probe: ProviderRequestProbe, bodies: [Data], automatic: Bool = false) throws -> OpenAIResponsesProvider {
        let qualification = try NativeContextQualification(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.openAIAutomatic, .openAIStandalone])
        return try OpenAIResponsesProvider(apiKey: "fixture-key", nativeContext: .init(qualification: qualification,
            automatic: automatic ? .init(mode: .openAIAutomatic, triggerInputTokens: 1_000) : nil),
            transport: FixtureHTTPTransport(probe: probe, bodies: bodies, headers: ["Content-Type": automatic ? "text/event-stream" : "application/json"]))
    }
    private func request(_ provider: OpenAIResponsesProvider, mode: ModelCompactionMode?, messages: [ModelMessage],
                         native: ModelNativeContextCheckpoint? = nil) throws -> ModelRequest {
        let session = UUID(), invocation = UUID()
        let plain = ModelRequest(model: .init(provider: "openai", name: "fixture"), messages: messages,
            tools: [.init(name: "tool", description: "schema", inputSchema: .object(["type": .string("object")]))],
            sessionID: session, runID: UUID(), nativeContext: native)
        let source = ModelNativeContextSource(sessionID: session, canonicalMessageCount: 2, lastMessageID: UUID(),
            canonicalDigest: "fixture-source", requestDigest: try provider.nativeContextRequestDigest(request: plain, compactionMode: mode),
            projectionID: "fixture", projectionVersion: "1", previousCheckpointID: native?.id)
        return plain.withNativeSource(source, invocationID: invocation)
    }
    @Test func standaloneUsesJSONEndpointAndEntireReturnedWindow() async throws {
        let probe = ProviderRequestProbe()
        let compact = Data(#"{"id":"compact-1","created_at":1,"object":"response.compaction","extension":{"retained":true},"output":[{"type":"message","role":"user","content":[{"type":"input_text","text":"original"}]},{"type":"compaction","id":"cmp-1","encrypted_content":"opaque","created_by":"fixture"}],"usage":{"input_tokens":20,"output_tokens":3,"input_tokens_details":{"cached_tokens":4,"cache_write_tokens":1}}}"#.utf8)
        let provider = try provider(probe, bodies: [compact, openAITextFixture])
        let req = try request(provider, mode: .openAIStandalone, messages: [.user([.text("original")]), .assistant(content: [.text("old answer")], toolCalls: [])])
        let operation = ModelCompactionRequest(request: req, mode: .openAIStandalone, operationID: UUID(), invocationID: req.invocationID!)
        var result: ModelCompactionResponse?
        for try await event in provider.compact(request: operation) { if case .completed(let response) = event { result = response } }
        let response = try #require(result), state = try #require(response.continuation)
        #expect(response.usage.inputTokens == 20); #expect(response.usage.iterationUsage == nil)
        let payload = try JSONDecoder().decode(JSONValue.self, from: state.payload)
        #expect(payload["extension"] == .object(["retained": .bool(true)]))
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: state, transition: state.contextTransition!,
            rootConfigurationDigest: "fixture-root", toolBaseline: req.tools, usage: response.usage)
        let next = try request(provider, mode: nil, messages: [.user([.text("next")])], native: checkpoint)
        for try await _ in provider.stream(request: next) {}
        let sent = await probe.requests
        #expect(sent.count == 2)
        #expect(sent[0].url?.path == "/v1/responses/compact")
        #expect(sent[0].value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody!)
        for key in ["stream", "tools", "reasoning", "text", "store", "max_output_tokens", "context_management"] { #expect(body[key] == nil) }
        let continued = try JSONDecoder().decode(JSONValue.self, from: sent[1].httpBody!)
        guard case .array(let input) = continued["input"] else { Issue.record("missing input"); return }
        #expect(input.count == 3)
        guard case .array(let window) = payload["output"] else { Issue.record("missing compact window"); return }
        #expect(input[0] == window[0])
        #expect(input[1]["created_by"] == .string("fixture"))
        #expect(input[2]["content"] == .string("next"))
    }
    @Test func alreadyCancelledStandaloneCallerCannotDispatch() async throws {
        let probe = ProviderRequestProbe()
        let provider = try provider(probe, bodies: [Data(#"{"id":"none","created_at":1,"object":"response.compaction","output":[]}"#.utf8)])
        let req = try request(provider, mode: .openAIStandalone, messages: [.user([.text("source")])])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return provider.compact(request: .init(request: req, mode: .openAIStandalone, operationID: UUID(), invocationID: req.invocationID!))
        }
        let stream = await task.value
        do {
            for try await _ in stream {}
            Issue.record("pre-cancelled standalone operation completed")
        } catch is CancellationError {}
        #expect(await probe.requests.isEmpty)
    }
    @Test func nativeWindowFinalBodyLimitStopsTransport() async throws {
        let probe = ProviderRequestProbe()
        let provider = try provider(probe, bodies: [openAITextFixture])
        let req = try request(provider, mode: .openAIStandalone, messages: [.user([.text("source")])])
        let transition = ModelNativeContextTransition(mode: .openAIStandalone, source: req.nativeContextSource!,
            replayPosition: 0, invocationID: req.invocationID!, responseID: "compact", itemID: "cmp")
        let payload = Data(#"{"id":"compact","created_at":1,"object":"response.compaction","output":[{"type":"compaction","id":"cmp","encrypted_content":"opaque"}]}"#.utf8)
        let state = ModelProviderContinuation(model: req.model, format: "openai.responses.compact.v1", payload: payload, contextTransition: transition)
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: state, transition: transition,
            rootConfigurationDigest: "fixture", toolBaseline: [], usage: .init())
        let oversized = ModelRequest(model: req.model, messages: [.user([.text(String(repeating: "x", count: 32_000_000))])],
            nativeContext: checkpoint)
        do {
            for try await _ in provider.stream(request: oversized) {}
            Issue.record("oversized body dispatched")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await probe.requests.isEmpty)
    }
    @Test(arguments: ["missing_done", "wrong_id", "wrong_index", "eof", "failed", "incomplete"])
    func partialAutomaticResponseCannotPublish(_ failure: String) async throws {
        let probe = ProviderRequestProbe()
        let compact = #"{"type":"compaction","id":"cmp","encrypted_content":"opaque"}"#
        var frames: [(String, String)] = [
            ("response.created", #"{"type":"response.created","response":{"id":"resp","model":"fixture","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"type":"compaction","id":"cmp","encrypted_content":""}}"#)
        ]
        if failure != "missing_done" {
            let doneItem = failure == "wrong_id" ? compact.replacingOccurrences(of: "cmp", with: "other") : compact
            let index = failure == "wrong_index" ? 1 : 0
            frames.append(("response.output_item.done", "{\"type\":\"response.output_item.done\",\"output_index\":\(index),\"item\":\(doneItem)}"))
        }
        if failure != "eof" {
            let status = ["failed", "incomplete"].contains(failure) ? failure : "completed"
            frames.append(("response.\(status)", "{\"type\":\"response.\(status)\",\"response\":{\"id\":\"resp\",\"model\":\"fixture\",\"status\":\"\(status)\",\"output\":[\(compact)],\"error\":{\"code\":\"server_error\",\"message\":\"fixture\"},\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}"))
        }
        let provider = try provider(probe, bodies: [providerNamedSSE(frames)], automatic: true)
        let req = try request(provider, mode: nil, messages: [.user([.text("source")])])
        var transitions = 0
        do {
            for try await event in provider.stream(request: req) {
                if case .providerContinuation(let state) = event, state.contextTransition != nil { transitions += 1 }
            }
            if failure != "incomplete" { Issue.record("invalid automatic stream accepted") }
        } catch is ModelProviderError {}
        #expect(transitions == 0)
        #expect(await probe.requests.count == 1)
    }
    @Test(arguments: ["null", "123", "\"\""])
    func malformedRetainedImageCannotBecomeCheckpoint(_ url: String) async throws {
        let probe = ProviderRequestProbe()
        let body = Data("{\"id\":\"compact\",\"created_at\":1,\"object\":\"response.compaction\",\"output\":[{\"type\":\"compaction\",\"id\":\"cmp\",\"encrypted_content\":\"opaque\"},{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_image\",\"image_url\":\(url)}]}]}".utf8)
        let provider = try provider(probe, bodies: [body])
        let req = try request(provider, mode: .openAIStandalone, messages: [.user([.text("closed")])])
        do {
            for try await _ in provider.compact(request: .init(request: req, mode: .openAIStandalone, operationID: UUID(), invocationID: req.invocationID!)) {}
            Issue.record("malformed retained image accepted")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidResponse) }
    }
    @Test(arguments: ["function_call", "reasoning", "function_call_output"])
    func malformedStandaloneSuffixCannotBecomeCheckpoint(_ type: String) async throws {
        let probe = ProviderRequestProbe()
        let body = Data("{\"id\":\"compact\",\"created_at\":1,\"object\":\"response.compaction\",\"output\":[{\"type\":\"compaction\",\"id\":\"cmp\",\"encrypted_content\":\"opaque\"},{\"type\":\"\(type)\"}]}".utf8)
        let provider = try provider(probe, bodies: [body])
        let req = try request(provider, mode: .openAIStandalone, messages: [.user([.text("closed")])])
        do {
            for try await _ in provider.compact(request: .init(request: req, mode: .openAIStandalone, operationID: UUID(), invocationID: req.invocationID!)) {}
            Issue.record("malformed compact window accepted")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidResponse) }
    }
    @Test(arguments: [false, true])
    func automaticCompleteItemAndPostCompactionTextArePreserved(_ precedingUnencryptedReasoning: Bool) async throws {
        let probe = ProviderRequestProbe()
        let compact: JSONValue = .object(["type": .string("compaction"), "id": .string("cmp"), "encrypted_content": .string("opaque"), "created_by": .string("extension")])
        let message: JSONValue = .object(["id": .string("msg"), "type": .string("message"), "role": .string("assistant"), "status": .string("completed"),
            "content": .array([.object(["type": .string("output_text"), "text": .string("answer"), "annotations": .array([])])])])
        func json(_ value: JSONValue) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        let frames: [(String, String)] = [
            ("response.created", #"{"type":"response.created","response":{"id":"resp","model":"fixture","status":"in_progress"}}"#),
            ("response.compaction.compacting", #"{"type":"response.compaction.compacting"}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"type":"compaction","id":"cmp","encrypted_content":""}}"#),
            ("response.output_item.done", "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":\(try json(compact))}"),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":1,"item":{"id":"msg","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg","output_index":1,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
            ("response.output_item.done", "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":\(try json(message))}"),
            ("response.completed", "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":\(try json(.array([compact, message]))),\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}")
        ]
        let reasoning: JSONValue = .object(["id": .string("reasoning"), "type": .string("reasoning"), "summary": .array([])])
        var actualFrames = frames
        if precedingUnencryptedReasoning {
            actualFrames = try frames.map { name, data in
                guard case .object(var fields) = try JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)) else { throw ModelProviderError(kind: .invalidResponse, message: "fixture shape") }
                if case .number(let index) = fields["output_index"] { fields["output_index"] = .number(index + 1) }
                if name == "response.completed", case .object(var response) = fields["response"] {
                    response["output"] = .array([reasoning, compact, message]); fields["response"] = .object(response)
                }
                return (name, try json(.object(fields)))
            }
            actualFrames.insert(contentsOf: [
                ("response.output_item.added", "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":\(try json(reasoning))}"),
                ("response.output_item.done", "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":\(try json(reasoning))}")
            ], at: 1)
        }
        let provider = try provider(probe, bodies: [providerNamedSSE(actualFrames), openAITextFixture], automatic: true)
        let req = try request(provider, mode: nil, messages: [.user([.text("long source")])])
        var response: ModelResponse?
        for try await event in provider.stream(request: req) { if case .responseCompleted(let value) = event { response = value } }
        let result = try #require(response)
        #expect(result.content.contains(.text("answer")))
        let state = try #require(result.content.compactMap { if case .providerContinuation(let value) = $0 { value } else { nil } }.first)
        #expect(state.contextTransition?.mode == .openAIAutomatic)
        let payload = try JSONDecoder().decode(JSONValue.self, from: state.payload)
        guard case .array(let items) = payload["items"] else { Issue.record("missing native items"); return }
        #expect(items == (precedingUnencryptedReasoning ? [reasoning, compact, message] : [compact, message]))
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: state, transition: state.contextTransition!,
            rootConfigurationDigest: "fixture", toolBaseline: req.tools, usage: result.usage)
        let next = try request(provider, mode: nil, messages: [.user([.text("next")])], native: checkpoint)
        for try await _ in provider.stream(request: next) {}
        let continued = try #require(await probe.requests.last?.httpBody)
        let continuedBody = try JSONDecoder().decode(JSONValue.self, from: continued)
        guard case .array(let continuedItems) = continuedBody["input"] else { Issue.record("missing continued items"); return }
        #expect(continuedItems.prefix(2).elementsEqual([compact, message]))
        let sent = try #require(await probe.requests.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: sent.httpBody!)
        #expect(body["context_management"] == .array([.object(["type": .string("compaction"), "compact_threshold": .number(1_000)])]))
        let unqualifiedProbe = ProviderRequestProbe()
        let unqualified = try OpenAIResponsesProvider(apiKey: "fixture", transport: FixtureHTTPTransport(probe: unqualifiedProbe, bodies: [openAITextFixture]))
        let replay = ModelRequest(model: req.model, messages: [.user([.text("source")]),
            .assistant(content: result.content, toolCalls: result.toolCalls), .user([.text("next")])])
        do {
            for try await _ in unqualified.stream(request: replay) {}
            Issue.record("unqualified native replay was dispatched")
        } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        #expect(await unqualifiedProbe.requests.isEmpty)

    }
}

private extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }; return object[key]
    }
}
