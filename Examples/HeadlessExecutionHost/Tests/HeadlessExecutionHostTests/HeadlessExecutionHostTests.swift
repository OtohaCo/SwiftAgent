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
        #expect(result.executorEntryCount == 1)
        #expect(result.replayExecutorEntryCount == 1)
        #expect(result.report.receipts.count == 1)
        #expect(result.report.runtimeTermination == .failed(.provider(.init(
            kind: .invalidResponse,
            message: "deterministic final response failure"
        ))))
        #expect(result.report.presentation == .malformed(reason: "fixture provider ended before a valid final response"))
        #expect(result.report.coverage.isComplete)
    }

    @Test func readOnlyGoalRejectsMutationBeforeExecutorEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HeadlessHost-\(UUID().uuidString)")
        let result = try await HeadlessExecutionHost().run(.readOnlyRejectsWrite, root: root)

        #expect(result.executorEntryCount == 0)
        #expect(result.fileContent == nil)
        #expect(result.report.receipts.isEmpty)
        #expect(result.report.toolObservations.first?.executorEntered == false)
        #expect(result.report.diagnostics.contains(.missingReceipt(callID: .init(rawValue: "note-call"))))
    }
}
