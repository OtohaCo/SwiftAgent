import AgentModels
import AgentUsage
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicCacheUsageTests {
    @Test func ttlReportsCrossProviderSnapshotsLedgerSummaryAndCodableWithoutDoubleCounting() async throws {
        let samples: [(Int, Int, CacheWriteTTLUsage?)] = [
            (0, 15_000, .init(fiveMinuteTokens: 15_000, oneHourTokens: 0)),
            (0, 15_000, .init(fiveMinuteTokens: 0, oneHourTokens: 15_000)),
            (12_000, 3_000, .init(fiveMinuteTokens: 2_000, oneHourTokens: 1_000)),
            (15_000, 0, .init(fiveMinuteTokens: 0, oneHourTokens: 0)),
            (12_000, 3_000, .init(fiveMinuteTokens: 2_000)),
            (12_000, 3_000, nil),
        ]
        let ledger = UsageLedger()
        var accumulator = UsageAccumulator()
        for (index, sample) in samples.enumerated() {
            var usage: [String: JSONValue] = ["input_tokens": .number(0), "cache_read_input_tokens": .number(Decimal(sample.0)),
                "cache_creation_input_tokens": .number(Decimal(sample.1)), "output_tokens": .number(0)]
            if let detail = sample.2 {
                var fields: [String: JSONValue] = [:]
                if let five = detail.fiveMinuteTokens { fields["ephemeral_5m_input_tokens"] = .number(Decimal(five)) }
                if let hour = detail.oneHourTokens { fields["ephemeral_1h_input_tokens"] = .number(Decimal(hour)) }
                usage["cache_creation"] = .object(fields)
            }
            let model = ModelID(provider: "anthropic", name: "fixture")
            let identity = UsageRecordIdentity(source: .modelResponse, invocationID: "ttl-\(index)", model: model)
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(), bodies: [try fixture(usage: usage)]))
            var stream = ModelEventAccumulator()
            for try await event in provider.stream(request: .init(model: model, messages: [.user([.text("Hi")])])) {
                try stream.append(event)
                switch event {
                case .usage(let snapshot):
                    let observed = UsageObservation(identity: identity, usage: snapshot, status: .provisional)
                    #expect(accumulator.record(observed).accepted)
                    #expect(await ledger.record(observed).accepted)
                case .responseCompleted(let response):
                    #expect(response.usage.inputTokens == 15_000)
                    #expect(response.usage.outputTokens == 100)
                    #expect(response.usage.cacheWriteInputTokens == sample.1)
                    #expect(response.usage.cacheWriteTTL == sample.2)
                    // Replay the actual sparse final, not a reconstructed complete value.
                    let final = UsageObservation(identity: identity, usage: .init(outputTokens: 100), status: .finalized)
                    #expect(accumulator.record(final).accepted)
                    #expect(await ledger.record(final).accepted)
                    #expect(accumulator.record(final).disposition == .duplicate)
                    #expect(await ledger.record(final).disposition == .duplicate)
                    #expect(try JSONDecoder().decode(ModelUsage.self, from: JSONEncoder().encode(response.usage)) == response.usage)
                default: break
                }
            }
            #expect(try stream.finish().usage.cacheWriteTTL == sample.2)
            #expect(await ledger.summary(identity: identity).totalTokens == 15_100)
        }
        let summary = await ledger.summary()
        #expect(summary == accumulator.summary())
        #expect(summary.totalTokens == 90_600)
        #expect(summary.cacheWriteInputTokens.reportedSubtotal == 39_000)
        #expect(summary.cacheWriteTTL?.fiveMinuteTokens.reportedSubtotal == 19_000)
        #expect(summary.cacheWriteTTL?.oneHourTokens.reportedSubtotal == 16_000)
        #expect(summary.cacheWriteTTL?.fiveMinuteTokens.missingCount == 1)
        #expect(summary.cacheWriteTTL?.oneHourTokens.missingCount == 2)
        #expect(try JSONDecoder().decode(UsageSummary.self, from: JSONEncoder().encode(summary)) == summary)
    }

    @Test func sparseNativeTTLUpdatesAndNullKeepEarlierCategories() async throws {
        let initial: [String: JSONValue] = ["input_tokens": .number(0), "cache_read_input_tokens": .number(12_000),
            "cache_creation_input_tokens": .number(3_000), "cache_creation": .object(["ephemeral_5m_input_tokens": .number(2_000)])]
        let body = String(decoding: try fixture(usage: initial), as: UTF8.self).replacingOccurrences(
            of: #""usage":{"output_tokens":100}"#,
            with: #""usage":{"output_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":null,"ephemeral_1h_input_tokens":1000}}"#)
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(
            probe: ProviderRequestProbe(), bodies: [Data(body.utf8)]))
        var stream = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: .init(provider: "anthropic", name: "fixture"),
            messages: [.user([.text("Hi")])])) { try stream.append(event) }
        let usage = try stream.finish().usage
        #expect(usage.inputTokens == 15_000)
        #expect(usage.cacheWriteInputTokens == 3_000)
        #expect(usage.cacheWriteTTL == .init(fiveMinuteTokens: 2_000, oneHourTokens: 1_000))
    }

    @Test func missingNullPartialAndInconsistentReportsRemainObservable() async throws {
        let samples: [[String: JSONValue]] = [
            ["input_tokens": .number(5), "output_tokens": .number(0)],
            ["input_tokens": .number(5), "cache_read_input_tokens": .null, "cache_creation_input_tokens": .null, "cache_creation": .null],
            ["input_tokens": .number(5), "cache_read_input_tokens": .number(0), "cache_creation": .object(["ephemeral_5m_input_tokens": .number(3)])],
            ["input_tokens": .number(5), "cache_read_input_tokens": .number(0), "cache_creation_input_tokens": .number(3),
                "cache_creation": .object(["ephemeral_5m_input_tokens": .number(2), "ephemeral_1h_input_tokens": .number(2)])],
        ]
        for (index, native) in samples.enumerated() {
            let result = try await decoded(native)
            if index < 3 { #expect(result.inputTokens == nil) }
            else {
                // Keep raw metering; pricing must diagnose aggregate/breakdown mismatch.
                #expect(result.inputTokens == 8)
                #expect(result.cacheWriteInputTokens == 3)
                #expect(result.cacheWriteTTL == .init(fiveMinuteTokens: 2, oneHourTokens: 2))
            }
        }
        let nullDetail = try await decoded(["input_tokens": .number(5), "cache_read_input_tokens": .number(0),
            "cache_creation_input_tokens": .number(0), "cache_creation": .object(["ephemeral_5m_input_tokens": .null, "ephemeral_1h_input_tokens": .number(0)])])
        #expect(nullDetail.cacheWriteTTL == .init(oneHourTokens: 0))
        #expect(nullDetail.inputTokens == 5)
    }

    @Test func malformedTTLCountsUseExistingInvalidResponseContract() async throws {
        for field in ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"] {
            for invalid in [JSONValue.string("3"), .bool(true), .number(-1), .number(1.5),
                .number(Decimal(Int.max) + 1), .array([]), .object([:])] {
                do {
                    _ = try await decoded(["input_tokens": .number(5), "cache_read_input_tokens": .number(0),
                        "cache_creation_input_tokens": .number(3), "cache_creation": .object([field: invalid])])
                    Issue.record("Accepted malformed TTL count")
                } catch let error as ModelProviderError { #expect(error.kind == .invalidResponse) }
            }
        }
    }

    private func decoded(_ usage: [String: JSONValue]) async throws -> ModelUsage {
        let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(
            probe: ProviderRequestProbe(), bodies: [try fixture(usage: usage)]))
        var stream = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: .init(provider: "anthropic", name: "fixture"),
            messages: [.user([.text("Hi")])])) { try stream.append(event) }
        return try stream.finish().usage
    }

    private func fixture(usage: [String: JSONValue]) throws -> Data {
        let start: JSONValue = .object(["type": .string("message_start"), "message": .object([
            "id": .string("msg-ttl"), "type": .string("message"), "role": .string("assistant"),
            "model": .string("fixture"), "content": .array([]), "usage": .object(usage)])])
        return providerSSE([try ProviderJSON.text(start),
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":100}}"#,
            #"{"type":"message_stop"}"#])
    }
}
