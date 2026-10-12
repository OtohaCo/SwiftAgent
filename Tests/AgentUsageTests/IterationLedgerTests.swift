import AgentModels
import AgentUsage
import Foundation
import Testing

@Suite struct IterationLedgerTests {
    @Test func tableReplacementIsObservableAndFinalizedConflictIsNotDuplicate() throws {
        var ledger = UsageAccumulator()
        let id = UsageRecordIdentity(source: .modelResponse, invocationID: "one-http", model: .init(provider: "fixture", name: "model"))
        let one = try ModelIterationUsage(iterations: [.init(ordinal: 0, kind: "compaction", inputTokens: 10, outputTokens: 2)], coverage: .partial)
        let replaced = try ModelIterationUsage(iterations: [.init(ordinal: 1, kind: "future", inputTokens: 10, outputTokens: 2)], coverage: .partial)
        let cleared = try ModelIterationUsage(iterations: [], coverage: .partial)
        #expect(ledger.record(.init(identity: id, usage: .init(inputTokens: 10, outputTokens: 2, iterationUsage: one), status: .provisional)).disposition == .inserted)
        #expect(ledger.record(.init(identity: id, usage: .init(iterationUsage: replaced), status: .provisional)).disposition == .updated)
        #expect(ledger.record(.init(identity: id, usage: .init(iterationUsage: cleared), status: .provisional)).disposition == .updated)
        #expect(ledger.record(.init(identity: id, usage: .init(iterationUsage: cleared), status: .finalized)).disposition == .updated)
        #expect(ledger.record(.init(identity: id, usage: .init(inputTokens: 10, outputTokens: 2), status: .finalized)).disposition == .duplicate)
        #expect(ledger.record(.init(identity: id, usage: .init(iterationUsage: one), status: .finalized)).disposition == .rejected)
        #expect(ledger.summary().observedResponseCount == 1)
        #expect(ledger.summary().totalTokens == 12)
    }
    @Test func exactOldUsageFunctionSignaturesRemainAvailable() {
        let old: (Int?, Int?, Int?, Int?, Int?) -> ModelUsage = ModelUsage.init
        let ttl: (Int?, Int?, Int?, Int?, Int?, CacheWriteTTLUsage?) -> ModelUsage = ModelUsage.init
        #expect(old(1, 2, nil, nil, nil).iterationUsage == nil)
        #expect(ttl(1, 2, nil, nil, nil, nil).iterationUsage == nil)
    }
}
