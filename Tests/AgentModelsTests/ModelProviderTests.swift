import AgentModels
import Testing

struct ModelProviderTests {
    private let model = ModelID(provider: "fixture", name: "calculator")

    @Test func fakeProviderHandlesModelTurnsThroughExistentialProtocol() async throws {
        let provider: any ModelProvider = FixtureProvider()
        #expect(provider.descriptor.id == "fixture")
        #expect(provider.descriptor.capabilities.isSuperset(of: [.streaming, .tools, .multiTurn]))
        let first = try await collect(provider.stream(request: .init(
            model: model, messages: [.user([.text("Add 2 and 3")])]
        )))
        #expect(first.stopReason == .toolCalls)
        #expect(first.toolCalls.map(\.name) == ["calculator"])
        let result = ToolResultMessage(callID: first.toolCalls[0].id, content: [.json(.number(5))], isError: false)
        let second = try await collect(provider.stream(request: .init(
            model: model, messages: [.assistant(content: first.content, toolCalls: first.toolCalls), .tool(result)]
        )))
        #expect(second.stopReason == .endTurn)
        #expect(second.content == [.text("5")])
    }

    private func collect(_ events: AsyncThrowingStream<ModelEvent, Error>) async throws -> ModelResponse {
        try Task.checkCancellation()
        var accumulator = ModelEventAccumulator()
        for try await event in events {
            try Task.checkCancellation()
            try accumulator.append(event)
        }
        try Task.checkCancellation()
        return try accumulator.finish()
    }

    @Test func classifiedFailureSurvivesStreamWithoutAutomaticRetry() async throws {
        let failure = ModelProviderError(kind: .rateLimited, message: "Retry later", retryAfter: .seconds(2))
        let stream = AsyncThrowingStream<ModelEvent, Error> { $0.finish(throwing: failure) }
        await #expect(throws: failure) { try await collect(stream) }
        #expect(failure.kind == .rateLimited)
        #expect(failure.retryAfter == .seconds(2))
        #expect(ModelProviderError(kind: .authentication, message: "Credentials rejected").retryAfter == nil)
    }
}

private struct FixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .tools, .multiTurn])

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let info = ResponseInfo(id: "fixture-response", model: request.model)
            continuation.yield(.responseStarted(info))
            if case .tool(let result) = request.messages.last {
                #expect(result.callID.rawValue == "calc-1")
                #expect(result.content == [.json(.number(5))])
                continuation.yield(.textDelta("5"))
                continuation.yield(.responseCompleted(.init(info: info, content: [.text("5")], stopReason: .endTurn)))
            } else {
                let call = ToolCall(id: .init(rawValue: "calc-1"), name: "calculator",
                                    argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)
                continuation.yield(.toolCallStarted(call.id, name: call.name))
                continuation.yield(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                continuation.yield(.toolCallCompleted(call))
                continuation.yield(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            }
            continuation.finish()
        }
    }
}
