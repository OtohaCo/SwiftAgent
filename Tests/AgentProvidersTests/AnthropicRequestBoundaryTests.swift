import AgentModels
import Foundation
import Testing
@testable import AgentProviders
#if canImport(ImageIO)
import ImageIO
#endif

struct AnthropicRequestBoundaryTests {
    @Test func completeEncodedBodyIsRejectedBeforeTransport() async throws {
        let request = ModelRequest(model: .init(provider: "anthropic", name: "fixture"), messages: [.user([.text(String(repeating: "x", count: 32_000_001))])])
        let body = try ProviderJSON.encode(AnthropicRequestEncoder.encode(request, maximumOutputTokens: 64, thinking: .disabled))
        print("RC6 body oversize bytes=\(body.count)")
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "k", maximumOutputTokens: 64, transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        do {
            for try await _ in provider.stream(request: request) {}
            Issue.record("Oversize body reached transport")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await probe.requests.isEmpty)
        #expect(throws: ModelProviderError.self) { try provider.validate(request: request) }
    }

    @Test func signedThinkingRejectsChangedToolsAndEarlierMessages() async throws {
        let model = ModelID(provider: "anthropic", name: "fixture")
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "k", transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture]))
        var accumulated = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: model, messages: [.user([.text("Compute")])])) { try accumulated.append(event) }
        let response = try accumulated.finish()
        let messages: [ModelMessage] = [.user([.text("Compute")]), .assistant(content: response.content, toolCalls: response.toolCalls), .tool(.init(callID: response.toolCalls[0].id, content: [.text("5")], isError: false))]
        let changed = ModelRequest(model: model, messages: messages, tools: [.init(name: "new_tool", description: "deferred", inputSchema: .object(["type": .string("object")]))])
        do {
            for try await _ in provider.stream(request: changed) {}
            Issue.record("Changed signed-thinking prefix reached transport")
        } catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await probe.requests.count == 1)
    }
    private func image(bytes: Int) throws -> ModelImage {
        // A complete 1x1 PNG with a legal ancillary text chunk, including its real CRC.
        let original = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let padding = bytes - original.count - 12
        var chunk = Data("tEXt".utf8)
        chunk.append(contentsOf: Array("padding\0".utf8))
        chunk.append(Data(repeating: 120, count: padding - 8))
        let table = (0..<256).map { value -> UInt32 in
            var crc = UInt32(value)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            return crc
        }
        var crc: UInt32 = 0xffffffff
        for byte in chunk { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 255)] }
        crc ^= 0xffffffff
        func bigEndian(_ value: UInt32) -> Data { var value = value.bigEndian; return withUnsafeBytes(of: &value) { Data($0) } }
        var data = Data(original.prefix(33))
        data.append(bigEndian(UInt32(padding)))
        data.append(chunk)
        data.append(bigEndian(crc))
        data.append(original.dropFirst(33))
        #expect(data.count == bytes)
        #if canImport(ImageIO)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 1 && decoded.height == 1)
        #endif
        return try ModelImage(data: data, description: "valid padded PNG")
    }

    @Test func legalImageTotalsAndMixedExactBodyBoundary() async throws {
        let model = ModelID(provider: "anthropic", name: "fixture")
        let threeMiB = try image(bytes: 3 * 1024 * 1024)
        let twoMiB = try image(bytes: 2 * 1024 * 1024)
        let twentyFour = Array(repeating: ModelContent.image(threeMiB), count: 8)
        let twenty = Array(repeating: ModelContent.image(threeMiB), count: 6) + [.image(twoMiB)]
        let tools: [ModelToolDefinition] = [.init(name: "tool", description: "quote \" newline\n", inputSchema: .object(["type": .string("object"), "description": .string("schema \" \n")]))]
        let requests = [
            ModelRequest(model: model, messages: [.user(twentyFour)]),
            ModelRequest(model: model, messages: [.system(String(repeating: "s", count: 6_000_000)), .user(twenty)], tools: tools),
        ]
        for request in requests {
            let body = try ProviderJSON.encode(AnthropicRequestEncoder.encode(request, maximumOutputTokens: 64, thinking: .disabled))
            print("RC6 legal image count=\(request.messages.flatMap(\.images).count) raw=\(request.messages.flatMap(\.images).reduce(0) { $0 + $1.byteCount }) body=\(body.count)")
            #expect(body.count > 32_000_000)
            let probe = ProviderRequestProbe()
            let provider = try AnthropicProvider(apiKey: "k", maximumOutputTokens: 64, transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
            do { for try await _ in provider.stream(request: request) {}; Issue.record("Legal raw images exceeded whole body limit") }
            catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
            #expect(await probe.requests.isEmpty)
        }
        func mixed(_ text: String) -> ModelRequest {
            .init(model: model, messages: [.system("important constraint \"\n"), .user([.image(twoMiB), .text(text)])], tools: tools,
                  structuredOutput: .init(name: "result", schema: .object(["type": .string("object")])))
        }
        let overhead = try ProviderJSON.encode(AnthropicRequestEncoder.encode(mixed(""), maximumOutputTokens: 64, thinking: .disabled)).count
        let exact = mixed(String(repeating: "x", count: 32_000_000 - overhead))
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "k", maximumOutputTokens: 64, transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
        try provider.validate(request: exact)
        for try await _ in provider.stream(request: exact) {}
        #expect(await probe.requests.first?.httpBody?.count == 32_000_000)
        let excessive = mixed(String(repeating: "x", count: 32_000_001 - overhead))
        do { for try await _ in provider.stream(request: excessive) {}; Issue.record("One byte over limit dispatched") }
        catch let error as ModelProviderError { #expect(error.kind == .invalidRequest) }
        #expect(await probe.requests.count == 1)
        print("RC6 mixed exact body=32000000 accepted transports=1; body=32000001 rejected transports=1")
    }

}
