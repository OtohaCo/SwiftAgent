@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

/// A Run that reports its model requests carries one bounded record for each, failed and stopped ones
/// included, so a Host can count and price every request without a second journal.
struct ModelRequestRecordTests {
    @Test func everyRequestOfARunIsRecordedOnceBeforeItsResponseCompletes() async throws {
        let first = ModelUsage(inputTokens: 1_200, outputTokens: 30, cachedInputTokens: 1_000,
                               cacheWriteInputTokens: 150, reasoningTokens: 10)
        let second = ModelUsage(inputTokens: 1_300, outputTokens: 8, cachedInputTokens: 1_150)
        let call = addition("a")
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? usageResponse(request, id: "first", usage: first, calls: [call])
                      : usageResponse(request, id: "second", usage: second, text: "5")
        }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider),
                             tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: EffectLog()))]),
                             reportsModelRequests: true)
        let events = await collectEvents(loop.events(messages: [.user([.text("Add")])], sessionID: UUID(), budget: try testBudget()))
        guard case .runFinished(.result(let result)) = events.last else { Issue.record("Missing result"); return }
        #expect(result.outcome == .completed)
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "first", usage: first,
                  outcome: .completed(.toolCalls), duration: .zero),
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "second", usage: second,
                  outcome: .completed(.endTurn), duration: .zero),
        ])
        // Each record belongs to its turn and comes before that turn's completed response.
        for turn in [1, 2] {
            let started = try #require(events.firstIndex(of: .turnStarted(turn)))
            let record = try #require(events.indices.first { $0 > started && isRecord(events[$0]) })
            let completed = try #require(events.indices.first { index in
                guard index > started, case .model(.responseCompleted) = events[index] else { return false }
                return true
            })
            #expect(record < completed)
        }
    }

    @Test func aFailedRequestIsRecordedWithTheUsageItReportedBeforeTheRunFails() async throws {
        let reported = ModelUsage(inputTokens: 4_000, cachedInputTokens: 3_500)
        let failure = ModelProviderError(kind: .transport, message: "fixture",
                                         diagnostic: .init(stage: .transport, reason: .connectionLost))
        let provider = LiveProvider { request, emit in
            try emit(.responseStarted(.init(id: "partial", model: request.model)))
            try emit(.usage(reported))
            throw failure
        }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider), tools: try ToolRegistry(tools: []),
                             reportsModelRequests: true)
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.last == .runFinished(.failed(.provider(failure))))
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "partial", usage: reported,
                  outcome: .failed(.provider(.transport, .init(stage: .transport, reason: .connectionLost))), duration: .zero),
        ])
    }

    @Test func aResponseThatBreaksTheEventContractIsRecordedAsAnInvalidStream() async throws {
        let provider = LiveProvider { _, emit in try emit(.textDelta("no start")) }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider), tools: try ToolRegistry(tools: []),
                             reportsModelRequests: true)
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.last == .runFinished(.failed(.modelStream(.missingStart))))
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: nil, usage: .init(),
                  outcome: .failed(.invalidStream), duration: .zero),
        ])
    }

    @Test func aRequestStoppedByTheDeadlineIsRecordedAsCancelledWithWhatItReported() async throws {
        let reported = ModelUsage(inputTokens: 900)
        let provider = LiveProvider { request, emit in
            try emit(.responseStarted(.init(id: "slow", model: request.model)))
            try emit(.usage(reported))
            try await Task.sleep(for: .seconds(60))
        }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider), tools: try ToolRegistry(tools: []),
                             reportsModelRequests: true)
        // Leave room for dispatch under suite contention; this tests recording, not startup speed.
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 0, deadline: .now.advanced(by: .seconds(2)))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: budget))
        guard case .runFinished(let termination) = events.last else { Issue.record("Missing terminal"); return }
        if case .result = termination { Issue.record("The deadline should end the Run") }
        let records = requestRecords(events)
        #expect(records.map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "slow", usage: reported,
                  outcome: .cancelled, duration: .zero),
        ])
        #expect(records.first.map { $0.duration > .zero } == true)
    }

    @Test func aRunThatEndsWithoutWaitingForItsTurnStillRecordsTheRequestOnce() async throws {
        let reported = ModelUsage(inputTokens: 300, cachedInputTokens: 200)
        let held = ManualGate()
        let provider = LiveProvider { request, emit in
            try emit(.responseStarted(.init(id: "held", model: request.model)))
            try emit(.usage(reported))
            try emit(.textDelta("late"))
        }
        // The turn is held before it reads the text, past the deadline, so only the Run's end can record the request.
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider), tools: try ToolRegistry(tools: []),
                             reportsModelRequests: true,
                             beforeHandlingModelEvent: { event in if case .textDelta = event { await held.wait() } })
        // Leave room for dispatch under suite contention; this tests recording, not startup speed.
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 0, deadline: .now.advanced(by: .seconds(2)))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: budget))
        await held.open()
        #expect(events.last == .runFinished(.failed(.loop(.deadlineExceeded))))
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "held", usage: reported,
                  outcome: .cancelled, duration: .zero),
        ])
        #expect(events.dropLast().last.map(isRecord) == true)
    }

    @Test(arguments: [false, true])
    func terminalPublicationRecordsThePendingRequestExactlyOnceBeforeALateTurnExits(cancelled: Bool) async throws {
        // Exercise the publication race without relying on a timer or provider scheduling.
        let pair = AsyncStream<AgentEvent>.makeStream()
        let emitter = AgentEventEmitter(pair.continuation)
        let usage = ModelUsage(inputTokens: 300, cachedInputTokens: 200)
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(.init(id: "pending", model: fixtureModel)))
        try accumulator.append(.usage(usage))
        let requests = AgentModelRequestTracker(model: fixtureModel)
        let pending = try #require(requests.pending(accumulator))
        await emitter.requestInFlight(pending)
        let terminal: AgentRunTermination = cancelled ? .cancelled : .failed(.loop(.deadlineExceeded))
        await emitter.finish(terminal)
        // A provider/turn that drains later cannot publish the same physical request again.
        await emitter.requestEnded(pending.stopped(at: .now), next: nil)
        await emitter.finish(terminal)
        let events = await collectEvents(pair.stream)
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "pending", usage: usage,
                  outcome: .cancelled, duration: .zero),
        ])
        #expect(events.count == 2)
        #expect(events.dropLast().last.map(isRecord) == true)
        #expect(events.last == .runFinished(terminal))
    }

    @Test func anExpiredBudgetBeforeDispatchDoesNotInventARequestRecord() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not be called") }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider),
                             tools: try ToolRegistry(tools: []), reportsModelRequests: true)
        let budget = try AgentBudget(maxModelTurns: 2, maxToolCalls: 0, deadline: .now.advanced(by: .milliseconds(-1)))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: budget))
        #expect(events.last == .runFinished(.failed(.loop(.deadlineExceeded))))
        #expect(requestRecords(events).isEmpty)
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func aRequestTheUserStopsIsRecordedAsCancelledWithWhatItReported() async throws {
        let reported = ModelUsage(inputTokens: 50)
        let provider = LiveProvider { request, emit in
            try emit(.responseStarted(.init(id: "stopped", model: request.model)))
            try emit(.usage(reported))
            try await Task.sleep(for: .seconds(5))
        }
        var configuration = AgentConfiguration()
        configuration.reportsModelRequests = true
        let run = try await Agent(model: fixtureModel, provider: provider, configuration: configuration).makeSession().run("Hi")
        var events: [AgentEvent] = []
        for await event in run.events {
            events.append(event)
            if case .model(.usage) = event { await run.cancel() }
        }
        #expect(events.last == .runFinished(.cancelled))
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "stopped", usage: reported,
                  outcome: .cancelled, duration: .zero),
        ])
    }

    @Test func requestsTheProviderReportsItselfAreForwardedAndNotRecordedTwice() async throws {
        let failedUsage = ModelUsage(inputTokens: 700)
        let answerUsage = ModelUsage(inputTokens: 710, outputTokens: 3)
        let reported = [
            ModelRequestAttempt(ordinal: 1, model: fixtureModel, candidate: "primary", responseID: nil, usage: failedUsage,
                                outcome: .failed(.provider(.unavailable, nil)), duration: .milliseconds(40)),
            ModelRequestAttempt(ordinal: 2, model: fixtureModel, candidate: "backup", responseID: "answer", usage: answerUsage,
                                outcome: .completed(.endTurn), duration: .milliseconds(60)),
        ]
        let provider = ScriptedProvider { request, _ in
            reported.map { .requestAttempt($0) } + usageResponse(request, id: "answer", usage: answerUsage, text: "done")
        }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider), tools: try ToolRegistry(tools: []),
                             reportsModelRequests: true)
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        guard case .runFinished(.result(let result)) = events.last else { Issue.record("Missing result"); return }
        #expect(result.response.content == [.text("done")])
        #expect(requestRecords(events) == reported)
    }

    @Test func aFailureTheProviderReportedBeforeThrowingItIsNotRecordedAgain() async throws {
        let failure = ModelProviderError(kind: .rateLimited, message: "fixture")
        let reported = ModelRequestAttempt(ordinal: 1, model: fixtureModel, candidate: "only", responseID: nil, usage: .init(),
                                           outcome: .failed(.provider(.rateLimited, nil)), duration: .milliseconds(5))
        let provider = LiveProvider { _, emit in
            try emit(.requestAttempt(reported))
            throw failure
        }
        let loop = AgentLoop(binding: .legacy(model: fixtureModel, provider: provider), tools: try ToolRegistry(tools: []),
                             reportsModelRequests: true)
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(events.last == .runFinished(.failed(.provider(failure))))
        #expect(requestRecords(events) == [reported])
    }

    @Test func withoutTheSettingARunCarriesNoRequestRecords() async throws {
        let provider = LiveProvider { request, emit in
            try emit(.responseStarted(.init(id: "partial", model: request.model)))
            throw ModelProviderError(kind: .unavailable, message: "fixture")
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider, tools: try ToolRegistry(tools: []))
        let events = await collectEvents(loop.events(messages: [], sessionID: UUID(), budget: try testBudget()))
        #expect(requestRecords(events).isEmpty)
    }

    @Test func theAgentConfigurationTurnsRecordsOnForTheRunsOfItsSessions() async throws {
        let usage = ModelUsage(inputTokens: 10, outputTokens: 2)
        let provider = ScriptedProvider { request, _ in usageResponse(request, id: "hello", usage: usage, text: "Hello") }
        var configuration = AgentConfiguration()
        #expect(configuration.reportsModelRequests == false)
        configuration.reportsModelRequests = true
        let run = try await Agent(model: fixtureModel, provider: provider, configuration: configuration).makeSession().run("Hi")
        var events: [AgentEvent] = []
        for await event in run.events { events.append(event) }
        _ = try await run.wait()
        #expect(requestRecords(events).map(\.timeless) == [
            .init(ordinal: 1, model: fixtureModel, candidate: nil, responseID: "hello", usage: usage,
                  outcome: .completed(.endTurn), duration: .zero),
        ])
    }

    @Test func aRecordKeepsNoTextBeyondItsBounds() throws {
        let long = String(repeating: "é", count: ModelRequestAttempt.maximumTextBytes)
        let record = ModelRequestAttempt(ordinal: 1, model: fixtureModel, candidate: long, responseID: long, usage: .init(),
                                         outcome: .completed(.unknown(long)), duration: .zero)
        #expect(record.candidate == nil)
        #expect(record.responseID == nil)
        guard case .completed(.unknown(let reason)) = record.outcome else { Issue.record("Stop reason lost"); return }
        #expect(reason.utf8.count <= ModelRequestAttempt.maximumTextBytes)
        #expect(long.hasPrefix(reason) && !reason.isEmpty)
        let decoded = try JSONDecoder().decode(ModelRequestAttempt.self, from: JSONEncoder().encode(
            ModelRequestAttempt(ordinal: 2, model: fixtureModel, candidate: "c", responseID: "r", usage: .init(inputTokens: 1),
                                outcome: .failed(.provider(.transport, .init(stage: .transport, reason: .requestTimedOut))),
                                duration: .milliseconds(12))))
        #expect(decoded == ModelRequestAttempt(ordinal: 2, model: fixtureModel, candidate: "c", responseID: "r", usage: .init(inputTokens: 1),
                                                outcome: .failed(.provider(.transport, .init(stage: .transport, reason: .requestTimedOut))),
                                                duration: .milliseconds(12)))
    }
}

