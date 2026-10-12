import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import Foundation
import Testing

@Suite struct OpenAIAutomaticFinalAnswerTests {
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let model = ModelID(provider: "openai", name: "gpt-5.4-nano-2026-03-17")

    private func provider(_ probe: ProviderRequestProbe, bodies: [Data]) throws -> OpenAIResponsesProvider {
        try OpenAIResponsesProvider(apiKey: "fixture", nativeContext: .init(
            qualification: .init(endpoint: endpoint, resolvedModelNames: [model.name], modes: [.openAIAutomatic]),
            automatic: .init(mode: .openAIAutomatic, triggerInputTokens: 1_000)),
            transport: FixtureHTTPTransport(probe: probe, bodies: bodies, chunkBytes: 7))
    }

    private func agent(_ provider: OpenAIResponsesProvider) throws -> Agent {
        try Agent(binding: .init(profileID: "fixture", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "openai")))
    }

    @Test(arguments: [false, true])
    func completedAnswerBeforeTrailingCompactionIsFinal(_ leadingCompaction: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-final-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = ProviderRequestProbe()
        // If misclassified, reproduce the bounded fifth-response failure instead of exhausting the fixture.
        let bodies = try (1...5).map { try fixture(id: "resp-\($0)", leading: leadingCompaction, answer: true) }
        let provider = try provider(probe, bodies: bodies)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "automatic-final", supportsNativeContext: true)
        let session = try agent(provider).makeSession(journal: journal)
        let run = try await session.run("Remember this reference. Reply only OK.")
        let result: AgentLoopResult
        do { result = try await run.wait() }
        catch { try await run.waitForDrain(); throw error }
        try await run.waitForDrain()
        #expect(result.outcome == .completed)
        #expect(result.response.stopReason == .endTurn)
        #expect(result.response.content.contains(.text("OK")))
        #expect(result.modelTurns == 1)
        #expect(await probe.requests.count == 1)
        let history = await session.history
        #expect(history.count == 2)
        #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history == history)
        let checkpoint = try #require(try await journal.nativeContextCheckpoint(sessionID: session.id))
        let payload = try JSONDecoder().decode(JSONValue.self, from: checkpoint.continuation.payload)
        let items = try #require(payload["items"]?.array)
        #expect(items.map { $0["type"] } == (leadingCompaction ? ["compaction", "message", "compaction"] : ["message", "compaction"]).map(JSONValue.string))
        #expect(items.last?["encrypted_content"] == .string("opaque-resp-1-tail"))
        let answer = try #require(items.first { $0["type"] == .string("message") })
        #expect(answer["id"] == .string("resp-1-message"))
        #expect(answer["content"]?.array?.first?["text"] == .string("OK"))
        #expect(checkpoint.transition.replayPosition == items.count - 1)
        #expect(checkpoint.transition.itemID == "resp-1-tail")
        #expect(checkpoint.usage.inputTokens == 13_523)
        #expect(checkpoint.usage.outputTokens == 353)
        let terminal = try await journal.runRecord(sessionID: session.id, runID: run.id)
        guard case .terminal(_, .completed) = terminal else { Issue.record("answer Run has no completed terminal"); return }
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == history)
        #expect(try await reopened.nativeContextCheckpoint(sessionID: session.id) == checkpoint)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == terminal)
        let freshProbe = ProviderRequestProbe()
        let freshProvider = try self.provider(freshProbe, bodies: [try fixture(id: "next", leading: false, answer: true)])
        let fresh = try agent(freshProvider).makeSession(id: session.id, journal: reopened)
        let next = try await fresh.run("next user")
        #expect(try await next.wait().outcome == .completed); try await next.waitForDrain()
        #expect(await freshProbe.requests.count == 1)
        let body = try JSONDecoder().decode(JSONValue.self, from: #require(await freshProbe.requests.first?.httpBody))
        let input = try #require(body["input"]?.array)
        #expect(input.first == items.last)
        #expect(input.count == 2)
        #expect(input.last?["content"] == .string("next user"))
        #expect(await fresh.history.count == 4)
        try await reopened.close()
    }

    @Test func compactionWithoutAnAnswerStillUsesBoundedMaintenance() async throws {
        let probe = ProviderRequestProbe()
        let provider = try provider(probe, bodies: try (1...5).map { try fixture(id: "maintenance-\($0)", leading: false, answer: false) })
        let session = try agent(provider).makeSession()
        let run = try await session.run("source")
        do { _ = try await run.wait(); Issue.record("maintenance-only response completed as an answer") }
        catch let error as ModelProviderError {
            #expect(error.kind == .invalidResponse)
            #expect(error.message == "Native maintenance did not converge within its bounded continuation budget.")
        }
        try await run.waitForDrain()
        #expect(await probe.requests.count == 5)
        #expect(await session.history == [.user([.text("source")])])
    }

    private func fixture(id: String, leading: Bool, answer: Bool) throws -> Data {
        func compact(_ suffix: String) -> JSONValue { .object(["type": .string("compaction"), "id": .string("\(id)-\(suffix)"), "encrypted_content": .string("opaque-\(id)-\(suffix)")]) }
        let message: JSONValue = .object(["type": .string("message"), "id": .string("\(id)-message"), "role": .string("assistant"), "status": .string("completed"), "content": .array([.object(["type": .string("output_text"), "text": .string("OK"), "annotations": .array([])])])])
        var output: [JSONValue] = leading ? [compact("head")] : []
        if answer { output.append(message) }
        output.append(compact("tail"))
        var frames: [(String, String)] = []
        func add(_ type: String, _ fields: [String: JSONValue]) throws {
            var object = fields; object["type"] = .string(type)
            frames.append((type, String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)))
        }
        try add("response.created", ["response": .object(["id": .string(id), "model": .string(model.name), "status": .string("in_progress")])])
        for (index, item) in output.enumerated() {
            var added = try #require(item.object)
            if item["type"] == .string("message") { added["status"] = .string("in_progress"); added["content"] = .array([]) }
            else { added["encrypted_content"] = .string("") }
            try add("response.output_item.added", ["output_index": .number(Decimal(index)), "item": .object(added)])
            if item["type"] == .string("message") {
                let coordinates: [String: JSONValue] = ["output_index": .number(Decimal(index)), "item_id": item["id"]!, "content_index": .number(0)]
                try add("response.content_part.added", coordinates.merging(["part": .object(["type": .string("output_text"), "text": .string(""), "annotations": .array([])])]) { _, rhs in rhs })
                try add("response.output_text.delta", coordinates.merging(["delta": .string("OK")]) { _, rhs in rhs })
            }
            try add("response.output_item.done", ["output_index": .number(Decimal(index)), "item": item])
        }
        try add("response.completed", ["response": .object(["id": .string(id), "model": .string(model.name), "status": .string("completed"), "output": .array(output), "usage": .object(["input_tokens": .number(13_523), "output_tokens": .number(353)])])])
        return providerNamedSSE(frames)
    }
}

private extension JSONValue {
    subscript(_ key: String) -> JSONValue? { object?[key] }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}
