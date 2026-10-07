import AgentCore
import AgentModels
import AgentUsage
import Foundation
import Testing
@testable import AgentProviders

struct ResponsesCacheUsageTests {
    // Both adapters must preserve the service report, without requiring cache support.
    @Test(arguments: [false, true], [false, true])
    func cacheCountsSurviveProviderEventsSnapshotsLedgerAndExport(local: Bool, incomplete: Bool) async throws {
        let samples: [(Int?, Int?)] = [(12_000, 3_000), (0, 15_000), (0, 3_000), (0, 0), (nil, nil)]
        var accumulator = UsageAccumulator()
        let ledger = UsageLedger()
        let model = ModelID(provider: local ? "local-responses" : "openai", name: "fixture")
        for (index, sample) in samples.enumerated() {
            let body = try fixture(read: sample.0, write: sample.1.map { .number(Decimal($0)) }, incomplete: incomplete)
            let provider = try provider(local: local, body: body)
            let identity = UsageRecordIdentity(source: .modelResponse, invocationID: "turn-\(index)", model: model)
            var stream = ModelEventAccumulator()
            var final: ModelResponse?
            for try await event in provider.stream(request: .init(model: model, messages: [.user([.text("Hi")])])) {
                try stream.append(event)
                switch event {
                case .usage(let usage):
                    #expect(usage.inputTokens == 15_000)
                    #expect(usage.cachedInputTokens == sample.0)
                    #expect(usage.cacheWriteInputTokens == sample.1)
                    #expect(usage.outputTokens == 100)
                    #expect(usage.reasoningTokens == 0)
                    let observation = UsageObservation(identity: identity, usage: usage, status: .provisional)
                    #expect(accumulator.record(observation).accepted)
                    #expect(await ledger.record(observation).accepted)
                    // Same invocation, sparse cumulative update: retain earlier cache counts.
                    let sparse = UsageObservation(identity: identity, usage: .init(outputTokens: 100), status: .provisional)
                    #expect(accumulator.record(sparse).accepted)
                    #expect(await ledger.record(sparse).accepted)
                case .responseCompleted(let response):
                    final = response
                    let observation = UsageObservation(identity: identity, usage: response.usage, status: .finalized)
                    #expect(accumulator.record(observation).disposition == .updated)
                    #expect(await ledger.record(observation).disposition == .updated)
                    #expect(accumulator.record(observation).disposition == .duplicate)
                    #expect(await ledger.record(observation).disposition == .duplicate)
                    #expect(try JSONDecoder().decode(UsageObservation.self, from: JSONEncoder().encode(observation)) == observation)
                default: break
                }
            }
            #expect(try stream.finish() == final)
            let summary = await ledger.summary(identity: identity)
            #expect(summary.observedResponseCount == 1)
            #expect(summary.provisionalResponseCount == 0)
            #expect(summary.totalTokens == 15_100)
            #expect(summary.cacheWriteInputTokens.reportedSubtotal == sample.1)
            #expect(summary.cacheWriteInputTokens.complete == (sample.1 != nil))
        }
        let summary = await ledger.summary()
        #expect(summary == accumulator.summary())
        #expect(summary.observedResponseCount == 5)
        #expect(summary.totalTokens == 75_500)
        #expect(summary.cachedInputTokens.reportedSubtotal == 12_000)
        #expect(summary.cacheWriteInputTokens.reportedSubtotal == 21_000)
        #expect(summary.cacheWriteInputTokens.reportedCount == 4)
        #expect(summary.cacheWriteInputTokens.missingCount == 1)
        #expect(!summary.cacheWriteInputTokens.complete)
        #expect(try JSONDecoder().decode(UsageSummary.self, from: JSONEncoder().encode(summary)) == summary)
    }

