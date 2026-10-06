import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

/// A tool call whose arguments are not a JSON object, or do not match the tool's input schema,
/// is a model mistake. The tool does not run; the model is told what was wrong and the Run goes on.
struct AgentInvalidToolArgumentsTests {
    @Test func committedRejectionSurvivesALaterSiblingExecutionFailureAndJournalReopen() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "rejected-sibling")
        let bad = invalidAddition("bad", "{")
        let good = addition("good")
        let overflow = invalidAddition("overflow", "{\"lhs\":\(Int.max),\"rhs\":1}")
        let log = EffectLog()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [bad, good, overflow]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log, execution: .sequential)]).makeSession(journal: journal)
        let run = try await session.run("Add")
        let observation = Task { await collectInvalidArgumentEvents(run.events) }
        await #expect(throws: FixtureError.invalidOperation) { try await run.wait() }
        try await run.waitForDrain()
        let events = await observation.value
        #expect(events.filter { $0 == .toolAdmissionRejected(bad.id) }.count == 1)
        #expect(events.last == .runFinished(.failed(.unclassified)))
        #expect(!events.contains(.toolStarted(bad)))
        #expect(events.contains(.toolCompleted(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false))))
        #expect(await log.contexts.map(\.callID) == [good.id, overflow.id])
        #expect(await provider.log.requests.count == 1)
        let committed = try #require(try await journal.latestCheckpoint(sessionID: session.id)).history
        #expect(committed.suffix(3).first == .assistant(content: [], toolCalls: [invalidAddition("bad", "{}"), good]))
        let feedback = try #require(toolResult(Array(committed.suffix(2))[0]))
        #expect(feedback.callID == bad.id && feedback.isError && feedbackCode(feedback) == "invalid_arguments")
        #expect(committed.last == .tool(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false)))
        #expect(await session.history == committed)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == committed)
        try await reopened.close()
    }

    @Test(arguments: [#"{"lhs":2,"rhs":"#, #"[2,3]"#, #"{"lhs":2,"lhs":3,"rhs":1}"#, ""])
    func argumentsThatAreNotAJSONObjectGoBackToTheModel(_ arguments: String) async throws {
        let call = invalidAddition("bad", arguments)
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "I will try again.")
        }
        let run = try await Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)])
            .makeSession().run("Add 2 and 3")
        let events = Task { await collectInvalidArgumentEvents(run.events) }
        let result = try await run.wait()

        #expect(result.outcome == .completed)
        #expect(result.modelTurns == 2 && result.toolCalls == 1)
        #expect(await log.names.isEmpty)
        let second = try #require(await provider.log.requests.last)
        // Every provider needs a tool call's input to be one JSON object, so the replayed call carries `{}`.
        #expect(second.messages.suffix(2).first == .assistant(content: [], toolCalls: [
            .init(id: call.id, name: "add", argumentsJSON: "{}", completeness: .complete),
        ]))
        let feedback = try #require(toolResult(second.messages.last))
        #expect(feedback.callID == call.id && feedback.isError)
        #expect(feedbackCode(feedback) == "invalid_arguments")
        #expect(feedbackMessage(feedback)?.contains("not a valid JSON object") == true)
        #expect(feedbackMessage(feedback)?.contains("was not run") == true)
        let received = await events.value
        #expect(received.contains(.toolAdmissionRejected(call.id)))
        #expect(!received.contains { if case .toolStarted = $0 { true } else { false } })
    }

    @Test(arguments: [(#"{"lhs":2}"#, "/rhs"), (#"{"lhs":"two","rhs":3}"#, "/lhs")])
    func argumentsOutsideTheSchemaNameTheFieldAndKeepTheProposal(_ arguments: String, _ field: String) async throws {
        let call = invalidAddition("schema", arguments)
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "I will try again.")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)]).makeSession()
        let result = try await session.run("Add 2 and 3").wait()

        #expect(result.outcome == .completed)
        #expect(await log.names.isEmpty)
        let second = try #require(await provider.log.requests.last)
        // Valid JSON is replayed exactly as the model wrote it.
        #expect(second.messages.suffix(2).first == .assistant(content: [], toolCalls: [call]))
        let feedback = try #require(toolResult(second.messages.last))
        #expect(feedback.isError && feedbackCode(feedback) == "invalid_arguments")
        #expect(feedbackMessage(feedback)?.contains(field) == true)
        #expect(await session.history.contains(.tool(feedback)))
    }

    @Test func aValidSiblingInTheSameBatchStillRunsAndResultsKeepCallOrder() async throws {
        let bad = invalidAddition("bad", #"{"lhs":2"#)
        let good = addition("good")
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [bad, good]) : textResponse(request, "5")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)]).makeSession()
        let result = try await session.run("Add").wait()

        #expect(result.outcome == .completed)
        #expect(result.toolCalls == 2)
        #expect(await log.names == ["add"])
        let second = try #require(await provider.log.requests.last)
        let tail = Array(second.messages.suffix(3))
        #expect(tail.first == .assistant(content: [], toolCalls: [
            .init(id: bad.id, name: "add", argumentsJSON: "{}", completeness: .complete), good,
        ]))
        #expect(toolResult(tail[1])?.callID == bad.id && toolResult(tail[1])?.isError == true)
        #expect(tail[2] == .tool(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false)))
    }

    @Test func repeatedInvalidCallsStopAtTheModelTurnBudget() async throws {
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            toolResponse(request, [invalidAddition("bad-\(turn)", #"{"lhs":"#)])
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider,
                             tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
        await #expect(throws: AgentLoopError.modelTurnLimitReached) {
            try await loop.run(messages: [], sessionID: UUID(), budget: testBudget(turns: 3, calls: 50))
        }
        #expect(await provider.log.requests.count == 3)
        #expect(await log.names.isEmpty)
    }

    @Test func repeatedInvalidCallsCountTowardTheToolCallBudget() async throws {
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            toolResponse(request, [invalidAddition("bad-\(turn)", #"{"lhs":"#)])
        }
        let loop = AgentLoop(model: fixtureModel, provider: provider,
                             tools: try ToolRegistry(tools: [AnyAgentTool(AddTool(log: log))]))
        await #expect(throws: AgentLoopError.toolCallLimitReached) {
            try await loop.run(messages: [], sessionID: UUID(), budget: testBudget(turns: 50, calls: 2))
        }
        #expect(await provider.log.requests.count == 3)
        #expect(await log.names.isEmpty)
    }

    @Test func correctedArgumentsExecuteOnceAndCompleteOnTheThirdModelTurn() async throws {
        let bad = invalidAddition("bad", "{")
        let good = addition("corrected")
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [bad])
            case 2:
                let feedback = try #require(toolResult(request.messages.last))
                #expect(feedback.callID == bad.id && feedbackCode(feedback) == "invalid_arguments")
                return toolResponse(request, [good])
            default:
                #expect(request.messages.last == .tool(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false)))
                return textResponse(request, "5")
            }
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)]).makeSession()
        let run = try await session.run("Add", budget: testBudget(turns: 3, calls: 2))
        let observation = Task { await collectInvalidArgumentEvents(run.events) }
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(result.outcome == .completed && result.modelTurns == 3 && result.toolCalls == 2)
        #expect(await log.contexts.map(\.callID) == [good.id])
        let history = await session.history
        #expect(history[1] == .assistant(content: [], toolCalls: [invalidAddition("bad", "{}")]))
        #expect(toolResult(history[2])?.callID == bad.id && toolResult(history[2])?.isError == true)
        #expect(history[3] == .assistant(content: [], toolCalls: [good]))
        #expect(history[4] == .tool(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false)))
        let events = await observation.value
        #expect(events.filter { $0 == .toolAdmissionRejected(bad.id) }.count == 1)
        #expect(!events.contains(.toolStarted(bad)))
        #expect(events.filter { $0 == .toolStarted(good) }.count == 1)
    }

    @Test func correctedArgumentsCannotReuseTheRejectedCallID() async throws {
        let bad = invalidAddition("bad", "{")
        let corrected = addition("bad")
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in toolResponse(request, [turn == 1 ? bad : corrected]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: log)]).makeSession()
        let run = try await session.run("Add")
        await #expect(throws: AgentLoopError.reusedToolCallID(bad.id)) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await log.names.isEmpty)
        #expect(await provider.log.requests.count == 2)
    }

    @Test func unknownToolStillEndsTheRun() async throws {
        let call = ToolCall(id: .init(rawValue: "missing"), name: "does_not_exist", argumentsJSON: "{", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: EffectLog())]).makeSession()
        await #expect(throws: ToolRegistryError.unknownTool("does_not_exist")) { _ = try await session.run("Go").wait() }
        #expect(await provider.log.requests.count == 1)
    }

    /// Under required audit a mutation with unusable arguments is recorded, never authorized,
    /// leaves no pending intent, and its rejection is committed to the durable journal.
    @Test func auditedMutationWithInvalidArgumentsIsNeverAuthorizedAndIsJournaled() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "invalid-arguments",
                                                         supportsAuthorizationAudit: true)
        let authorizer = AuditTestAuthorizer(), probe = AuditExecutionProbe()
        let call = ToolCall(id: .init(rawValue: "write-bad"), name: AuditExecutionTool.name,
                            argumentsJSON: #"{"id":"A""#, completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "I will try again.")
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AuditExecutionTool(probe: probe)],
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let run = try await session.run("write")
        let result = try await run.wait()
        try await run.waitForDrain()

        #expect(result.outcome == .completed)
        #expect(await authorizer.requests.isEmpty)
        #expect(await probe.executorEntered == 0)
        #expect(try await journal.pendingMutations().isEmpty)
        let records = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true).records
        #expect(records.contains { if case .proposal(let p) = $0.fact { p.rawArgumentsJSON == call.argumentsJSON } else { false } })
        #expect(records.compactMap { if case .disposition(let d) = $0.fact { d.reasonCode } else { nil } } == ["invalid_arguments"])
        let checkpoint = try #require(try await journal.latestCheckpoint(sessionID: session.id))
        #expect(checkpoint.history.contains { toolResult($0)?.callID == call.id && toolResult($0)?.isError == true })
        try await journal.close()
    }
}

private func invalidAddition(_ id: String, _ arguments: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: "add", argumentsJSON: arguments, completeness: .complete)
}

private func toolResult(_ message: ModelMessage?) -> ToolResultMessage? {
    if case .tool(let result) = message { return result }
    return nil
}

private func feedbackField(_ result: ToolResultMessage, _ key: String) -> String? {
    guard case .json(.object(let object)) = result.content.first, case .string(let value) = object[key] else { return nil }
    return value
}

private func feedbackCode(_ result: ToolResultMessage) -> String? { feedbackField(result, "code") }
private func feedbackMessage(_ result: ToolResultMessage) -> String? { feedbackField(result, "message") }

private func collectInvalidArgumentEvents(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in stream { events.append(event) }
    return events
}
