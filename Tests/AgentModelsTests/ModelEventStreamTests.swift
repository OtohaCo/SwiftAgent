import AgentModels
import Testing

struct ModelEventStreamTests {
    private let info = ResponseInfo(id: "async-response", model: .init(provider: "fixture", name: "calculator"))

    @Test func asyncFixtureReplaysOutsideActorIsolation() async throws {
        let response = ModelResponse(info: info, content: [.text("5")], stopReason: .endTurn)
        let events: [ModelEvent] = [.responseStarted(info), .textDelta("5"), .responseCompleted(response)]
        let result = try await Task.detached {
            let stream = AsyncThrowingStream<ModelEvent, Error> { continuation in
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
            var accumulator = ModelEventAccumulator()
            for try await event in stream { try accumulator.append(event) }
            return try accumulator.finish()
        }.value
        #expect(result == response)
    }

    @Test func eofAtEveryPrefixOfToolResponseCannotBecomeACompleteResponse() throws {
        let call = ToolCall(id: .init(rawValue: "c1"), name: "calculator", argumentsJSON: "{}", completeness: .complete)
        let response = ModelResponse(info: info, toolCalls: [call], stopReason: .toolCalls)
        let events: [ModelEvent] = [
            .responseStarted(info), .toolCallStarted(call.id, name: call.name),
            .toolCallArgumentsDelta(call.id, "{"), .toolCallArgumentsDelta(call.id, "}"),
            .toolCallCompleted(call), .responseCompleted(response),
        ]
        for count in 0..<events.count {
            var accumulator = ModelEventAccumulator()
            for event in events.prefix(count) { try accumulator.append(event) }
            #expect(throws: ModelStreamError.missingTerminal) { try accumulator.finish() }
        }
    }

    @Test func transportErrorPropagatesEvenAfterTerminalEvent() async throws {
        enum TransportError: Error { case disconnected }
        let stream = AsyncThrowingStream<ModelEvent, Error> { continuation in
            continuation.yield(.responseStarted(info))
            continuation.yield(.responseCompleted(.init(info: info, stopReason: .endTurn)))
            continuation.finish(throwing: TransportError.disconnected)
        }
        await #expect(throws: TransportError.self) {
            var accumulator = ModelEventAccumulator()
            for try await event in stream { try accumulator.append(event) }
            return try accumulator.finish()
        }
    }
}
