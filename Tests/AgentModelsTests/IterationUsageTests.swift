import Foundation
import Testing
@testable import AgentModels

@Suite struct IterationUsageTests {
    @Test func completeChildrenAggregateOncePartialStaysUnknown() throws {
        let first = try ModelUsageIteration(ordinal: 0, kind: "compaction", model: .init(provider: "anthropic", name: "fixture"), inputTokens: 120, outputTokens: 4, cachedInputTokens: 20, cacheWriteInputTokens: 0)
        let second = try ModelUsageIteration(ordinal: 1, kind: "message", inputTokens: 30, outputTokens: 8, cachedInputTokens: 0, cacheWriteInputTokens: 0)
        let complete = try ModelIterationUsage(iterations: [first, second], coverage: .complete)
        #expect(try complete.aggregate().inputTokens == 150)
        #expect(try complete.aggregate().outputTokens == 12)
        #expect(try complete.aggregate().cachedInputTokens == 20)
        let partial = try ModelIterationUsage(iterations: [first], coverage: .partial)
        #expect(try partial.aggregate().inputTokens == nil)
        #expect(try JSONDecoder().decode(ModelIterationUsage.self, from: JSONEncoder().encode(complete)) == complete)
        #expect(throws: (any Error).self) { try ModelIterationUsage(iterations: [first, first], coverage: .complete) }
    }
    @Test func contradictoryCacheSubsetsReject() throws {
        #expect(throws: (any Error).self) { try ModelUsageIteration(ordinal: 0, kind: "message", inputTokens: 100, cachedInputTokens: 80, cacheWriteInputTokens: 80) }
        #expect(throws: (any Error).self) { try ModelUsageIteration(ordinal: 0, kind: "message", cacheWriteInputTokens: 10, cacheWriteTTL: .init(fiveMinuteTokens: 20)) }
    }
    @Test func usageSnapshotsReplaceDetailsAndMissingPreserves() throws {
        let info = ResponseInfo(id: "fixture", model: .init(provider: "custom", name: "model"))
        let one = try ModelUsageIteration(ordinal: 0, kind: "future", inputTokens: 4, outputTokens: 2)
        let populated = try ModelIterationUsage(iterations: [one], coverage: .partial)
        let empty = try ModelIterationUsage(iterations: [], coverage: .partial)
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(info))
        try accumulator.append(.usage(.init(inputTokens: 4, outputTokens: 2, iterationUsage: populated)))
        try accumulator.append(.usage(.init(outputTokens: 3)))
        try accumulator.append(.usage(.init(iterationUsage: empty)))
        let final = ModelUsage(inputTokens: 4, outputTokens: 3, iterationUsage: empty)
        try accumulator.append(.responseCompleted(.init(info: info, usage: final, stopReason: .endTurn)))
        #expect(try accumulator.finish().usage.iterationUsage == empty)
        let old = Data(#"{"inputTokens":3,"outputTokens":1}"#.utf8)
        #expect(try JSONDecoder().decode(ModelUsage.self, from: old).iterationUsage == nil)
    }
}
