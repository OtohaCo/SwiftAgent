import AgentModels
import Foundation
import Testing
@testable import AgentProviders

struct OpenAIResponsesStreamDecoderTests {
    @Test func queuedLifecycleEmitsExactlyOneLogicalStart() throws {
        let response = try decode([
            ("response.queued", lifecycle("resp-queued", status: "queued", type: "response.queued")),
            ("response.created", lifecycle("resp-queued", status: "in_progress")),
            messageAdded(),
            contentPartAdded(text: "Hello"),
            ("response.output_item.done", messageDone(text: "Hello")),
            completed(responseID: "resp-queued", output: [messageOutput(text: "Hello")]),
        ])
        #expect(response.content == [.text("Hello")])
    }

    @Test func zeroDeltaAndInitialNonEmptyPartPreserveContent() throws {
        let response = try decode([
            ("response.created", lifecycle("resp-initial", status: "in_progress")),
            messageAdded(),
            contentPartAdded(text: "Initial"),
            outputTextDelta(""),
            ("response.output_text.done", outputTextDone("Initial")),
            ("response.output_item.done", messageDone(text: "Initial")),
            completed(responseID: "resp-initial", output: [messageOutput(text: "Initial")]),
        ])
        #expect(response.content == [.text("Initial")])
    }

    @Test func interleavedItemsPreserveCanonicalContentOrder() throws {
        let response = try decode([
            ("response.created", lifecycle("resp-interleaved", status: "in_progress")),
            messageAdded(id: "msg-1", outputIndex: 0),
            contentPartAdded(itemID: "msg-1", outputIndex: 0, text: ""),
            reasoningAdded(id: "rs-1", outputIndex: 1),
            reasoningSummaryPartAdded(itemID: "rs-1", outputIndex: 1),
            outputTextDelta("A", itemID: "msg-1", outputIndex: 0),
            reasoningDelta("B", itemID: "rs-1", outputIndex: 1),
            outputTextDelta("C", itemID: "msg-1", outputIndex: 0),
            ("response.output_item.done", messageDone(id: "msg-1", outputIndex: 0, text: "AC")),
            ("response.output_item.done", reasoningDone(id: "rs-1", outputIndex: 1, text: "B")),
            completed(responseID: "resp-interleaved", output: [
                messageOutput(id: "msg-1", outputIndex: 0, text: "AC"),
                reasoningOutput(id: "rs-1", outputIndex: 1, text: "B"),
            ]),
        ])
        #expect(response.content == [.text("A"), .reasoning("B"), .text("C")])
    }

    @Test func arbitrarySSEChunkBoundariesPreserveMultibyteUTF8() throws {
        let body = providerNamedSSE([
            ("response.created", lifecycle("resp-utf8", status: "in_progress")),
            messageAdded(id: "msg-utf8"),
            contentPartAdded(itemID: "msg-utf8", text: ""),
            outputTextDelta("こんにちは", itemID: "msg-utf8"),
            ("response.output_item.done", messageDone(id: "msg-utf8", text: "こんにちは")),
            completed(responseID: "resp-utf8", output: [messageOutput(id: "msg-utf8", text: "こんにちは")]),
        ])
        let response = try decodeRaw(body, chunkSize: 1)
        #expect(response.content == [.text("こんにちは")])
    }

    @Test func deterministicRandomChunkBoundariesPreserveStream() throws {
        let body = providerNamedSSE([
            ("response.created", lifecycle("resp-random", status: "in_progress")),
            messageAdded(id: "msg-random"),
            contentPartAdded(itemID: "msg-random", text: ""),
            outputTextDelta("prefix-", itemID: "msg-random"),
            outputTextDelta("こんにちは-", itemID: "msg-random"),
            outputTextDelta("suffix", itemID: "msg-random"),
            ("response.output_item.done", messageDone(id: "msg-random", text: "prefix-こんにちは-suffix")),
            completed(responseID: "resp-random", output: [
                messageOutput(id: "msg-random", text: "prefix-こんにちは-suffix"),
            ]),
        ])

        for seed in UInt64(1)...UInt64(32) {
            var state = seed
            var lengths: [Int] = []
            for _ in 0..<64 {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                lengths.append(Int(state % 7) + 1)
            }
            let response = try decodeRaw(body, chunkLengths: lengths)
            #expect(response.content == [.text("prefix-こんにちは-suffix")])
        }
    }

