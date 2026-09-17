import AgentModels
import Testing

struct ModelUsageStreamTests {
    private let info = ResponseInfo(id: "usage", model: .init(provider: "fixture", name: "test"))

    @Test func eachReportedCumulativeCounterCannotDecrease() throws {
        let counters: [(Int) -> ModelUsage] = [
            { .init(inputTokens: $0) }, { .init(outputTokens: $0) }, { .init(cachedInputTokens: $0) },
            { .init(cacheWriteInputTokens: $0) }, { .init(reasoningTokens: $0) },
        ]
        for counter in counters {
            var stream = ModelEventAccumulator()
            try stream.append(.responseStarted(info))
            try stream.append(.usage(counter(40)))
            try stream.append(.usage(.init()))
            #expect(throws: ModelStreamError.invalidUsage) { try stream.append(.usage(counter(5))) }
            #expect(throws: ModelStreamError.invalidUsage) { try stream.finish() }
        }
    }

    @Test func terminalRejectsSubsetsExceedingReportedTotals() throws {
        for usage in [
            ModelUsage(inputTokens: 10, cachedInputTokens: 11),
            .init(inputTokens: 10, cacheWriteInputTokens: 11),
            .init(outputTokens: 2, reasoningTokens: 3),
        ] {
            var stream = ModelEventAccumulator()
            try stream.append(.responseStarted(info))
            try stream.append(.usage(usage))
            #expect(throws: ModelStreamError.invalidUsage) {
                try stream.append(.responseCompleted(.init(info: info, usage: usage, stopReason: .endTurn)))
            }
            #expect(throws: ModelStreamError.invalidUsage) { try stream.finish() }
        }
    }

    @Test func increasingCountsAndNilPreservePreviouslyReportedValues() throws {
        let expected = ModelUsage(inputTokens: 10, outputTokens: 4, cachedInputTokens: 2, cacheWriteInputTokens: 1, reasoningTokens: 3)
        #expect(try replay([
            .init(inputTokens: 10, outputTokens: 1, cachedInputTokens: 1, cacheWriteInputTokens: 0, reasoningTokens: 0),
            .init(outputTokens: 4, cachedInputTokens: 2, cacheWriteInputTokens: 1, reasoningTokens: 3), .init(),
        ], terminal: expected) == expected)
    }

    @Test func zeroAbsentAndDelayedTotalsRetainTheirDistinctMeanings() throws {
        let zero = ModelUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, reasoningTokens: 0)
        #expect(try replay([zero], terminal: zero) == zero)
        let subsets = ModelUsage(cachedInputTokens: 8, cacheWriteInputTokens: 2, reasoningTokens: 3)
        #expect(try replay([subsets], terminal: subsets) == subsets)
        #expect(try replay([], terminal: .init()) == .init())
        let final = ModelUsage(inputTokens: 10, outputTokens: 4, cachedInputTokens: 8, cacheWriteInputTokens: 2, reasoningTokens: 3)
        #expect(try replay([.init(inputTokens: 1, outputTokens: 1), subsets, .init(inputTokens: 10, outputTokens: 4)], terminal: final) == final)
    }

    private func replay(_ snapshots: [ModelUsage], terminal: ModelUsage) throws -> ModelUsage {
        var stream = ModelEventAccumulator()
        try stream.append(.responseStarted(info))
        for snapshot in snapshots { try stream.append(.usage(snapshot)) }
        try stream.append(.responseCompleted(.init(info: info, usage: terminal, stopReason: .endTurn)))
        return try stream.finish().usage
    }
}
