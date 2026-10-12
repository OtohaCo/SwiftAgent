import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import Foundation
import Testing

@Suite struct AnthropicNativeContextTests {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = ModelID(provider: "anthropic", name: "fixture")
    private func scopedAgent(_ provider: any ModelProvider) throws -> Agent {
        try Agent(binding: .init(profileID: "http-fixture", profileRevision: "1", model: .init(provider: "anthropic", name: "fixture"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture-account", endpointScope: endpoint.absoluteString, apiDialect: "anthropic")))
    }
    private func provider(_ probe: ProviderRequestProbe, bodies: [Data], threshold: Bool = false) throws -> AnthropicProvider {
        let qualification = try NativeContextQualification(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicThreshold, .anthropicOnDemand])
        return try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: qualification,
            automatic: threshold ? .init(mode: .anthropicThreshold, triggerInputTokens: 50_000, pauseAfterCompaction: true) : nil),
            transport: FixtureHTTPTransport(probe: probe, bodies: bodies, chunkBytes: 7))
    }
    private func request(_ provider: AnthropicProvider, mode: ModelCompactionMode?, native: ModelNativeContextCheckpoint? = nil,
                         messages: [ModelMessage] = [.system("root"), .user([.text("full source")])]) throws -> ModelRequest {
        let session = UUID(), invocation = UUID()
        let request = ModelRequest(model: model, messages: messages, sessionID: session, runID: UUID(), nativeContext: native)
        let source = ModelNativeContextSource(sessionID: session, canonicalMessageCount: 1, lastMessageID: UUID(),
            canonicalDigest: "fixture-source", requestDigest: try provider.nativeContextRequestDigest(request: request, compactionMode: mode),
            projectionID: "fixture", projectionVersion: "1", previousCheckpointID: native?.id)
        return request.withNativeSource(source, invocationID: invocation)
    }