    @Test func ghostItemDeltaAndDuplicateItemIdentityFailClosed() {
        let ghost = [
            ("response.created", lifecycle("resp-ghost", status: "in_progress")),
            messageAdded(id: "msg-1"),
            outputTextDelta("INJECTED Hello", itemID: "ghost", outputIndex: 7),
        ]
        #expect(throws: ModelProviderError.self) { try decode(ghost) }

        let duplicate = [
            ("response.created", lifecycle("resp-duplicate", status: "in_progress")),
            messageAdded(id: "same-id", outputIndex: 0),
            messageAdded(id: "same-id", outputIndex: 1),
        ]
        #expect(throws: ModelProviderError.self) { try decode(duplicate) }
    }

    @Test func duplicateOrConflictingPartLifecycleFailsClosed() {
        let duplicateAdd = [
            ("response.created", lifecycle("resp-parts", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: ""),
            contentPartAdded(itemID: "msg-1", text: ""),
        ]
        #expect(throws: ModelProviderError.self) { try decode(duplicateAdd) }

        let duplicateDone = [
            ("response.created", lifecycle("resp-parts", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: "Hello"),
            ("response.content_part.done", contentPartDone(itemID: "msg-1", text: "Hello")),
            ("response.content_part.done", contentPartDone(itemID: "msg-1", text: "Hello")),
        ]
        #expect(throws: ModelProviderError.self) { try decode(duplicateDone) }

        let conflictingSeed = [
            ("response.created", lifecycle("resp-parts", status: "in_progress")),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"in_progress","content":[{"type":"output_text","text":"Original","annotations":[]}]}}"#),
            contentPartAdded(itemID: "msg-1", text: "Different"),
        ]
        #expect(throws: ModelProviderError.self) { try decode(conflictingSeed) }
    }

