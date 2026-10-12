import Foundation

enum Fixtures {
    private static func anthropic(_ values: [String]) -> Data {
        Data(values.map { "data: \($0)\n\n" }.joined().utf8)
    }
    private static func openAI(_ values: [String]) -> Data {
        Data(values.enumerated().map { ordinal, value in
            // Fixture event names are read from their actual type field.
            var fields = try! JSONSerialization.jsonObject(with: Data(value.utf8)) as! [String: Any]
            fields["sequence_number"] = ordinal
            let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
            return "event: \(fields["type"]!)\ndata: \(encoded)\n\n"
        }.joined().utf8)
    }
    static let anthropicAnswer = anthropic([
        #"{"type":"message_start","message":{"id":"answer","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"中文回答"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
        #"{"type":"message_stop"}"#])
    static let anthropicThinkingAnswer = anthropic([
        #"{"type":"message_start","message":{"id":"answer","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Fixture reasoning, not signature validation."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"fixture-thinking-signature"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"中文回答"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}"#,
        #"{"type":"message_stop"}"#])
    static let anthropicCompact = anthropic([
        #"{"type":"message_start","message":{"id":"summary","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":0,"output_tokens":0,"iterations":[]}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"compaction","content":"Native summary, not an answer","signature":"fixture-compaction-signature","tool_changes":[]}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"compaction"},"usage":{"iterations":[{"type":"compaction","input_tokens":1000,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}]}}"#,
        #"{"type":"message_stop"}"#])
    static let anthropicThinkingDiscovery = anthropic([
        #"{"type":"message_start","message":{"id":"discovery","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#,
        #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Fixture reasoning, not signature validation."}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"fixture-thinking-signature"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
        #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"discovery-call","name":"discover","input":{}}}"#,
        #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"value\":1}"}}"#,
        #"{"type":"content_block_stop","index":1}"#,
        #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
        #"{"type":"message_stop"}"#])
    static let openAIAnswer = openAI([
        #"{"type":"response.created","response":{"id":"answer","model":"fixture","status":"in_progress"}}"#,
        #"{"type":"response.output_item.added","output_index":0,"item":{"id":"message","type":"message","role":"assistant","status":"in_progress","content":[]}}"#,
        #"{"type":"response.content_part.added","item_id":"message","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#,
        #"{"type":"response.output_text.delta","item_id":"message","output_index":0,"content_index":0,"delta":"answer"}"#,
        #"{"type":"response.output_item.done","output_index":0,"item":{"id":"message","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer","annotations":[]}]}}"#,
        #"{"type":"response.completed","response":{"id":"answer","model":"fixture","status":"completed","output":[{"id":"message","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"answer","annotations":[]}]}],"usage":{"input_tokens":5,"output_tokens":3}}}"#])
    static let openAIAutomaticTool = openAI([
        #"{"type":"response.created","response":{"id":"automatic","model":"fixture","status":"in_progress"}}"#,
        #"{"type":"response.output_item.added","output_index":0,"item":{"type":"compaction","id":"compact-item","encrypted_content":""}}"#,
        #"{"type":"response.output_item.done","output_index":0,"item":{"type":"compaction","id":"compact-item","encrypted_content":"opaque-openai-window"}}"#,
        #"{"type":"response.output_item.added","output_index":1,"item":{"id":"function","type":"function_call","call_id":"native-call","name":"discover","arguments":"","status":"in_progress"}}"#,
        #"{"type":"response.function_call_arguments.delta","item_id":"function","output_index":1,"delta":"{\"value\":1}"}"#,
        #"{"type":"response.function_call_arguments.done","item_id":"function","output_index":1,"arguments":"{\"value\":1}"}"#,
        #"{"type":"response.output_item.done","output_index":1,"item":{"id":"function","type":"function_call","call_id":"native-call","name":"discover","arguments":"{\"value\":1}","status":"completed"}}"#,
        #"{"type":"response.completed","response":{"id":"automatic","model":"fixture","status":"completed","output":[{"type":"compaction","id":"compact-item","encrypted_content":"opaque-openai-window"},{"id":"function","type":"function_call","call_id":"native-call","name":"discover","arguments":"{\"value\":1}","status":"completed"}],"usage":{"input_tokens":100,"output_tokens":4}}}"#])
}
