import Foundation
import AgentModels
import AgentProviders
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

actor ProviderRequestProbe {
    private(set) var requests: [URLRequest] = []
    @discardableResult
    func record(_ request: URLRequest) -> Int { requests.append(request); return requests.count }
}

struct FixtureHTTPTransport: ProviderHTTPTransport {
    let probe: ProviderRequestProbe
    let bodies: [Data]
    var status = 200

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let index = await probe.record(request) - 1
                guard bodies.indices.contains(index) else {
                    continuation.finish(throwing: ModelProviderError(kind: .transport, message: "Fixture responses exhausted."))
                    return
                }
                continuation.yield(.response(status: status, headers: ["Content-Type": "text/event-stream"]))
                continuation.yield(.data(bodies[index]))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

func providerSSE(_ frames: [String]) -> Data {
    Data(frames.map { "data: " + $0 + "\n\n" }.joined().utf8)
}

let anthropicTextFixture = providerSSE([
    #"{"type":"message_start","message":{"id":"msg-1","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
    #"{"type":"content_block_stop","index":0}"#,
    #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
    #"{"type":"message_stop"}"#,
])

let anthropicToolFixture = providerSSE([
    #"{"type":"message_start","message":{"id":"msg-tool","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu-1","name":"calculator","input":{}}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"a\":2,"}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\"b\":3}"}}"#,
    #"{"type":"content_block_stop","index":0}"#,
    #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
    #"{"type":"message_stop"}"#,
])

let anthropicThinkingToolFixture = providerSSE([
    #"{"type":"message_start","message":{"id":"msg-thinking","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":0}}}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Consider inputs."}}"#,
    #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signature-1"}}"#,
    #"{"type":"content_block_stop","index":0}"#,
    #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu-1","name":"calculator","input":{}}}"#,
    #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\":2,\"b\":3}"}}"#,
    #"{"type":"content_block_stop","index":1}"#,
    #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7,"output_tokens_details":{"thinking_tokens":2}}}"#,
    #"{"type":"message_stop"}"#,
])
