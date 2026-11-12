@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

@Suite struct JournalConcurrencyAndFaultContractTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-contract-\(label)-\(UUID())")
    }

    @Test(arguments: JournalContractBackends.all)
    func writerLockRefusesConcurrentFailFastOpenAndAllowsBoundedWaitHandoff(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("writer-lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try backend.create(at: directory, operationDomain: "lock-contract")

        await #expect(throws: AgentJournalError.storeInUse) {
            _ = try await backend.openAsync(at: directory, writerLockWait: .failFast, deadline: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await backend.openAsync(
                at: directory,
                writerLockWait: .until(ContinuousClock.now + .milliseconds(80)),
                deadline: ContinuousClock.now + .milliseconds(80)
            )
        }

        let waiter = Task {
            try await backend.openAsync(
                at: directory,
                writerLockWait: .until(ContinuousClock.now + .seconds(5)),
                deadline: ContinuousClock.now + .seconds(5)
            )
        }
        try await Task.sleep(for: .milliseconds(60))
        try await owner.close()
        let handedOff = try await waiter.value
        let session = UUID()
        _ = try await handedOff.appendCheckpoint(
            [.checkpoint(history: [.user([.text("after lock handoff")])], steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )
        #expect(try await handedOff.latestCheckpoint(sessionID: session)?.history == [.user([.text("after lock handoff")])])
        try await handedOff.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func foregroundCommitsAndMutationsDuringMaintenanceSnapshotArePreserved(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("interleave-writes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let maintenancePause = ContractStagePause()
        let journal = try backend.create(
            at: directory,
            operationDomain: "interleave-writes",
            smallMaintenanceSegments: true,
            capabilities: .init(),
            fault: { stage in
                if stage == .duringMaintenanceSnapshot { maintenancePause.waitOnce() }
            }
        )

        let first = UUID(), second = UUID()
        var history: [ModelMessage] = []
        for index in 0..<15 {
            history.append(.user([.text("before-\(index)-" + String(repeating: "m", count: 90))]))
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: history, steeringIDs: [])],
                sessionID: first,
                runID: UUID(),
                durability: .durable
            )
            if maintenancePause.didEnter { break }
        }
        let manualMaintenance: Task<JournalMaintenanceStatus?, any Error>? = maintenancePause.didEnter
            ? nil
            : Task { try await journal.requestMaintenance() }
        await maintenancePause.waitUntilEntered()

        history.append(.assistant(content: [.text("committed-during-maintenance")], toolCalls: []))
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: history, steeringIDs: [])],
            sessionID: first,
            runID: UUID(),
            durability: .durable
        )

        let target = EvidenceReference(namespace: "fixture", id: "second")
        let run = UUID(), call = ToolCallID(rawValue: "post-snapshot")
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: [.user([.text("S+2")])], steeringIDs: [])],
            sessionID: second,
            runID: run,
            durability: .durable
        )
        _ = try await journal.admit(.init(
            sessionID: second,
            runID: run,
            callID: call,
            name: "write",
            argumentsJSON: "{}",
            resources: [.named(target)],
            idempotencyKey: "after-snapshot-operation",
            receiptExpectation: try .init(targets: [target], revision: .present)
        ))
        let receipt = ToolReceipt(operationID: "after-snapshot-operation", status: .succeeded, confirmedTargets: [target], revision: "committed")
        try await journal.commitMutation(
            sessionID: second,
            runID: run,
            callID: call,
            receipt: receipt,
            output: .string("persisted"),
            history: [
                .user([.text("S+2")]),
                .tool(.init(callID: call, content: [.text("persisted")], isError: false)),
            ],
            steeringIDs: []
        )

        maintenancePause.release()
        _ = try await manualMaintenance?.value
        for _ in 0..<16 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        #expect(try await reopened.latestCheckpoint(sessionID: first)?.history == history)
        #expect(try await reopened.latestCheckpoint(sessionID: second)?.history.count == 2)
        #expect(try await reopened.mutationStatus(identity: "after-snapshot-operation")?.receipt == receipt)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func activeSessionReaderSeesConsistentHistoryAcrossConcurrentMaintenance(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("interleave-reader")
        defer { try? FileManager.default.removeItem(at: directory) }
        let maintenancePause = ContractStagePause()
        let readPause = ContractStagePause(armed: false)
        let journal = try backend.create(
            at: directory,
            operationDomain: "interleave-reader",
            smallMaintenanceSegments: true,
            capabilities: .init(),
            fault: { stage in
                if stage == .duringMaintenanceSnapshot { maintenancePause.waitOnce() }
                if stage == .beforeSessionRead { readPause.waitOnce() }
            }
        )
        let session = UUID()
        var history: [ModelMessage] = []
        for index in 0..<12 {
            history.append(.user([.text("pinned-\(index)-" + String(repeating: "r", count: 90))]))
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: history, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
            if maintenancePause.didEnter { break }
        }
        let manualMaintenance: Task<JournalMaintenanceStatus?, any Error>? = maintenancePause.didEnter
            ? nil
            : Task { try await journal.requestMaintenance() }
        await maintenancePause.waitUntilEntered()

        readPause.arm()
        let reading = Task { try await journal.readMessages(sessionID: session, after: 0, limit: 50) }
        await readPause.waitUntilEntered()
        maintenancePause.release()
        readPause.release()

        #expect(try await reading.value.map(\.message) == history)
        _ = try await manualMaintenance?.value
        try await journal.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func preCommitAndPostCommitFaultsPreserveAtomicSettlementAndPoisonUncertainHandles(
        _ backend: any JournalBackendHarness
    ) async throws {
        for stage in [JournalContractFaultStage.beforeCommit, .afterCommitBeforeAck] {
            let directory = tempDir("settlement-\(stage.rawValue)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = ContractFaultGate()
            var journal: AgentJournal? = try backend.create(
                at: directory,
                operationDomain: "settlement-fault",
                smallMaintenanceSegments: false,
                capabilities: .init(),
                fault: { try gate.check($0) }
            )
            let session = UUID(), run = UUID(), call = ToolCallID(rawValue: "mutation")
            let target = EvidenceReference(namespace: "fixture", id: "target")
            let request = ToolMutationAdmissionRequest(
                sessionID: session,
                runID: run,
                callID: call,
                name: "write",
                argumentsJSON: "{}",
                resources: [.named(target)],
                idempotencyKey: "effect",
                receiptExpectation: try .init(targets: [target], revision: .present)
            )
            _ = try await journal?.admit(request)

            let receipt = ToolReceipt(operationID: "effect", status: .succeeded, confirmedTargets: [target], revision: "v2")
            let history: [ModelMessage] = [
                .user([.text("commit")]),
                .assistant(content: [], toolCalls: [.init(id: call, name: "write", argumentsJSON: "{}", completeness: .complete)]),
                .tool(.init(callID: call, content: [.text("done")], isError: false)),
            ]
            gate.arm(stage)
            if stage == .afterCommitBeforeAck {
                await #expect(throws: AgentJournalError.commitUnknown) {
                    try await journal?.commitMutation(
                        sessionID: session,
                        runID: run,
                        callID: call,
                        receipt: receipt,
                        output: .string("done"),
                        history: history,
                        steeringIDs: []
                    )
                }
                // Uncertain publication poisons the handle until reopened.
                await #expect(throws: AgentJournalError.commitUnknown) {
                    _ = try await journal?.latestCheckpoint(sessionID: session)
                }
            } else {
                await #expect(throws: (any Error).self) {
                    try await journal?.commitMutation(
                        sessionID: session,
                        runID: run,
                        callID: call,
                        receipt: receipt,
                        output: .string("done"),
                        history: history,
                        steeringIDs: []
                    )
                }
            }
            try? await journal?.close()
            journal = nil

            let reopened = try backend.open(at: directory)
            let status = try #require(try await reopened.mutationStatus(identity: "effect"))
            if stage == .beforeCommit {
                #expect(status.state == .intent)
                #expect(status.receipt == nil)
                #expect(try await reopened.latestCheckpoint(sessionID: session) == nil)
                #expect(try await reopened.recoverPendingMutations(sessionID: session).map(\.state) == [.needsReconciliation])
            } else {
                #expect(status.state == .settled)
                #expect(status.receipt == receipt)
                #expect(status.replayOutput == .string("done"))
                #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == history)
            }
            try await reopened.close()
        }
    }

    @Test(arguments: JournalContractBackends.all)
    func corruptedStorageAndUnsupportedSchemaFailClosedWithoutResettingStore(
        _ backend: any JournalBackendHarness
    ) async throws {
        let schemaDir = tempDir("unsupported-schema")
        defer { try? FileManager.default.removeItem(at: schemaDir) }
        let created = try backend.create(at: schemaDir, operationDomain: "schema-check")
        let session = UUID()
        _ = try await created.appendCheckpoint(
            [.checkpoint(history: [.user([.text("keep")])], steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )
        try await created.close()

        try backend.writeUnsupportedSchemaVersion(at: schemaDir)
        #expect(throws: AgentJournalError.unsupportedFormat) {
            _ = try backend.open(at: schemaDir)
        }

        let corruptDir = tempDir("corrupt-payload")
        defer { try? FileManager.default.removeItem(at: corruptDir) }
        let healthy = try backend.create(at: corruptDir, operationDomain: "corrupt-check")
        _ = try await healthy.appendCheckpoint(
            [.checkpoint(history: [.user([.text("must-not-become-empty")])], steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )
        try await healthy.close()

        try backend.corruptCommittedPayload(at: corruptDir)
        var failed = false
        do {
            let opened = try backend.open(at: corruptDir)
            _ = try await opened.latestCheckpoint(sessionID: session)
            _ = try await opened.readMessages(sessionID: session)
            try await opened.close()
        } catch {
            failed = true
        }
        #expect(failed, "corrupted committed payload must fail instead of silently returning empty state")
    }
    @Test(arguments: JournalContractBackends.all)
    func closedStoreRefusesSubsequentWritesAndFollowUpMutations(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("closed-store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "close-contract",
            capabilities: .init(supportsPerCallFollowUps: true)
        )
        let session = UUID()
        _ = try await journal.enqueueFollowUp(
            .init(inputID: "queued-1", text: "queued", operationID: "op-1", configurationRef: "cfg"),
            sessionID: session
        )
        try await journal.close()

        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: [.user([.text("late")])], steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
        }
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await journal.enqueueFollowUp(
                .init(inputID: "late-1", text: "late", operationID: "op-late", configurationRef: "cfg"),
                sessionID: session
            )
        }
        await #expect(throws: AgentJournalError.storeClosed) {
            _ = try await journal.withdrawFollowUp(sessionID: session, inputID: "queued-1")
        }

        let reopened = try backend.open(at: directory)
        #expect(try await reopened.followUp(sessionID: session, inputID: "queued-1")?.state == .queued)
        #expect(try await reopened.followUp(sessionID: session, inputID: "late-1") == nil)
        try await reopened.close()
    }
}
