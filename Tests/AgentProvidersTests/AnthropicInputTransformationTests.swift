import AgentModels
import AgentProviders
import Foundation
import Testing

@Suite struct AnthropicInputTransformationTests {
    private let model = ModelID(provider: "anthropic", name: "fixture")
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    @Test(arguments: [AnthropicThinkingPrefixMismatch.error, .dropBlock])
    func explicitPolicyPreservesThinkingAndMapsMergedWirePositions(_ policy: AnthropicThinkingPrefixMismatch) async throws {
        let probe = ProviderRequestProbe()
        let configuration = try AnthropicNativeContextConfiguration(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: []), thinkingPrefixMismatch: policy)
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive, nativeContext: configuration,
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, diagnosticFixture(clear: false)]))
        let prefix: [ModelMessage] = [.system("root"), .user([.text("one")]), .user([.text("two")])]
        var first = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: model, messages: prefix)) { try first.append(event) }
        let response = try first.finish()
        let signed = try #require(response.content.compactMap { if case .providerContinuation(let value) = $0 { value } else { nil } }.first)
        let oldPayload = signed.payload
        let assistant = ModelMessage.assistant(content: response.content, toolCalls: response.toolCalls)
        // The changed root is handled by the explicitly selected server policy. The
        // opaque continuation remains byte-for-byte unchanged; no local signature check.
        let next = ModelRequest(model: model, messages: [.system("changed root")] + prefix.dropFirst() + [assistant,
            .tool(.init(callID: response.toolCalls[0].id, content: [.text("5")], isError: false))])
        var snapshots: [[ModelInputTransformation]] = [], accumulated = ModelEventAccumulator()
        for try await event in provider.stream(request: next) {
            try accumulated.append(event)
            if case .inputTransformations(let values) = event { snapshots.append(values) }
        }
        let final = try accumulated.finish()
        #expect(snapshots.count == 2)
        #expect(snapshots[0][0].thinkingWasDropped)
        #expect(snapshots[1].count == 1 && snapshots[1][0].kind == "future_transform")
        #expect(snapshots[1][0].reason == "future_reason")
        #expect(final.inputTransformations == snapshots[1])
        let identity = try #require(snapshots[0][0].source)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(identity.messageDigest == ModelImageDigest.sha256Hex(try encoder.encode(assistant)))
        #expect(identity.nativeCheckpointID == nil)
        #expect(signed.payload == oldPayload)
        let sent = await probe.requests
        #expect(sent.count == 2)
        #expect(sent[1].value(forHTTPHeaderField: "anthropic-beta") == "thinking-binding-controls-2026-08-01")
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[1].httpBody!)
        #expect(body["thinking"]?["block_binding"]?["prefix_mismatch_behavior"] == .string(policy.rawValue))
        guard case .array(let messages) = body["messages"], case .array(let blocks) = messages[1]["content"] else { Issue.record("missing merged request"); return }
        #expect(messages.count == 3) // canonical assistant index 3 is actual wire index 1.
        #expect(blocks[0]["signature"] == .string("signature-1"))
        #expect(!final.content.contains { if case .text(let value) = $0 { value.contains("thinking_dropped") } else { false } })
    }

    @Test func emptyDiagnosticSnapshotClearsAndMissingFieldPreserves() async throws {
        let probe = ProviderRequestProbe(), provider = try AnthropicProvider(apiKey: "fixture",
            transport: FixtureHTTPTransport(probe: probe, bodies: [diagnosticFixture(clear: true)]))
        var snapshots: [[ModelInputTransformation]] = [], accumulated = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: model, messages: [.user([.text("one")])])) {
            try accumulated.append(event)
            if case .inputTransformations(let values) = event { snapshots.append(values) }
        }
        #expect(snapshots.count == 2 && snapshots[1].isEmpty)
        #expect(try accumulated.finish().inputTransformations == [])
        #expect(snapshots[0][0].source == nil) // unknown path is retained without a fabricated mapping.
    }

    @Test(arguments: [false, true])
    func standaloneReportsTransformationsEvenBeforeEOF(_ eof: Bool) async throws {
        let probe = ProviderRequestProbe()
        let qualification = try NativeContextQualification(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand])
        let replacement = #"[{"type":"future_transform","reason":"future_reason","path":"messages.0.content.0"}]"#
        var frames = [
            #"{"type":"message_start","message":{"id":"compact","type":"message","role":"assistant","model":"fixture","content":[],"input_transformations":[{"type":"thinking_dropped","reason":"prefix_binding_mismatch","path":"messages.0.content.0"}],"usage":{"iterations":[]}}}"#,
            #"{"type":"message_delta","delta":{},"input_transformations":\#(replacement)}"#,
            #"{"type":"message_delta","delta":{},"input_transformations":null}"#,
        ]
        if !eof { frames += [#"{"type":"message_delta","delta":{"stop_reason":"refusal"},"input_transformations":[]}"#, #"{"type":"message_stop"}"#] }
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: qualification, thinkingPrefixMismatch: .dropBlock),
            transport: FixtureHTTPTransport(probe: probe, bodies: [providerSSE(frames)]))
        let plain = ModelRequest(model: model, messages: [.user([.text("source")])], sessionID: UUID())
        let invocation = UUID()
        let source = ModelNativeContextSource(sessionID: plain.sessionID!, canonicalMessageCount: 1, lastMessageID: UUID(),
            canonicalDigest: "fixture", requestDigest: try provider.nativeContextRequestDigest(request: plain, compactionMode: .anthropicOnDemand),
            projectionID: "fixture", projectionVersion: "1", previousCheckpointID: nil)
        var snapshots: [[ModelInputTransformation]] = [], response: ModelCompactionResponse?, failed = false
        do {
            for try await event in provider.compact(request: .init(request: plain.withNativeSource(source, invocationID: invocation),
                mode: .anthropicOnDemand, operationID: UUID(), invocationID: invocation)) {
                if case .inputTransformations(let values) = event { snapshots.append(values) }
                if case .completed(let value) = event { response = value }
            }
        } catch let error as ModelProviderError { failed = error.kind == .invalidResponse }
        #expect(failed == eof)
        #expect(snapshots.count == (eof ? 2 : 3))
        #expect(snapshots[0][0].thinkingWasDropped && snapshots[0][0].source != nil)
        #expect(snapshots[1][0].kind == "future_transform")
        if eof { #expect(response == nil) }
        else { #expect(response?.inputTransformations == [] && response?.continuation == nil) }
    }

    private func diagnosticFixture(clear: Bool) -> Data {
        let replacement = clear ? "[]" : #"[{"type":"future_transform","reason":"future_reason","path":"messages.1.content.0"}]"#
        return providerSSE([
            #"{"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","model":"fixture","content":[],"input_transformations":[{"type":"thinking_dropped","reason":"prefix_binding_mismatch","path":"messages.1.content.0"}],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"answer"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            "{\"type\":\"message_delta\",\"delta\":{},\"input_transformations\":\(replacement)}",
            #"{"type":"message_delta","delta":{},"input_transformations":null}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3,"iterations":null}}"#,
            #"{"type":"message_stop"}"#,
        ])
    }
}

private extension JSONValue {
    subscript(_ key: String) -> JSONValue? { guard case .object(let fields) = self else { return nil }; return fields[key] }
}