    @Test func deltasAfterFinalizationAndMismatchedDonePayloadsFailClosed() {
        let deltaAfterDone = [
            ("response.created", lifecycle("resp-order", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: ""),
            outputTextDelta("Hello", itemID: "msg-1"),
            ("response.output_text.done", outputTextDone("Hello")),
            outputTextDelta("!", itemID: "msg-1"),
        ]
        #expect(throws: ModelProviderError.self) { try decode(deltaAfterDone) }

        let textMismatch = [
            ("response.created", lifecycle("resp-mismatch", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: ""),
            outputTextDelta("Hello", itemID: "msg-1"),
            ("response.output_text.done", outputTextDone("Hullo")),
        ]
        #expect(throws: ModelProviderError.self) { try decode(textMismatch) }

        let itemMismatch = [
            ("response.created", lifecycle("resp-mismatch", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: ""),
            outputTextDelta("Hello", itemID: "msg-1"),
            ("response.output_item.done", messageDone(id: "msg-1", text: "Hullo")),
        ]
        #expect(throws: ModelProviderError.self) { try decode(itemMismatch) }

        let finalMismatch = [
            ("response.created", lifecycle("resp-mismatch", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: "Hello"),
            ("response.output_item.done", messageDone(id: "msg-1", text: "Hello")),
            completed(responseID: "resp-mismatch", output: [messageOutput(id: "msg-1", text: "Hullo")]),
        ]
        #expect(throws: ModelProviderError.self) { try decode(finalMismatch) }
    }

    @Test func completedReasoningMustPreserveEncryptedContent() {
        let frames = [
            ("response.created", lifecycle("resp-encrypted", status: "in_progress")),
            reasoningAdded(id: "rs-1"),
            reasoningSummaryPartAdded(itemID: "rs-1"),
            reasoningDelta("Checked", itemID: "rs-1"),
            ("response.output_item.done", reasoningDone(id: "rs-1", text: "Checked", encrypted: "a")),
            completed(responseID: "resp-encrypted", output: [reasoningOutput(id: "rs-1", text: "Checked", encrypted: "b")]),
        ]
        #expect(throws: ModelProviderError.self) { try decode(frames) }
    }

    @Test func sequenceNumbersMustBeIntegerAndStrictlyIncreasing() {
        let duplicate = [
            ("response.created", #"{"type":"response.created","sequence_number":1,"response":{"id":"resp-seq","model":"fixture","status":"in_progress"}}"#),
            ("response.future_event", #"{"type":"response.future_event","sequence_number":1}"#),
        ]
        #expect(throws: ModelProviderError.self) { try decode(duplicate) }

        let regression = [
            ("response.created", #"{"type":"response.created","sequence_number":2,"response":{"id":"resp-seq","model":"fixture","status":"in_progress"}}"#),
            ("response.future_event", #"{"type":"response.future_event","sequence_number":1}"#),
        ]
        #expect(throws: ModelProviderError.self) { try decode(regression) }
    }

    @Test func unknownActiveEventIsIgnoredButPostTerminalEventFails() throws {
        let active = try decode([
            ("response.created", lifecycle("resp-unknown", status: "in_progress")),
            ("response.future_metadata", #"{"type":"response.future_metadata","future":{"safe":true}}"#),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: "Hello"),
            ("response.output_item.done", messageDone(id: "msg-1", text: "Hello")),
            completed(responseID: "resp-unknown", output: [messageOutput(id: "msg-1", text: "Hello")]),
        ])
        #expect(active.content == [.text("Hello")])

        let trailing = [
            ("response.created", lifecycle("resp-unknown", status: "in_progress")),
            messageAdded(id: "msg-1"),
            contentPartAdded(itemID: "msg-1", text: "Hello"),
            ("response.output_item.done", messageDone(id: "msg-1", text: "Hello")),
            completed(responseID: "resp-unknown", output: [messageOutput(id: "msg-1", text: "Hello")]),
            ("response.future_metadata", #"{"type":"response.future_metadata","future":{"safe":true}}"#),
        ]
        #expect(throws: ModelProviderError.self) { try decode(trailing) }
    }

    private func decode(_ frames: [(String, String)]) throws -> ModelResponse {
        try decodeRaw(providerNamedSSE(frames))
    }

    private func decodeRaw(_ body: Data, chunkSize: Int = .max) throws -> ModelResponse {
        try decodeRaw(body) { _, remaining in min(chunkSize, remaining) }
    }

    private func decodeRaw(_ body: Data, chunkLengths: [Int]) throws -> ModelResponse {
        var chunkIndex = 0
        return try decodeRaw(body) { _, remaining in
            let value = chunkLengths[chunkIndex % chunkLengths.count]
            chunkIndex += 1
            return min(value, remaining)
        }
    }

    private func decodeRaw(
        _ body: Data,
        nextChunkSize: (_ offset: Int, _ remaining: Int) -> Int
    ) throws -> ModelResponse {
        var sse = try ProviderSSEDecoder()
        var decoder = OpenAIResponsesStreamDecoder(model: model)
        var accumulator = ModelEventAccumulator()
        var offset = 0
        while offset < body.count {
            let end = min(offset + max(1, nextChunkSize(offset, body.count - offset)), body.count)
            for frame in try sse.consume(body.subdata(in: offset..<end)) {
                for event in try decoder.consume(frame) { try accumulator.append(event) }
            }
            offset = end
        }
        try sse.finish()
        try decoder.finish()
        return try accumulator.finish()
    }

    private var model: ModelID { .init(provider: "openai", name: "fixture") }

    private func lifecycle(
        _ id: String,
        status: String,
        type: String = "response.created"
    ) -> String {
        #"{"type":"\#(type)","response":{"id":"\#(id)","model":"fixture","status":"\#(status)"}}"#
    }

    private func messageAdded(id: String = "msg-1", outputIndex: Int = 0) -> (String, String) {
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":\#(outputIndex),"item":{"id":"\#(id)","type":"message","role":"assistant","status":"in_progress","content":[]}}"#)
    }

    private func contentPartAdded(itemID: String = "msg-1", outputIndex: Int = 0, text: String) -> (String, String) {
        ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"\#(itemID)","output_index":\#(outputIndex),"content_index":0,"part":{"type":"output_text","text":"\#(text)","annotations":[]}}"#)
    }

    private func outputTextDelta(_ delta: String, itemID: String = "msg-1", outputIndex: Int = 0) -> (String, String) {
        ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"\#(itemID)","output_index":\#(outputIndex),"content_index":0,"delta":"\#(delta)"}"#)
    }

    private func outputTextDone(_ text: String, itemID: String = "msg-1", outputIndex: Int = 0) -> String {
        #"{"type":"response.output_text.done","item_id":"\#(itemID)","output_index":\#(outputIndex),"content_index":0,"text":"\#(text)"}"#
    }

    private func contentPartDone(itemID: String = "msg-1", outputIndex: Int = 0, text: String) -> String {
        #"{"type":"response.content_part.done","item_id":"\#(itemID)","output_index":\#(outputIndex),"content_index":0,"part":{"type":"output_text","text":"\#(text)","annotations":[]}}"#
    }

    private func messageDone(id: String = "msg-1", outputIndex: Int = 0, text: String) -> String {
        #"{"type":"response.output_item.done","output_index":\#(outputIndex),"item":{"id":"\#(id)","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}}"#
    }

    private func messageOutput(id: String = "msg-1", outputIndex: Int = 0, text: String) -> String {
        #"{"id":"\#(id)","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"\#(text)","annotations":[]}]}"#
    }

    private func reasoningAdded(id: String = "rs-1", outputIndex: Int = 0) -> (String, String) {
        ("response.output_item.added", #"{"type":"response.output_item.added","output_index":\#(outputIndex),"item":{"id":"\#(id)","type":"reasoning","summary":[]}}"#)
    }

    private func reasoningSummaryPartAdded(itemID: String = "rs-1", outputIndex: Int = 0) -> (String, String) {
        ("response.reasoning_summary_part.added", #"{"type":"response.reasoning_summary_part.added","item_id":"\#(itemID)","output_index":\#(outputIndex),"summary_index":0,"part":{"type":"summary_text","text":""}}"#)
    }

    private func reasoningDelta(_ text: String, itemID: String = "rs-1", outputIndex: Int = 0) -> (String, String) {
        ("response.reasoning_summary_text.delta", #"{"type":"response.reasoning_summary_text.delta","item_id":"\#(itemID)","output_index":\#(outputIndex),"summary_index":0,"delta":"\#(text)"}"#)
    }

    private func reasoningDone(
        id: String = "rs-1",
        outputIndex: Int = 0,
        text: String,
        encrypted: String? = nil
    ) -> String {
        var encryptedField = ""
        if let encrypted { encryptedField = #", "encrypted_content":"\#(encrypted)""# }
        return #"{"type":"response.output_item.done","output_index":\#(outputIndex),"item":{"id":"\#(id)","type":"reasoning","summary":[{"type":"summary_text","text":"\#(text)"}]\#(encryptedField)}}"#
    }

    private func reasoningOutput(
        id: String = "rs-1",
        outputIndex: Int = 0,
        text: String,
        encrypted: String? = nil
    ) -> String {
        var encryptedField = ""
        if let encrypted { encryptedField = #", "encrypted_content":"\#(encrypted)""# }
        return #"{"id":"\#(id)","type":"reasoning","summary":[{"type":"summary_text","text":"\#(text)"}]\#(encryptedField)}"#
    }

    private func completed(responseID: String, output: [String]) -> (String, String) {
        ("response.completed", #"{"type":"response.completed","response":{"id":"\#(responseID)","model":"fixture","status":"completed","output":[\#(output.joined(separator: ","))],"usage":{"input_tokens":5,"output_tokens":3}}}"#)
    }
}
