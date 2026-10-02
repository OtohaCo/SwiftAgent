import AgentProviders
import Foundation
import Testing

/// A Host transport that reads failed responses itself, before the provider sees them, recognizes a
/// context overflow by the same rules as the built-in adapters, through the public API only.
struct ContextOverflowPublicTests {
    @Test func lmStudioHTTP500IsAnOverflow() {
        let body = #"{"error":{"code":"unknown","type":"internal_error","message":"The number of tokens to keep from the initial prompt is greater than the context length (n_keep: 5012 >= n_ctx: 4096)."}}"#
        #expect(ProviderContextOverflow.isOverflow(httpStatus: 500, body: Data(body.utf8), signals: .responses))
    }

    @Test func openAIAndLlamaServerHTTP400AreOverflows() {
        let openAI = #"{"error":{"message":"This model's maximum context length is 8192 tokens.","type":"invalid_request_error","code":"context_length_exceeded"}}"#
        let llama = #"{"error":{"code":400,"message":"the request exceeds the available context size","type":"exceed_context_size_error"}}"#
        #expect(ProviderContextOverflow.isOverflow(httpStatus: 400, body: Data(openAI.utf8), signals: .responses))
        #expect(ProviderContextOverflow.isOverflow(httpStatus: 400, body: Data(llama.utf8), signals: .responses))
    }

    @Test func anthropicPromptTooLongIsAnOverflow() {
        let body = #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long: 203073 tokens > 200000 maximum"}}"#
        #expect(ProviderContextOverflow.isOverflow(httpStatus: 400, body: Data(body.utf8), signals: .anthropic))
        #expect(!ProviderContextOverflow.isOverflow(httpStatus: 400, body: Data(body.utf8), signals: .responses))
    }

    @Test func otherFailuresAreNot() {
        let overflow = Data(#"{"error":{"code":"context_length_exceeded","message":"too long"}}"#.utf8)
        #expect(!ProviderContextOverflow.isOverflow(httpStatus: 429, body: overflow, signals: .responses), "only 400 and 500 carry it")
        #expect(!ProviderContextOverflow.isOverflow(httpStatus: 400, body: Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8), signals: .responses))
        #expect(!ProviderContextOverflow.isOverflow(httpStatus: 500, body: Data("not json".utf8), signals: .responses))
        var long = overflow
        long.append(Data(repeating: 0x20, count: 64 * 1_024))
        #expect(!ProviderContextOverflow.isOverflow(httpStatus: 400, body: long, signals: .responses), "a body over 64 KiB is not read")
    }
}
