import AgentCore
import AgentModels
import AgentTools
import ExecutionReportingSupport
import Foundation
import Testing

struct ExecutionReportReducerTests {
    @Test func committedMutationSurvivesMalformedPresentation() throws {
        let ids = IdentityFixture()
        let receipt = try ids.receipt()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolReceiptValidated(receipt))
        reducer.consume(.toolCompleted(.init(callID: ids.call.id, content: [.json(.object(["ok": .bool(true)]))], isError: false)))
        reducer.recordLogicalResult(response: ids.response, outcome: .completed, receipts: [receipt])
        reducer.recordPresentation(.malformed(reason: "final response was not valid host JSON"))

        let report = reducer.report
        #expect(report.receipts == [receipt])
        #expect(report.presentation == .malformed(reason: "final response was not valid host JSON"))
        #expect(report.runtimeTermination == .completed(.completed))
        #expect(report.coverage.isComplete == false)
        #expect(report.diagnostics.isEmpty)
    }

    @Test func committedMutationSurvivesContradictoryStructuredPresentation() throws {
        let ids = IdentityFixture()
        let receipt = try ids.receipt()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolReceiptValidated(receipt))
        reducer.recordPresentation(.contradictory(reason: "model claimed search-only after a committed write"))

        #expect(reducer.report.receipts == [receipt])
        #expect(reducer.report.presentation == .contradictory(reason: "model claimed search-only after a committed write"))
    }

    @Test func committedMutationSurvivesLaterProviderFailure() throws {
        let ids = IdentityFixture()
        let receipt = try ids.receipt()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolReceiptValidated(receipt))
        reducer.consume(.runFinished(.failed(.provider(.init(kind: .invalidResponse, message: "fixture failure")))))
        reducer.recordWait(.failure(.provider(.init(kind: .invalidResponse, message: "fixture failure"))))

        #expect(reducer.report.receipts == [receipt])
        #expect(reducer.report.runtimeTermination == .failed(.provider(.init(kind: .invalidResponse, message: "fixture failure"))))
    }

    @Test func committedMutationSurvivesCancellation() throws {
        let ids = IdentityFixture()
        let receipt = try ids.receipt()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolReceiptValidated(receipt))
        reducer.consume(.runFinished(.cancelled))
        reducer.recordWait(outcome: .failure(.cancelled))
        reducer.markStreamEnded()
        reducer.markDrainCompleted()

        #expect(reducer.report.receipts == [receipt])
        #expect(reducer.report.runtimeTermination == .cancelled)
        #expect(reducer.report.coverage.isComplete)
    }

    @Test func fabricatedSuccessTextDoesNotCreateExecutionFacts() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.model(.textDelta("Saved successfully")))
        reducer.recordPresentation(.parsed(text: "Saved successfully"))

        #expect(reducer.report.receipts.isEmpty)
        #expect(reducer.report.toolObservations.isEmpty)
        #expect(reducer.report.modelText == "Saved successfully")
    }

    @Test func readOnlyGoalRejectsMutationBeforeExecutorEntry() throws {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.model(.toolCallCompleted(ids.call)))
        reducer.consume(.toolFailed(ids.call.id, .toolInvocation(.authorizationDenied)))

        let tool = try #require(reducer.report.toolObservations.first)
        #expect(tool.status == .failed(.toolInvocation(.authorizationDenied)))
        #expect(reducer.report.receipts.isEmpty)
        #expect(tool.executorEntered == false)
    }

    @Test func recoverableToolErrorIsNotReportedAsSuccessfulEffect() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolCompleted(.init(callID: ids.call.id, content: [.json(.object(["code": .string("not_found")]))], isError: true)))

        #expect(reducer.report.receipts.isEmpty)
        #expect(reducer.report.toolObservations.first?.status == .completed(isError: true))
    }

    @Test func failedToolDoesNotEraseEarlierCommittedTools() throws {
        let ids = IdentityFixture()
        let first = try ids.receipt(callID: ids.firstCall.id)
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.firstCall))
        reducer.consume(.toolReceiptValidated(first))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolFailed(ids.call.id, .toolInvocation(.authorizationDenied)))

        #expect(reducer.report.receipts == [first])
        #expect(reducer.report.toolObservations.count == 2)
    }

    @Test func missingReceiptDoesNotProveNoSideEffect() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolStarted(ids.call))
        reducer.consume(.toolFailed(ids.call.id, .cancelled))

        #expect(reducer.report.receipts.isEmpty)
        #expect(reducer.report.diagnostics.contains(.missingReceipt(callID: ids.call.id)))
        #expect(reducer.report.toolObservations.first?.status == .failed(.cancelled))
    }

    @Test func receiptEventAndFinalResultAreNotDoubleCounted() throws {
        let ids = IdentityFixture()
        let receipt = try ids.receipt()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolReceiptValidated(receipt))
        reducer.recordLogicalResult(response: ids.response, outcome: .completed, receipts: [receipt])

        #expect(reducer.report.receipts.count == 1)
        #expect(!reducer.report.diagnostics.contains(.duplicateReceipt(callID: ids.call.id)))
    }

    @Test func conflictingReceiptObservationProducesDiagnostic() throws {
        let ids = IdentityFixture()
        let first = try ids.receipt()
        let second = try ids.receipt(status: .indeterminate)
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolReceiptValidated(first))
        reducer.consume(.toolReceiptValidated(second))

        #expect(reducer.report.receipts == [first])
        #expect(reducer.report.toolObservations.first?.receipt == first)
        #expect(reducer.report.diagnostics.contains(.conflictingReceipt(callID: ids.call.id)))
    }

    @Test func repeatedTextDeltasAreNotDroppedAsDuplicates() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.model(.textDelta("ha")))
        reducer.consume(.model(.textDelta("ha")))

        #expect(reducer.report.modelText == "haha")
    }

    @Test func reportsDoNotMixRunsOrSessions() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        let wrong = AgentRunInfo(sessionID: UUID(), runID: UUID(), model: ids.info.model)
        reducer.consume(.runStarted(wrong))

        #expect(reducer.report.coverage.runStarted == false)
        #expect(reducer.report.diagnostics.contains(.mismatchedRun))
    }

    @Test func lateEventsCannotOverwriteANewerConversation() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.markStreamEnded()
        reducer.markDrainCompleted()
        reducer.consume(.model(.textDelta("late")))

        #expect(reducer.report.modelText.isEmpty)
        #expect(reducer.report.diagnostics.contains(.eventAfterObservationEnded))
    }

    @Test func reportIsNotFinalBeforeObserverHasProcessedTerminal() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.recordWait(.failure(.provider(.init(kind: .invalidResponse, message: "failure"))))
        reducer.markStreamEnded()
        reducer.markDrainCompleted()

        #expect(reducer.report.coverage.isComplete == false)
    }

    @Test func streamEndWithoutTerminalIsPartialObservation() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.markStreamEnded()

        #expect(reducer.report.coverage.streamEnded)
        #expect(reducer.report.coverage.terminalObserved == false)
        #expect(reducer.report.diagnostics.contains(.streamEndedWithoutTerminal))
    }

    @Test func reportDoesNotClaimPhysicalDrainBeforeDrainCompletes() {
        let ids = IdentityFixture()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.runFinished(.cancelled))
        reducer.recordWait(.failure(.cancelled))
        reducer.markStreamEnded()

        #expect(reducer.report.coverage.drainCompleted == false)
        #expect(reducer.report.coverage.isComplete == false)
    }

    @Test func restoredReportCannotCreateEvidenceOrAuthorizeTools() throws {
        let ids = IdentityFixture()
        let receipt = try ids.receipt()
        var reducer = ExecutionReportReducer(sessionID: ids.sessionID, runID: ids.runID)
        reducer.consume(.runStarted(ids.info))
        reducer.consume(.toolReceiptValidated(receipt))
        let snapshot = reducer.report.snapshot
        let restored = try JSONDecoder().decode(
            ExecutionReportSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        #expect(restored.receipts == [receipt])
        #expect(restored.canAuthorizeTools == false)
        #expect(restored.canCreateEvidence == false)
    }
}

private struct IdentityFixture {
    let sessionID = UUID()
    let runID = UUID()
    let model = ModelID(provider: "fixture", name: "reporting")

    var info: AgentRunInfo { .init(sessionID: sessionID, runID: runID, model: model) }
    var call: ToolCall {
        .init(id: .init(rawValue: "write"), name: "write_note", argumentsJSON: #"{"path":"note.txt"}"#, completeness: .complete)
    }
    var firstCall: ToolCall {
        .init(id: .init(rawValue: "first"), name: "search", argumentsJSON: "{}", completeness: .complete)
    }
    var response: ModelResponse {
        .init(info: .init(id: "response", model: model), content: [.text("done")], stopReason: .endTurn)
    }

    func receipt(
        callID: ToolCallID? = nil,
        status: ToolReceipt.Status = .succeeded
    ) throws -> AgentToolReceipt {
        let target = EvidenceReference(namespace: "file", id: "note.txt")
        let expectation = ToolReceipt(
            operationID: "operation",
            status: status,
            confirmedTargets: [target],
            revision: "revision"
        )
        return .init(
            callID: callID ?? call.id,
            effect: .mutation,
            receipt: expectation
        )
    }
}
