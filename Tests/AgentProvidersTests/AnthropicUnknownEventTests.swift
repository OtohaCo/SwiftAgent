import AgentCore
import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicUnknownEventTests {
    @Test(arguments: ["after-start", "inside-block", "before-delta"])
    func unknownTopLevelEventsAreIgnoredWithoutEndingTheBlock(insertion: String) async throws {
        let future = #"{"type":"future_event","future_field":{"x":1}}"#
        let original = String(decoding: anthropicTextFixture, as: UTF8.self)
        let spliced: String
        switch insertion {
        case "after-start":
            spliced = original.replacingOccurrences(
                of: "data: {\"type\":\"content_block_start\"",
                with: "data: \(future)\n\ndata: {\"type\":\"content_block_start\""
            )
        case "inside-block":
            spliced = original.replacingOccurrences(
                of: "data: {\"type\":\"content_block_delta\"",
                with: "data: \(future)\n\ndata: {\"type\":\"content_block_delta\""
            )
        default:
            spliced = original.replacingOccurrences(
                of: "data: {\"type\":\"message_delta\"",
                with: "data: \(future)\n\ndata: {\"type\":\"message_delta\""
            )
        }
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(spliced.utf8)])
        )
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider)
            .makeSession()
            .run("Hi")
            .wait()
        #expect(result.outcome == .completed)
        #expect(result.response.content.contains(.text("Hello")))
    }

    @Test func knownEventWithIllegalStructureStillFails() async throws {
        let original = String(decoding: anthropicTextFixture, as: UTF8.self)
        let illegal = original.replacingOccurrences(
            of: #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
            with: #"{"type":"content_block_delta","index":0}"#
        )
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(illegal.utf8)])
        )
        do {
            _ = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider)
                .makeSession()
                .run("Hi")
                .wait()
            Issue.record("Illegal known event must fail")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .invalidResponse)
        }
    }

    @Test func unknownDeltaTypeInsideAKnownEventStillFails() async throws {
        let original = String(decoding: anthropicTextFixture, as: UTF8.self)
        let illegal = original.replacingOccurrences(
            of: #"{"type":"text_delta","text":"Hello"}"#,
            with: #"{"type":"future_delta","text":"Hello"}"#
        )
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(illegal.utf8)])
        )
        do {
            _ = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider)
                .makeSession()
                .run("Hi")
                .wait()
            Issue.record("Unknown delta.type must not be ignored")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .invalidResponse)
        }
    }

    @Test func matchingNamedEventAndDataTypePass() async throws {
        let original = String(decoding: anthropicTextFixture, as: UTF8.self)
        let named = original.replacingOccurrences(
            of: #"data: {"type":"message_start""#,
            with: "event: message_start\ndata: {\"type\":\"message_start\""
        )
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(named.utf8)])
        )
        let result = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider)
            .makeSession().run("Hi").wait()
        #expect(result.outcome == .completed)
    }

    @Test func mismatchedNamedEventAndDataTypeFailClosed() async throws {
        let original = String(decoding: anthropicTextFixture, as: UTF8.self)
        let mismatched = original.replacingOccurrences(
            of: #"data: {"type":"message_start""#,
            with: "event: content_block_delta\ndata: {\"type\":\"message_start\""
        )
        try await expectInvalidResponse(mismatched)
    }

    @Test func unknownSemanticEventAfterMessageStopFailsClosed() async throws {
        let original = String(decoding: anthropicTextFixture, as: UTF8.self)
        let trailing = original + "event: future_event\ndata: {\"type\":\"future_event\"}\n\n"
        try await expectInvalidResponse(trailing)
    }

    private func expectInvalidResponse(_ body: String) async throws {
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(body.utf8)])
        )
        do {
            _ = try await Agent(model: .init(provider: "anthropic", name: "fixture"), provider: provider)
                .makeSession().run("Hi").wait()
            Issue.record("Malformed named Anthropic event must fail")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .invalidResponse)
        }
    }
}
