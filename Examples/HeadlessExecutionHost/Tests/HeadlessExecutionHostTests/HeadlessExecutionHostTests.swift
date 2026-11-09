import AgentCore
import ExecutionReportingSupport
import Foundation
import HeadlessExecutionHost
import Testing

struct HeadlessExecutionHostTests {
    @Test func committedMutationSurvivesLaterProviderFailureAndReplayDoesNotWriteAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessHost-\(UUID().uuidString)")
        let result = try await HeadlessExecutionHost().run(.failureAfterWrite, root: root)

        #expect(result.fileContent == "execution fact")
        #expect(result.fileRevision != nil)
        #expect(result.executorEntryCount == 1)
        #expect(result.executorEntryCountAfterFirstRun == 1)
        #expect(result.successfulWriteCount == 1)
        #expect(result.successfulWriteCountAfterFirstRun == 1)
        #expect(result.replayExecutorEntryCount == 1)
        #expect(result.replayReceivedToolResult == true)
        #expect(result.replayReport?.coverage.isComplete == true)
        #expect(result.replayReport?.runtimeTermination == .completed(.completed))
        #expect(result.replayReport?.receipts.first?.receipt == result.report.receipts.first?.receipt)
        #expect(result.replayReport?.receipts.first?.callID != result.report.receipts.first?.callID)
        #expect(result.replayReport?.toolObservations.first?.executorEntered == nil)
        #expect(result.replayReport?.toolObservations.first?.status == .completed(isError: false))
        #expect(result.report.receipts.count == 1)
        #expect(result.report.runtimeTermination == .failed(.provider(.init(
            kind: .invalidResponse,
            message: "deterministic final response failure"
        ))))
        #expect(result.report.presentation == .malformed(reason: "fixture provider ended before a valid final response"))
        #expect(result.report.coverage.isComplete)
        #expect(result.replayReport?.diagnostics.isEmpty == true)
    }

    @Test func readOnlyGoalRejectsMutationBeforeExecutorEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessHost-\(UUID().uuidString)")
        let result = try await HeadlessExecutionHost().run(.readOnlyRejectsWrite, root: root)

        #expect(result.executorEntryCount == 0)
        #expect(result.fileContent == nil)
        #expect(result.report.receipts.isEmpty)
        let refusal = try #require(result.report.toolObservations.first)
        #expect(refusal.status == .completed(isError: true))
        #expect(refusal.resultPreview?.contains("This call was not allowed") == true)
        #expect(refusal.executorEntered == nil)
        #expect(result.successfulWriteCount == 0)
        #expect(result.report.runtimeTermination == .completed(.completed))
        #expect(result.report.finalModelText == "The Host rejected the write before execution.")
        #expect(result.report.coverage.isComplete && result.report.diagnostics.isEmpty)
    }
}
