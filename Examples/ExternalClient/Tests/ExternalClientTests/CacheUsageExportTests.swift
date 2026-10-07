import AgentModels
import Foundation
import Testing
@testable import ReplanningEvalTrial

struct CacheUsageExportTests {
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
