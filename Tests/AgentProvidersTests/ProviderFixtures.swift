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
    var headers: [String: String] = ["Content-Type": "text/event-stream"]

    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let index = await probe.record(request) - 1
                guard bodies.indices.contains(index) else {
                    continuation.finish(throwing: ModelProviderError(kind: .transport, message: "Fixture responses exhausted."))
                    return
                }
                continuation.yield(.response(status: status, headers: headers))
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

func providerNamedSSE(_ frames: [(String, String)]) -> Data {
    let sequenced = frames.enumerated().map { index, frame -> String in
        guard let value = try? JSONValue.decodeToolArguments(frame.1),
              case .object(var object) = value else {
            return frame.1
        }
        if object["sequence_number"] == nil {
            object["sequence_number"] = .number(Decimal(index))
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(object)) else { return frame.1 }
        return String(decoding: data, as: UTF8.self)
    }
    return Data(sequenced.enumerated().map { "event: \(frames[$0.offset].0)\ndata: \($0.element)\n\n" }.joined().utf8)
}

let openAITextFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-1","model":"fixture","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
    ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
    ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"Hello"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-1","model":"fixture","status":"completed","incomplete_details":null,"output":[{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello","annotations":[]}]}],"usage":{"input_tokens":5,"input_tokens_details":{"cached_tokens":2},"output_tokens":3,"output_tokens_details":{"reasoning_tokens":1},"total_tokens":8}}}"#),
])

let openAIToolFixture = providerNamedSSE([
    ("response.created", #"{"type":"response.created","response":{"id":"resp-tool","model":"fixture","status":"in_progress"}}"#),
    ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"","status":"in_progress"}}"#),
    ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"{\"a\":2,"}"#),
    ("response.function_call_arguments.delta", #"{"type":"response.function_call_arguments.delta","item_id":"fc-1","output_index":0,"delta":"\"b\":3}"}"#),
    ("response.function_call_arguments.done", #"{"type":"response.function_call_arguments.done","item_id":"fc-1","output_index":0,"arguments":"{\"a\":2,\"b\":3}"}"#),
    ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}}"#),
    ("response.completed", #"{"type":"response.completed","response":{"id":"resp-tool","model":"fixture","status":"completed","incomplete_details":null,"output":[{"id":"fc-1","type":"function_call","call_id":"call-1","name":"calculator","arguments":"{\"a\":2,\"b\":3}","status":"completed"}],"usage":{"input_tokens":5,"output_tokens":4,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":9}}}"#),
])

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
