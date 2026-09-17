import AgentModels
import Foundation
import XCTest

final class ModelMetadataTests: XCTestCase {
    func testCapabilitiesSupportRequirementMatchingWithoutVendorBranches() throws {
        let available: ModelCapabilities = [.streaming, .multiTurn, .tools, .structuredOutput]
        XCTAssertTrue(available.isSuperset(of: [.tools, .structuredOutput]))
        XCTAssertFalse(available.contains(.reasoning))
        let future = available.union(.init(rawValue: 1 << 40))
        XCTAssertEqual(try JSONDecoder().decode(ModelCapabilities.self, from: JSONEncoder().encode(future)), future)
    }

    func testUsagePreservesMissingVersusZeroAndCacheAccounting() throws {
        let usage = ModelUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 70,
                               cacheWriteInputTokens: 10, reasoningTokens: 5)
        XCTAssertEqual(try JSONDecoder().decode(ModelUsage.self, from: JSONEncoder().encode(usage)), usage)
        let missing = ModelUsage()
        XCTAssertNil(missing.inputTokens)
        XCTAssertNil(missing.outputTokens)
        XCTAssertNotEqual(missing, ModelUsage(inputTokens: 0, outputTokens: 0))
        XCTAssertEqual(usage.cachedInputTokens, 70)
        XCTAssertEqual(usage.cacheWriteInputTokens, 10)
        XCTAssertEqual(usage.reasoningTokens, 5)
    }

    func testStopReasonsPreserveTruncationRefusalAndUnknownValues() throws {
        let reasons: [StopReason] = [.endTurn, .toolCalls, .maxOutputTokens, .stopSequence,
                                      .refusal, .cancelled, .unknown("new-provider-reason")]
        XCTAssertEqual(try JSONDecoder().decode([StopReason].self, from: JSONEncoder().encode(reasons)), reasons)
        XCTAssertNotEqual(StopReason.endTurn, .maxOutputTokens)
        XCTAssertNotEqual(StopReason.endTurn, .unknown("new-provider-reason"))
    }
}
