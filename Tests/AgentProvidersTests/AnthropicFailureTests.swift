import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct AnthropicFailureTests {
    @Test func invalidStartLateContentAndSignatureMutationFailClosed() async throws {
        let text = String(decoding: anthropicTextFixture, as: UTF8.self)
        let late = String(decoding: providerSSE([
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Late"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_stop"}"#,
        ]), as: UTF8.self)
        let marker = "data: {\"type\":\"message_stop\"}\n\n"
        let thinking = String(decoding: anthropicThinkingToolFixture, as: UTF8.self)
        let changed = String(decoding: providerSSE([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" changed"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
        ]), as: UTF8.self)
        let bodies = [
            text.replacingOccurrences(of: #""id":"msg-1""#, with: #""id":"""#),
            text.replacingOccurrences(of: #""role":"assistant""#, with: #""role":"user""#),
            text.replacingOccurrences(of: #""content":[]"#, with: #""content":[{"type":"text","text":"Injected"}]"#),
            "event: error\n" + text,
            text.replacingOccurrences(of: marker, with: late),
            thinking.replacingOccurrences(of: "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n", with: changed),
        ]
        for body in bodies {
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: [Data(body.utf8)]))
            do {
                for try await _ in provider.stream(request: request) {}
                Issue.record("Malformed stream must fail")
            } catch { #expect((error as? ModelProviderError)?.kind == .invalidResponse) }
        }
    }

    @Test func responseCannotSilentlyChangeTheRequestedModelIdentity() async throws {
        let mismatched = String(decoding: anthropicTextFixture, as: UTF8.self)
            .replacingOccurrences(of: #""model":"fixture""#, with: #""model":"other-model""#)
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [Data(mismatched.utf8)]
            )
        )

        do {
            for try await _ in provider.stream(request: request) {}
            Issue.record("A response from another model must fail closed")
        } catch {
            #expect((error as? ModelProviderError)?.kind == .invalidResponse)
        }
    }

    @Test func explicitlyConfiguredLegacyAliasAcceptsOnlyItsResolvedModel() async throws {
        let resolved = String(decoding: anthropicTextFixture, as: UTF8.self)
            .replacingOccurrences(of: #""model":"fixture""#, with: #""model":"fixture-20260919""#)
        let provider = try AnthropicProvider(
            apiKey: "fixture-key",
            resolvedModelIDsByAlias: ["fixture": "fixture-20260919"],
            transport: FixtureHTTPTransport(
                probe: ProviderRequestProbe(),
                bodies: [Data(resolved.utf8)]
            )
        )

        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: request) {
            try accumulator.append(event)
        }
        #expect(try accumulator.finish().info.model == request.model)
    }

    @Test func providerDiagnosticsNeverPrintCredentials() throws {
        let provider = try AnthropicProvider(apiKey: "fixture-secret")
        #expect(!String(describing: provider).contains("fixture-secret"))
        #expect(!String(reflecting: provider).contains("fixture-secret"))
        #expect(!Mirror(reflecting: provider).children.contains { String(reflecting: $0.value).contains("fixture-secret") })
    }

    @Test func httpErrorsAreClassifiedWithoutEchoingResponseBodies() async throws {
        for (status, kind) in [(401, ModelProviderError.Kind.authentication), (403, .permissionDenied),
                               (429, .rateLimited), (500, .unavailable), (400, .invalidRequest)] {
            let probe = ProviderRequestProbe()
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe,
                bodies: [Data("private server diagnostic".utf8)], status: status))
            do {
                for try await _ in provider.stream(request: request) {}
                Issue.record("HTTP failure must terminate the request")
            } catch {
                #expect((error as? ModelProviderError)?.kind == kind)
                #expect((error as? ModelProviderError)?.message.contains("private") == false)
            }
            #expect(await probe.requests.count == 1)
        }
    }

    @Test func nativeErrorEventsDoNotBecomeSuccessfulResponses() async throws {
        for (type, kind) in [("overloaded_error", ModelProviderError.Kind.unavailable),
                             ("rate_limit_error", .rateLimited), ("authentication_error", .authentication)] {
            let probe = ProviderRequestProbe()
            let body = providerSSE(["{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"private diagnostic\"}}"])
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [body]))
            do {
                for try await _ in provider.stream(request: request) {}
                Issue.record("Native failure must terminate the request")
            } catch {
                #expect((error as? ModelProviderError)?.kind == kind)
                #expect((error as? ModelProviderError)?.message.contains("private") == false)
            }
        }
    }

    @Test func insecureOrInvalidConfigurationFailsBeforeNetworking() throws {
        for value in ["http://example.com/v1/messages", "file:///tmp/messages", "https://user:password@example.com/v1/messages"] {
            let endpoint = try #require(URL(string: value))
            #expect(throws: ModelProviderError.self) { try AnthropicProvider(apiKey: "fixture-key", endpoint: endpoint) }
        }
    }

    private var request: ModelRequest { .init(model: .init(provider: "anthropic", name: "fixture"), messages: [.user([.text("Hi")])]) }

    @Test func requestEncodingRejectsUnsupportedInstructionPlacementAndInvalidJSONWithoutSending() async throws {
        let cases: [([ModelMessage], ModelProviderError.Kind)] = [
            ([.user([.text("Hi")]), .system("Later instruction")], .unsupportedCapability),
            ([.user([.text("Hi")]), .developer("Later instruction")], .unsupportedCapability),
            ([.user([.json(.number(.nan))])], .invalidRequest),
            ([], .invalidRequest),
        ]
        for (messages, kind) in cases {
            let probe = ProviderRequestProbe()
            let provider = try AnthropicProvider(apiKey: "fixture-key", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
            do {
                for try await _ in provider.stream(request: .init(model: request.model, messages: messages)) {}
                Issue.record("Invalid request must fail before HTTP")
            } catch { #expect((error as? ModelProviderError)?.kind == kind) }
            #expect(await probe.requests.isEmpty)
        }
    }
}
