import AgentModels
import Foundation
import Testing
@testable import AgentProviders

/// How each adapter sends images (ADR 0012): natively where it can, and an explicit failure where it cannot.
struct ImageContentProviderTests {
    private static func png(width: Int = 4, height: Int = 3) throws -> ModelImage {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data.append(contentsOf: Array("IHDR".utf8))
        for value in [width, height] { data.append(contentsOf: [0, 0, UInt8(value >> 8), UInt8(value & 0xFF)]) }
        data.append(contentsOf: [8, 2, 0, 0, 0, 0, 0, 0, 0])
        return try ModelImage(data: data, description: "A screenshot of the settings window")
    }

    private static let call = ToolCall(id: .init(rawValue: "call-1"), name: "screenshot",
                                       argumentsJSON: "{}", completeness: .complete)

    private static func request(provider: String, image: ModelImage) -> ModelRequest {
        .init(model: .init(provider: provider, name: "fixture"), messages: [
            .user([.text("Look at this"), .image(image)]),
            .assistant(content: [], toolCalls: [call]),
            .tool(.init(callID: call.id, content: [.json(.object(["window": .string("Settings")])), .image(image)], isError: false)),
        ])
    }

    @Test func anthropicSendsImagesAsBase64BlocksInUserTurnsAndToolResults() throws {
        let image = try Self.png()
        guard case .object(let body) = try AnthropicRequestEncoder.encode(
            Self.request(provider: "anthropic", image: image), maximumOutputTokens: 64, thinking: .disabled),
              case .array(let messages) = body["messages"], messages.count == 3,
              case .object(let user) = messages[0], case .object(let toolTurn) = messages[2],
              case .array(let toolBlocks) = toolTurn["content"], case .object(let result) = toolBlocks.first else {
            Issue.record("Missing Anthropic messages"); return
        }
        let block = JSONValue.object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/png"),
            "data": .string(image.data.base64EncodedString()),
        ])])
        #expect(user["content"] == .array([.object(["type": .string("text"), "text": .string("Look at this")]), block]))
        #expect(result["content"] == .array([.object(["type": .string("text"), "text": .string(#"{"window":"Settings"}"#)]), block]))
        #expect(try AnthropicProvider(apiKey: "k").descriptor.capabilities.contains(.imageInput))
    }

    @Test func openAIResponsesSendsImagesAsInputImageDataURLs() throws {
        let image = try Self.png()
        guard case .object(let body) = try OpenAIResponsesRequestEncoder.encode(
            Self.request(provider: "openai", image: image), maximumOutputTokens: 64,
            reasoningEffort: nil, reasoningSummary: nil),
              case .array(let input) = body["input"], input.count == 3,
              case .object(let user) = input[0], case .object(let output) = input[2] else {
            Issue.record("Missing Responses input"); return
        }
        let part = JSONValue.object(["type": .string("input_image"),
                                     "image_url": .string("data:image/png;base64,\(image.data.base64EncodedString())")])
        #expect(user["content"] == .array([.object(["type": .string("input_text"), "text": .string("Look at this")]), part]))
        #expect(output["type"] == .string("function_call_output"))
        #expect(output["output"] == .array([.object(["type": .string("input_text"), "text": .string(#"{"window":"Settings"}"#)]), part]))
        #expect(try OpenAIResponsesProvider(apiKey: "k").descriptor.capabilities.contains(.imageInput))
    }

    @Test func aLocalResponsesServerSendsImagesOnlyWhenConfiguredTo() throws {
        let image = try Self.png()
        let url = try #require(URL(string: "http://127.0.0.1:1234/v1"))
        let plain = try LocalResponsesProvider(configuration: .init(baseURL: url, model: "fixture", capabilities: [.tools]))
        #expect(!plain.descriptor.capabilities.contains(.imageInput))
        #expect(throws: ModelProviderError.self) {
            try plain.validate(request: Self.request(provider: plain.descriptor.id, image: image))
        }
        do {
            try plain.validate(request: Self.request(provider: plain.descriptor.id, image: image))
        } catch let error as ModelProviderError {
            #expect(error.kind == .unsupportedCapability)
        }
        let vision = try LocalResponsesProvider(configuration: .init(baseURL: url, model: "fixture", capabilities: [.tools, .imageInput]))
        #expect(vision.descriptor.capabilities.contains(.imageInput))
        try vision.validate(request: Self.request(provider: vision.descriptor.id, image: image))
    }

    @Test func deepSeekRefusesImagesBeforeSending() throws {
        let provider = try DeepSeekResponsesProvider(apiKey: "k")
        #expect(!provider.descriptor.capabilities.contains(.imageInput))
        do {
            try provider.validate(request: Self.request(provider: "deepseek", image: Self.png()))
            Issue.record("DeepSeek accepted an image")
        } catch let error as ModelProviderError {
            #expect(error.kind == .unsupportedCapability)
        }
    }

    @Test func anAssistantMessageCarryingAnImageIsRefused() throws {
        let image = try Self.png()
        let messages: [ModelMessage] = [.user([.text("Hi")]), .assistant(content: [.image(image)], toolCalls: []), .user([.text("Again")])]
        #expect(throws: ModelProviderError.self) {
            try AnthropicRequestEncoder.encode(.init(model: .init(provider: "anthropic", name: "f"), messages: messages),
                                               maximumOutputTokens: 64, thinking: .disabled)
        }
        #expect(throws: ModelProviderError.self) {
            try OpenAIResponsesRequestEncoder.encode(.init(model: .init(provider: "openai", name: "f"), messages: messages),
                                                     maximumOutputTokens: 64, reasoningEffort: nil, reasoningSummary: nil)
        }
    }

    @Test func requestsWithoutImagesKeepTheirTextShapes() throws {
        let request = ModelRequest(model: .init(provider: "openai", name: "f"), messages: [
            .user([.text("Hi")]), .assistant(content: [], toolCalls: [Self.call]),
            .tool(.init(callID: Self.call.id, content: [.text("done")], isError: false)),
        ])
        guard case .object(let body) = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 64,
                                                                               reasoningEffort: nil, reasoningSummary: nil),
              case .array(let input) = body["input"], case .object(let user) = input[0], case .object(let output) = input[2] else {
            Issue.record("Missing input"); return
        }
        #expect(user["content"] == .string("Hi"))
        #expect(output["output"] == .string("done"))
    }
}
