import AgentModels
import Foundation
import Testing
@testable import ReplanningEvalTrial

struct CacheUsageExportTests {
    @Test func trialDTOExportsTTLDetailsAndPreservesPartialAndLegacyUnknown() throws {
        for detail: CacheWriteTTLUsage? in [.init(fiveMinuteTokens: 2_000, oneHourTokens: 1_000),
            .init(fiveMinuteTokens: 0, oneHourTokens: 0), .init(fiveMinuteTokens: 2_000), nil] {
            let usage = ModelUsage(inputTokens: 15_000, outputTokens: 100, cachedInputTokens: 12_000,
                cacheWriteInputTokens: 3_000, cacheWriteTTL: detail)
            let bytes = try JSONEncoder().encode(ResponseUsage(usage))
            let exported = try JSONDecoder().decode(ResponseUsage.self, from: bytes)
            #expect(exported.cacheWriteTTL == detail)
            #expect(exported.cacheWriteInputTokens == 3_000)
        }
        #expect(try JSONDecoder().decode(ResponseUsage.self,
            from: Data(#"{"inputTokens":15,"outputTokens":1}"#.utf8)).cacheWriteTTL == nil)
        // Preserve the original public ModelUsage initializer as a stored function.
        let original: (Int?, Int?, Int?, Int?, Int?) -> ModelUsage = ModelUsage.init
        #expect(original(15_000, 100, 12_000, 3_000, 0).cacheWriteTTL == nil)
    }

    @Test func trialDTOExportsReportedCacheWritesAndKeepsAbsenceDistinctFromZero() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for count in [Optional(3_000), 0, nil] {
            let original = ModelUsage(inputTokens: 15_000, outputTokens: 100,
                cachedInputTokens: 12_000, cacheWriteInputTokens: count, reasoningTokens: 0)
            let bytes = try encoder.encode(ResponseUsage(original))
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["cacheWriteInputTokens"] as? Int == count)
            #expect(object["cachedInputTokens"] as? Int == 12_000)
            let decoded = try JSONDecoder().decode(ResponseUsage.self, from: bytes)
            #expect(try encoder.encode(decoded) == bytes)
        }
    }
}