private func usageResponse(_ request: ModelRequest, id: String, usage: ModelUsage,
                           text: String? = nil, calls: [ToolCall] = []) -> [ModelEvent] {
    let info = ResponseInfo(id: id, model: request.model)
    var events: [ModelEvent] = [.responseStarted(info)]
    if let text { events.append(.textDelta(text)) }
    for call in calls {
        events += [.toolCallStarted(call.id, name: call.name), .toolCallArgumentsDelta(call.id, call.argumentsJSON), .toolCallCompleted(call)]
    }
    events.append(.usage(usage))
    events.append(.responseCompleted(.init(info: info, content: text.map { [.text($0)] } ?? [], toolCalls: calls,
                                           usage: usage, stopReason: calls.isEmpty ? .endTurn : .toolCalls)))
    return events
}

private func requestRecords(_ events: [AgentEvent]) -> [ModelRequestAttempt] {
    events.compactMap { if case .model(.requestAttempt(let record)) = $0 { record } else { nil } }
}

private func isRecord(_ event: AgentEvent) -> Bool {
    if case .model(.requestAttempt) = event { true } else { false }
}

private extension ModelRequestAttempt {
    /// The record without its measured time, which a test cannot predict.
    var timeless: ModelRequestAttempt {
        .init(ordinal: ordinal, model: model, candidate: candidate, responseID: responseID, usage: usage,
              outcome: outcome, duration: .zero)
    }
}
