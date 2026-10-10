import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

/// An answer the model source handed over whole before the Run's deadline is complete. The deadline
/// only decides whether a Run that has no such answer yet ran out of time.
struct AgentSettledAnswerDeadlineTests {
    /// The answer arrives well before the deadline, but the stream is only closed after it.
    private func providerClosingLate(after delay: Duration, text: String = "the whole answer") -> any ModelProvider {
        ScriptedProvider { request, _ in
            let info = ResponseInfo(id: "response", model: request.model)
            return [.responseStarted(info), .textDelta(text),
                    .responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn))]
        }.delayingStreamEnd(by: delay)
    }

    @Test func answerReceivedBeforeTheDeadlineCompletesWhenTheStreamClosesAfterIt() async throws {
        let provider = providerClosingLate(after: .milliseconds(600))
        let session = try Agent(model: fixtureModel, provider: provider,
                                configuration: .init(runTimeout: .milliseconds(300))).makeSession()
        let run = try await session.run("Answer")
        let result = try await run.wait()
        #expect(result.outcome == .completed)
        #expect(result.response.content == [.text("the whole answer")])
        let history = await session.history
        #expect(history.last == .assistant(content: [.text("the whole answer")], toolCalls: []))
    }

    @Test func answerTheModelSourceHandedOverBeforeTheDeadlineCompletesWhenTheRunReadsItLate() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "the whole answer") }
        // The model source has sent everything at once; the Run gets to the first event after the deadline.
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []),
                             beforeHandlingModelEvent: { event in
            if case .responseStarted = event { try? await Task.sleep(for: .milliseconds(600)) }
        })
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 0, deadline: .now.advanced(by: .milliseconds(300)))
        let result = try await loop.run(messages: [ModelMessage.user([.text("Answer")])], sessionID: UUID(), budget: budget)
        #expect(result.outcome == .completed)
        #expect(result.history.last == .assistant(content: [.text("the whole answer")], toolCalls: []))
    }

    @Test func aRunWithoutAnAnswerByTheDeadlineStillTimesOut() async throws {
        let provider = ScriptedProvider { request, _ in
            let info = ResponseInfo(id: "response", model: request.model)
            try await Task.sleep(for: .seconds(5))
            return [.responseStarted(info), .responseCompleted(.init(info: info, content: [.text("late")], stopReason: .endTurn))]
        }
        let session = try Agent(model: fixtureModel, provider: provider,
                                configuration: .init(runTimeout: .milliseconds(300))).makeSession()
        let run = try await session.run("Answer")
        await #expect(throws: AgentLoopError.deadlineExceeded) { _ = try await run.wait() }
        let history = await session.history
        #expect(!history.contains { if case .assistant = $0 { true } else { false } })
    }
}

extension ScriptedProvider {
    /// Same events, but the stream only finishes `delay` after the last of them.
    func delayingStreamEnd(by delay: Duration) -> any ModelProvider {
        DelayedEndProvider(inner: self, delay: delay)
    }
}

private struct DelayedEndProvider: ModelProvider {
    let inner: ScriptedProvider
    let delay: Duration
    var descriptor: ModelProviderDescriptor { inner.descriptor }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        let upstream = inner.stream(request: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream { continuation.yield(event) }
                    try await Task.sleep(for: delay)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
