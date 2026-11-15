import AgentModels
import Foundation
import Testing
@testable import AgentProviders

/// Host-supplied summarization instructions for Anthropic native compaction.
@Suite struct AnthropicCompactionInstructionsTests {
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let request = ModelRequest(model: .init(provider: "anthropic", name: "fixture"), messages: [.user([.text("hello")])])

    private func configuration(threshold: Bool) throws -> AnthropicNativeContextConfiguration {
        let qualification = try NativeContextQualification(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicThreshold, .anthropicOnDemand])
        return try .init(qualification: qualification,
            automatic: threshold ? .init(mode: .anthropicThreshold, triggerInputTokens: 50_000, pauseAfterCompaction: true) : nil)
    }

    private func body(_ configuration: AnthropicNativeContextConfiguration, threshold: Bool) throws -> String {
        let configured = try AnthropicNativeContext.configure(.object(["model": .string("fixture")]), request: request,
            mode: threshold ? nil : .anthropicOnDemand, configuration: configuration, endpoint: endpoint,
            resolvedModelName: "fixture", thinking: .disabled)
        return String(decoding: try ProviderJSON.encode(configured), as: UTF8.self)
    }

    /// Without instructions the request bytes stay exactly what they were before the option existed.
    @Test(arguments: [false, true])
    func withoutInstructionsTheBodyIsUnchanged(_ threshold: Bool) throws {
        let expected = threshold
            ? #"{"context_management":{"edits":[{"pause_after_compaction":true,"trigger":{"type":"input_tokens","value":50000},"type":"compact_20260112"}]},"model":"fixture"}"#
            : #"{"compaction":{"type":"summarize"},"model":"fixture"}"#
        #expect(try body(configuration(threshold: threshold), threshold: threshold) == expected)
    }

    @Test(arguments: [false, true])
    func instructionsReachBothCompactionShapes(_ threshold: Bool) throws {
        let configured = try configuration(threshold: threshold).withCompactionInstructions("Keep the open steps.\nDo not call tools.")
        #expect(configured.compactionInstructions == "Keep the open steps.\nDo not call tools.")
        let expected = threshold
            ? #"{"context_management":{"edits":[{"instructions":"Keep the open steps.\nDo not call tools.","pause_after_compaction":true,"trigger":{"type":"input_tokens","value":50000},"type":"compact_20260112"}]},"model":"fixture"}"#
            : #"{"compaction":{"instructions":"Keep the open steps.\nDo not call tools.","type":"summarize"},"model":"fixture"}"#
        #expect(try body(configured, threshold: threshold) == expected)
    }

    @Test(arguments: ["", "  \n\t", String(repeating: "x", count: AnthropicNativeContextConfiguration.maximumCompactionInstructionsLength + 1)])
    func blankOrOverlongInstructionsAreRefused(_ text: String) throws {
        #expect(throws: ModelProviderError.self) { try configuration(threshold: false).withCompactionInstructions(text) }
    }

    @Test func longestAllowedInstructionsAreAccepted() throws {
        let text = String(repeating: "x", count: AnthropicNativeContextConfiguration.maximumCompactionInstructionsLength)
        #expect(try configuration(threshold: false).withCompactionInstructions(text).compactionInstructions == text)
        #expect(AnthropicNativeContextConfiguration.maximumCompactionInstructionsLength == 16_384)
    }

    @Test func instructionsSurviveCodingAndOlderRecordsDecodeWithout() throws {
        let configured = try configuration(threshold: true).withCompactionInstructions("Keep the open steps.")
        let decoded = try JSONDecoder().decode(AnthropicNativeContextConfiguration.self, from: JSONEncoder().encode(configured))
        #expect(decoded == configured)
        let plain = try configuration(threshold: true)
        let plainData = try JSONEncoder().encode(plain)
        #expect(!String(decoding: plainData, as: UTF8.self).contains("compactionInstructions"))
        #expect(try JSONDecoder().decode(AnthropicNativeContextConfiguration.self, from: plainData).compactionInstructions == nil)
    }

    @Test func clearingInstructionsRestoresTheOriginalConfiguration() throws {
        let plain = try configuration(threshold: false)
        #expect(try plain.withCompactionInstructions("x").withCompactionInstructions(nil) == plain)
    }
}