    @Test(arguments: [false, true])
    func twoNativeShapesRoundTripExactBlockAndUsage(_ threshold: Bool) async throws {
        let mode: ModelCompactionMode = threshold ? .anthropicThreshold : .anthropicOnDemand
        let block: JSONValue = .object(["type": .string("compaction"), "content": .string("完整摘要"),
            "signature": threshold ? .null : .string("fixture-signature-not-live"), "encrypted_content": .string("opaque"),
            "tool_changes": .array([]), "extension": .object(["preserve": .bool(true)])])
        let probe = ProviderRequestProbe()
        let provider = try provider(probe, bodies: [try fixture(block: block, threshold: threshold), Data(String(decoding: anthropicTextFixture, as: UTF8.self).replacingOccurrences(of: #""output_tokens":3"#, with: #""output_tokens":3,"iterations":[]"#).utf8)], threshold: threshold)
        let req = try request(provider, mode: threshold ? nil : mode)
        var state: ModelProviderContinuation?, usage: ModelUsage?
        if threshold {
            for try await event in provider.stream(request: req) {
                if case .responseCompleted(let response) = event {
                    #expect(response.classification == .maintenance)
                    state = response.content.compactMap { if case .providerContinuation(let state) = $0 { state } else { nil } }.first
                    usage = response.usage
                }
            }
        } else {
            for try await event in provider.compact(request: .init(request: req, mode: mode, operationID: UUID(), invocationID: req.invocationID!)) {
                if case .completed(let response) = event { state = response.continuation; usage = response.usage }
            }
        }
        let continuation = try #require(state), reported = try #require(usage)
        #expect(reported.inputTokens == 1_000 && reported.outputTokens == 10)
        #expect(reported.iterationUsage?.coverage == .complete)
        #expect(reported.iterationUsage?.iterations.count == 1)
        let payload = try JSONDecoder().decode(JSONValue.self, from: continuation.payload)
        #expect(payload["content"] == .array([block]))
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: continuation,
            transition: continuation.contextTransition!, rootConfigurationDigest: "fixture", toolBaseline: [], usage: reported)
        let next = try request(provider, mode: nil, native: checkpoint, messages: [.system("root"), .user([.text("next")])])
        for try await _ in provider.stream(request: next) {}
        let forged = ModelNativeContextSource(sessionID: next.sessionID!, canonicalMessageCount: 1, lastMessageID: UUID(),
            canonicalDigest: "fixture", requestDigest: "wrong-wire-digest", projectionID: "fixture", projectionVersion: "1", previousCheckpointID: checkpoint.id)
        do {
            for try await _ in provider.stream(request: next.withNativeSource(forged, invocationID: UUID())) {}
            Issue.record("Mismatched native body dispatched")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        let sent = await probe.requests
        #expect(sent.count == 2)
        #expect(sent[0].value(forHTTPHeaderField: "anthropic-beta") == (threshold ? "compact-2026-01-12" : "compact-2026-09-04"))
        #expect(sent[1].value(forHTTPHeaderField: "anthropic-beta") == (threshold ? "compact-2026-01-12" : "compact-2026-09-04"))
        let first = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody!)
        #expect(first["compaction"] == (threshold ? nil : .object(["type": .string("summarize")])))
        #expect((first["context_management"] != nil) == threshold)
        let continued = try JSONDecoder().decode(JSONValue.self, from: sent[1].httpBody!)
        #expect(continued["compaction"] == nil)
        guard case .array(let messages) = continued["messages"] else { Issue.record("missing native window"); return }
        #expect(messages.count == 2)
        #expect(messages[0]["content"] == .array([block]))
        #expect(messages[1]["role"] == .string("user"))
        #expect(!String(decoding: sent[1].httpBody!, as: UTF8.self).contains("full source"))
    }

    @Test(arguments: [false, true])
    func missingToolChangesCannotEstablishContradictoryCoveredTools(_ explicitNull: Bool) async throws {
        let baseline = ModelToolDefinition(name: "base", description: "Trusted baseline", inputSchema: .object(["type": .string("object")]))
        let foreign = ModelToolDefinition(name: "different", description: "Unestablished active tool", inputSchema: baseline.inputSchema)
        var block: [String: JSONValue] = ["type": .string("compaction"), "content": .string("summary"), "signature": .string("fixture-not-live")]
        if explicitNull { block["tool_changes"] = .null }
        let probe = ProviderRequestProbe()
        let qualified = try NativeContextQualification(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand])
        let provider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: qualified, inlineToolChanges: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [try fixture(block: .object(block), threshold: false), anthropicTextFixture]))
        let initial = try request(provider, mode: .anthropicOnDemand)
        var continuation: ModelProviderContinuation?
        for try await event in provider.compact(request: .init(request: initial, mode: .anthropicOnDemand, operationID: UUID(), invocationID: initial.invocationID!)) {
            if case .completed(let response) = event { continuation = response.continuation }
        }
        let state = try #require(continuation)
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: state, transition: state.contextTransition!, rootConfigurationDigest: "fixture", toolBaseline: [], usage: .init())
        let next = ModelRequest(model: model, messages: [.user([.text("next")])], tools: [baseline], nativeContext: checkpoint,
            conversationControls: .init(toolBaseline: [baseline], activeTools: [foreign], controls: [], coveredTools: [foreign], coveredToolChanges: false))
        do { for try await _ in provider.stream(request: next) {}; Issue.record("Unestablished covered tools dispatched") }
        catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await probe.requests.count == 1)
    }

    @Test(arguments: ["max_tokens", "refusal", "tool_use", "end_turn"])
    func billedOnDemandWithoutSummaryIsNotAnAnswerOrCheckpoint(_ reason: String) async throws {
        let probe = ProviderRequestProbe()
        let provider = try provider(probe, bodies: [try fixture(block: nil, threshold: false, reason: reason)])
        let req = try request(provider, mode: .anthropicOnDemand)
        var completed: ModelCompactionResponse?
        for try await event in provider.compact(request: .init(request: req, mode: .anthropicOnDemand, operationID: UUID(), invocationID: req.invocationID!)) {
            if case .completed(let value) = event { completed = value }
        }
        #expect(completed?.continuation == nil)
        #expect(completed?.nativeStopReason == reason)
        #expect(completed?.usage.outputTokens == 10)
        #expect(completed?.usage.iterationUsage?.iterations.first?.kind == "compaction")
        #expect(await probe.requests.count == 1)
    }

    @Test(arguments: ["missing-delta", "double-delta", "missing-stop", "missing-terminal", "missing-signature", "bad-tool-changes"])
    func malformedNativeStagesNeverProduceACandidate(_ fault: String) async throws {
        let threshold = fault != "missing-signature"
        let mode: ModelCompactionMode = threshold ? .anthropicThreshold : .anthropicOnDemand
        var block: [String: JSONValue] = ["type": .string("compaction"), "content": .string("summary"), "signature": .string("fixture-not-live")]
        if fault == "missing-signature" { block.removeValue(forKey: "signature") }
        if fault == "bad-tool-changes" { block["tool_changes"] = .string("wrong") }
        var frames = String(decoding: try fixture(block: .object(block), threshold: threshold), as: UTF8.self).components(separatedBy: "\n\n")
        if fault == "missing-delta" { frames.removeAll { $0.contains("event: content_block_delta") } }
        if fault == "double-delta", let delta = frames.first(where: { $0.contains("event: content_block_delta") }), let index = frames.firstIndex(of: delta) { frames.insert(delta, at: index + 1) }
        if fault == "missing-stop" { frames.removeAll { $0.contains("event: content_block_stop") } }
        if fault == "missing-terminal" { frames.removeAll { $0.contains("event: message_stop") } }
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [Data(frames.joined(separator: "\n\n").utf8)], threshold: threshold)
        let req = try request(provider, mode: threshold ? nil : mode)
        var candidate = false, failed = false
        do {
            if threshold {
                for try await event in provider.stream(request: req) { if case .providerContinuation(let state) = event { candidate = state.contextTransition != nil } }
            } else {
                for try await event in provider.compact(request: .init(request: req, mode: mode, operationID: UUID(), invocationID: req.invocationID!)) { if case .completed(let response) = event { candidate = response.continuation != nil } }
            }
        } catch let error as ModelProviderError { failed = error.kind == .invalidResponse }
        #expect(failed && !candidate)
        #expect(await probe.requests.count == 1)
    }

    @Test func thresholdNoOpCanStillDeliverAnAnswerAndUsage() async throws {
        var frames = String(decoding: try fixture(block: .object(["type": .string("compaction"), "content": .null]), threshold: true, reason: "end_turn"), as: UTF8.self).components(separatedBy: "\n\n")
        let index = try #require(frames.firstIndex(where: { $0.contains("event: message_delta") }))
        let text = String(decoding: providerNamedSSE([
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"answer"}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
        ]), as: UTF8.self).components(separatedBy: "\n\n").filter { !$0.isEmpty }
        frames.insert(contentsOf: text, at: index)
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [Data(frames.joined(separator: "\n\n").utf8)], threshold: true)
        let req = try request(provider, mode: nil)
        var response: ModelResponse?
        for try await event in provider.stream(request: req) { if case .responseCompleted(let value) = event { response = value } }
        #expect(response?.classification == .finalResponse)
        #expect(response?.content.contains(.text("answer")) == true)
        #expect(response?.usage.inputTokens == 1_000)
        #expect(response?.content.contains { if case .providerContinuation(let state) = $0 { state.contextTransition != nil } else { false } } == false)
    }

    @Test(arguments: ["replacement", "empty", "eof", "sparse"])
    func iterationTablesAreWholeSnapshotsAndNeverDoubleCountParent(_ variant: String) async throws {
        let first = #"[{"type":"compaction","model":"actual-compactor","input_tokens":100,"output_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":7},{"type":"message","input_tokens":200,"output_tokens":20,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]"#
        let last = variant == "empty" ? "[]" : variant == "sparse"
            ? #"[{"type":"advisor","input_tokens":3,"output_tokens":2}]"#
            : #"[{"type":"compaction","model":"actual-compactor","input_tokens":110,"output_tokens":11,"cache_read_input_tokens":5,"cache_creation_input_tokens":7}]"#
        var frames = [
            #"{"type":"message_start","message":{"id":"usage","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":0,"output_tokens":0,"iterations":[]}}}"#,
            #"{"type":"message_delta","delta":{},"usage":{"iterations":\#(first)}}"#,
            #"{"type":"message_delta","delta":{},"usage":{"iterations":\#(last)}}"#,
        ]
        if variant != "eof" { frames += [#"{"type":"message_delta","delta":{"stop_reason":"compaction"},"usage":{"input_tokens":0,"output_tokens":0}}"#, #"{"type":"message_stop"}"#] }
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [providerSSE(frames)], threshold: true)
        let req = try request(provider, mode: nil)
        var snapshots: [ModelUsage] = [], failed = false
        do { for try await event in provider.stream(request: req) { if case .usage(let value) = event { snapshots.append(value) } } }
        catch let error as ModelProviderError { failed = error.kind == .invalidResponse }
        let final = try #require(snapshots.last)
        #expect(failed == (variant == "eof"))
        #expect(snapshots.dropLast().allSatisfy { $0.inputTokens == nil })
        #expect(final.iterationUsage?.iterations.count == (variant == "empty" ? 0 : 1))
        #expect(final.iterationUsage?.coverage == (variant == "eof" ? .partial : .complete))
        #expect(final.inputTokens == (variant == "replacement" ? 122 : nil))
        #expect(final.outputTokens == (variant == "replacement" ? 11 : variant == "sparse" ? 2 : nil))
        if variant == "sparse" { #expect(final.iterationUsage?.iterations.first?.model == nil) }
        else if variant != "empty" { #expect(final.iterationUsage?.iterations.first?.model?.name == "actual-compactor") }
    }

    @Test(arguments: [false, true])
    func realHTTPNativeContextSurvivesRunAndFileReopen(_ threshold: Bool) async throws {
        var phase = "setup"
        do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anthropic-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let block: JSONValue = .object(["type": .string("compaction"), "content": .string("summary"), "signature": threshold ? .null : .string("fixture-not-live")])
        let compactBody = try fixture(block: block, threshold: threshold)
        let bodies = threshold ? [compactBody, anthropicTextFixture, anthropicTextFixture] : [anthropicTextFixture, compactBody, anthropicTextFixture]
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: bodies, threshold: threshold)
        let id = UUID(), journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "native-http", supportsNativeContext: true)
        let session = try scopedAgent(provider).makeSession(id: id, journal: journal)
        let original = "source-that-must-not-be-replayed " + String(repeating: "x", count: 4_096)
        phase = "first run"
        let first = try await session.run(original)
        #expect(try await first.wait().outcome == .completed)
        try await first.waitForDrain()
        let firstHistory = await session.history
        if !threshold {
        phase = "idle compact"
            phase = "idle compact"
        let operation = try await session.compact(mode: .anthropicOnDemand)
            #expect(try await operation.wait().checkpoint != nil)
            try await operation.waitForDrain()
            #expect(await session.history == firstHistory)
        }
        phase = "next run"
        let next = try await session.run("next")
        #expect(try await next.wait().outcome == .completed)
        try await next.waitForDrain()
        let canonical = await session.history
        #expect(canonical.contains(.user([.text(original)])))
        let sent = await probe.requests
        #expect(sent.count == 3)
        #expect(!String(decoding: sent.last!.httpBody!, as: UTF8.self).contains(original))
        #expect(String(decoding: sent.last!.httpBody!, as: UTF8.self).contains("summary"))
        if threshold { #expect(sent[1].httpBody!.count < sent[0].httpBody!.count) }
        phase = "close"
        try await journal.close()
        phase = "reopen"
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let freshProbe = ProviderRequestProbe(), freshProvider = try self.provider(freshProbe, bodies: [anthropicTextFixture], threshold: threshold)
        phase = "fresh session"
        let fresh = try scopedAgent(freshProvider).makeSession(id: id, journal: reopened)
        phase = "snapshot"
        #expect(try await fresh.conversationSnapshot().messages == canonical)
        phase = "reopened run"
        let resumed = try await fresh.run("after reopen")
        #expect(try await resumed.wait().outcome == .completed)
        try await resumed.waitForDrain()
        let resumedBody = try #require(await freshProbe.requests.first?.httpBody)
        #expect(!String(decoding: resumedBody, as: UTF8.self).contains(original))
        #expect(String(decoding: resumedBody, as: UTF8.self).contains("summary"))
        phase = "final close"
        try await reopened.close()
        } catch { Issue.record("Native HTTP failure at \(phase)"); throw error }
    }

    @Test func legacyAutomaticConfigurationIsRefusedBeforeAdmission() async throws {
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [anthropicTextFixture], threshold: true)
        let session = try Agent(model: model, provider: provider).makeSession()
        do { _ = try await session.run("new source"); Issue.record("Native context admitted without deployment scope") }
        catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        #expect(await probe.requests.isEmpty)
        #expect(await session.history.isEmpty)
    }

    @Test func signedBlockCannotUseThresholdEvenWithMislabelledMode() async throws {
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [try fixture(block: .object([
            "type": .string("compaction"), "content": .string("summary"), "signature": .string("fixture-not-live")]), threshold: false)])
        let req = try request(provider, mode: .anthropicOnDemand)
        var state: ModelProviderContinuation?
        for try await event in provider.compact(request: .init(request: req, mode: .anthropicOnDemand, operationID: UUID(), invocationID: req.invocationID!)) {
            if case .completed(let value) = event { state = value.continuation }
        }
        let original = try #require(state), old = try #require(original.contextTransition)
        let transition = ModelNativeContextTransition(mode: .anthropicThreshold, source: old.source,
            replayPosition: old.replayPosition, invocationID: old.invocationID, responseID: old.responseID)
        let mislabelled = ModelProviderContinuation(model: model, format: original.format, payload: original.payload, contextTransition: transition)
        let checkpoint = ModelNativeContextCheckpoint(id: UUID(), generation: 1, continuation: mislabelled, transition: transition,
            rootConfigurationDigest: "fixture", toolBaseline: [], usage: .init())
        let nextProbe = ProviderRequestProbe(), next = try self.provider(nextProbe, bodies: [anthropicTextFixture], threshold: true)
        do {
            for try await _ in next.stream(request: .init(model: model, messages: [.user([.text("next")])], nativeContext: checkpoint)) {}
            Issue.record("Signed native block was combined with threshold context_management")
        } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        #expect(await nextProbe.requests.isEmpty)
    }

    func fixture(block: JSONValue?, threshold: Bool, reason: String = "compaction") throws -> Data {
        func json(_ value: JSONValue) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        var frames: [(String, String)] = [("message_start", #"{"type":"message_start","message":{"id":"compact","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"iterations":[]}}}"#)]
        if let block {
            let start = threshold ? JSONValue.object(["type": .string("compaction"), "content": .null]) : block
            frames.append(("content_block_start", "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":\(try json(start))}"))
            if threshold, case .object(var fields) = block {
                fields["type"] = .string("compaction_delta")
                frames.append(("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":\(try json(.object(fields)))}"))
            }
            frames.append(("content_block_stop", #"{"type":"content_block_stop","index":0}"#))
        }
        frames.append(("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(reason)\"},\"usage\":{\"input_tokens\":0,\"output_tokens\":0,\"iterations\":[{\"type\":\"compaction\",\"input_tokens\":1000,\"output_tokens\":10,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}]}}"))
        frames.append(("message_stop", #"{"type":"message_stop"}"#))
        return providerNamedSSE(frames)
    }
}

private extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }; return fields[key]
    }
}