    @Test(arguments: [false, true], [false, true])
    func nullCacheWriteRemainsUnreported(local: Bool, incomplete: Bool) async throws {
        let provider = try provider(local: local, body: fixture(read: 0, write: .null, incomplete: incomplete))
        for try await event in provider.stream(request: .init(
            model: .init(provider: local ? "local-responses" : "openai", name: "fixture"), messages: [.user([.text("Hi")])]
        )) {
            if case .responseCompleted(let response) = event { #expect(response.usage.cacheWriteInputTokens == nil) }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func malformedCacheWriteUsesExistingResponseError(local: Bool, incomplete: Bool) async throws {
        for invalid in [JSONValue.string("3000"), .bool(true), .number(-1), .number(1.5),
                        .number(Decimal(Int.max) + 1), .array([]), .object([:])] {
            let provider = try provider(local: local, body: fixture(read: 0, write: invalid, incomplete: incomplete))
            do {
                for try await _ in provider.stream(request: .init(
                    model: .init(provider: local ? "local-responses" : "openai", name: "fixture"), messages: [.user([.text("Hi")])])) {}
                Issue.record("Accepted invalid cache write count: \(invalid)")
            } catch let error as ModelProviderError {
                #expect(error.kind == .invalidResponse)
            }
        }
    }

    @Test func agentEventConsumerCountsToolRoundsWithoutAddingTheLoopResultAgain() async throws {
        let hit = String(decoding: openAITextFixture, as: UTF8.self).replacingOccurrences(of: #""cached_tokens":2"#,
            with: #""cached_tokens":2,"cache_write_tokens":3"#)
        let provider = try OpenAIResponsesProvider(apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [openAIToolFixture, Data(hit.utf8)]))
        let run = try await Agent(model: .init(provider: "openai", name: "fixture"), provider: provider,
            tools: [ProviderCalculator()]).makeSession().run("Add 2 and 3")
        var usage = UsageAccumulator()
        var turn = 0
        var identity: UsageRecordIdentity?
        for await event in run.events {
            switch event {
            case .turnStarted: turn += 1
            case .model(.responseStarted(let info)):
                identity = .init(source: .modelResponse, invocationID: "turn-\(turn)", model: info.model)
            case .model(.usage(let snapshot)):
                #expect(usage.record(.init(identity: try #require(identity), usage: snapshot, status: .provisional)).accepted)
            case .model(.responseCompleted(let response)):
                #expect(usage.record(.init(identity: try #require(identity), usage: response.usage, status: .finalized)).accepted)
            default: break
            }
        }
        let result = try await run.wait()
        #expect(result.outcome == .completed)
        #expect(result.response.usage.cacheWriteInputTokens == 3)
        #expect(usage.summary().observedResponseCount == 2)
        #expect(usage.summary().cacheWriteInputTokens.reportedSubtotal == 3)
        #expect(usage.summary().cacheWriteInputTokens.missingCount == 1)
    }

    private func provider(local: Bool, body: Data) throws -> any ModelProvider {
        let transport = FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [body])
        if local {
            return try LocalResponsesProvider(configuration: .init(
                baseURL: URL(string: "http://localhost:1234/v1")!, model: "fixture"), transport: transport)
        }
        return try OpenAIResponsesProvider(apiKey: "fixture-key", transport: transport)
    }

    private func fixture(read: Int?, write: JSONValue?, incomplete: Bool) throws -> Data {
        var details: [String: JSONValue] = [:]
        if let read { details["cached_tokens"] = .number(Decimal(read)) }
        if let write { details["cache_write_tokens"] = write }
        let type = incomplete ? "response.incomplete" : "response.completed"
        var response: [String: JSONValue] = [
            "id": .string("resp-cache"), "model": .string("fixture"),
            "status": .string(incomplete ? "incomplete" : "completed"), "output": .array([]),
            "usage": .object(["input_tokens": .number(15_000), "output_tokens": .number(100),
                "input_tokens_details": .object(details),
                "output_tokens_details": .object(["reasoning_tokens": .number(0)])])]
        if incomplete { response["incomplete_details"] = .object(["reason": .string("max_output_tokens")]) }
        return providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-cache","model":"fixture","status":"in_progress"}}"#),
            (type, try ProviderJSON.text(JSONValue.object(["type": .string(type), "response": .object(response)])))])
    }
}
