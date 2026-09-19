import AgentCore
import AgentModels
import AgentTools
import Foundation
import XCTest

final class AgentJournalTests: XCTestCase {
    func testEveryLifecyclePayloadRoundTripsWithoutHostTypes() throws {
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "search",
                            argumentsJSON: "{}", completeness: .complete)
        let expectation = try ToolReceiptExpectation(
            targets: [EvidenceReference(namespace: "property.listing", id: "listing-1")],
            revision: .changed(from: "v1")
        )
        let intent = try PendingMutationIntent(
            call: call,
            resources: [.named(EvidenceReference(namespace: "property.listing", id: "listing-1"))],
            idempotencyKey: "run-1/call-1",
            receiptExpectation: expectation
        )
        let receipt = AgentToolReceipt(
            callID: call.id,
            effect: .mutation,
            receipt: ToolReceipt(
                operationID: "run-1/call-1",
                status: .succeeded,
                confirmedTargets: [EvidenceReference(namespace: "property.listing", id: "listing-1")],
                revision: "v2"
            )
        )
        let events: [AgentJournalEvent] = [
            .sessionCreated,
            .userMessage("Find a listing"),
            .assistantMessage(content: [.reasoning("Search first")], toolCalls: [call]),
            .modelAttempt(turn: 1, model: ModelID(provider: "fixture", name: "search")),
            .modelCompleted(ModelResponse(
                info: .init(id: "response-1", model: .init(provider: "fixture", name: "search")),
                toolCalls: [call], stopReason: .toolCalls
            )),
            .toolProposed(call: call, effect: .mutation, resources: intent.resources),
            .toolAuthorized(callID: call.id),
            .toolStarted(callID: call.id),
            .pendingMutation(intent),
            .toolCompleted(.init(callID: call.id, content: [.json(.object(["ok": .bool(true)]))], isError: false)),
            .toolReceipt(receipt),
            .checkpoint(history: [.user([.text("Find a listing")])], steeringIDs: []),
            .compaction(.init(goal: "Find a listing", decisions: ["Use verified source"])),
            .runCompleted(.completed),
        ]
        let restored = try JSONDecoder().decode(
            [AgentJournalEvent].self,
            from: JSONEncoder().encode(events)
        )
        XCTAssertEqual(restored, events)
    }

    func testRoundTripPreservesTypedRecordsAndCheckpointBoundaries() async throws {
        let journal = AgentJournal()
        XCTAssertEqual(journal.storage, .memory)
        let sessionID = UUID()
        let runID = UUID()
        _ = try await journal.append(.sessionCreated, sessionID: sessionID)
        let checkpoint = try await journal.appendCheckpoint([
            .userMessage("Find a property"),
            .modelAttempt(turn: 1, model: ModelID(provider: "fixture", name: "search")),
        ], sessionID: sessionID, runID: runID)

        let records = await journal.snapshot()
        XCTAssertEqual(records.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(checkpoint.map(\.checkpointID).count, 2)
        XCTAssertEqual(checkpoint[0].checkpointID, checkpoint[1].checkpointID)

        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        try await journal.persist(to: url)
        XCTAssertEqual(journal.storage, .durable)
        let restored = try AgentJournal.load(from: url)
        XCTAssertEqual(restored.storage, .durable)
        let restoredRecords = await restored.snapshot()
        let originalRecords = await journal.snapshot()
        let restoredRecovery = await restored.recovery
        XCTAssertEqual(restoredRecords, originalRecords)
        XCTAssertEqual(restoredRecovery, .clean)
    }

    func testDurableAppendDoesNotPublishMemoryWhenWriteFails() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
        let url = blocker.appendingPathComponent("journal.log")
        defer { try? FileManager.default.removeItem(at: blocker) }
        let journal = try AgentJournal(persistenceURL: url)

        do {
            _ = try await journal.append(.sessionCreated, sessionID: UUID(), durability: .durable)
            XCTFail("Expected durable append to fail")
        } catch is AgentJournalError {
            // The directory cannot be opened as a journal file.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let records = await journal.snapshot()
        XCTAssertTrue(records.isEmpty)
    }

    func testFirstDurableAppendFailsClosedWhenDirectorySyncFails() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try AgentJournal(
            persistenceURL: url,
            persistenceFault: .directorySync
        )

        let sessionID = UUID()
        do {
            _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
            XCTFail("Expected the first durable append to fail when its directory cannot be synced")
        } catch let error as AgentJournalError {
            guard case .persistenceUnavailable = error else {
                return XCTFail("Unexpected journal error: \(error)")
            }
        }

        let records = await journal.snapshot()
        XCTAssertEqual(records.count, 1)
        _ = try await journal.append(.userMessage("after uncertain publish"), sessionID: sessionID, durability: .durable)
        let restarted = try AgentJournal.load(from: url)
        let restartedRecords = await restarted.snapshot()
        XCTAssertEqual(restartedRecords.count, 2)
    }

    func testPersistDoesNotAdvertiseDurabilityWhenDirectorySyncFails() async throws {
        let url = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = AgentJournal()
        _ = try await journal.append(.sessionCreated, sessionID: UUID())

        do {
            try await journal.persist(to: url, fault: .directorySync)
            XCTFail("Expected snapshot publication to fail when its directory cannot be synced")
        } catch let error as AgentJournalError {
            guard case .persistenceUnavailable = error else {
                return XCTFail("Unexpected journal error: \(error)")
            }
        }

        XCTAssertEqual(journal.storage, .memory)
        _ = try await journal.append(.userMessage("newer memory state"), sessionID: UUID())
        try await journal.persist(to: url)
        XCTAssertEqual(journal.storage, .durable)
        let restarted = try AgentJournal.load(from: url)
        let restartedRecords = await restarted.snapshot()
        XCTAssertEqual(restartedRecords.count, 2)
    }

    func testTruncatedTailRecoversOnlyCompleteFramesAndNextDurableWriteRepairsTail() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)

        let tail = Data([0xff, 0xee])
        try append(tail, to: url)

        let restored = try AgentJournal.load(from: url)
        let recoveredRecords = await restored.snapshot()
        let recoveredState = await restored.recovery
        XCTAssertEqual(recoveredRecords.count, 1)
        XCTAssertEqual(recoveredState, .truncatedTail)
        _ = try await restored.append(.userMessage("after recovery"), sessionID: sessionID, durability: .durable)
        let reloaded = try AgentJournal.load(from: url)
        let reloadedRecords = await reloaded.snapshot()
        let reloadedRecovery = await reloaded.recovery
        XCTAssertEqual(reloadedRecords.map(\.sequence), [1, 2])
        XCTAssertEqual(reloadedRecovery, .clean)
    }

    func testPartialPayloadTailIsTruncatedNotCorrupt() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        var header = Data()
        header.append(contentsOf: [0x00, 0x00, 0x00, 0x20])
        header.append(contentsOf: [0x11, 0x22, 0x33, 0x44])
        header.append(Data(repeating: 0xab, count: 4))
        try append(header, to: url)
        let restored = try AgentJournal.load(from: url)
        let truncatedRecovery = await restored.recovery
        let truncatedRecords = await restored.snapshot()
        XCTAssertEqual(truncatedRecovery, .truncatedTail)
        XCTAssertEqual(truncatedRecords.count, 1)
    }

    func testZeroFilledTailIsCorruptAndPreservesPrefix() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        try append(Data(repeating: 0, count: 64), to: url)
        let restored = try AgentJournal.load(from: url)
        let zeroRecovery = await restored.recovery
        let zeroRecords = await restored.snapshot()
        XCTAssertEqual(zeroRecovery, .corruptTail)
        XCTAssertEqual(zeroRecords.count, 1)
        do {
            _ = try await restored.append(.userMessage("must repair first"), sessionID: sessionID, durability: .durable)
            XCTFail("corrupt tail must require an explicit repair")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .repairRequired)
        }
        try await restored.discardCorruptTail()
        let repairedRecovery = await restored.recovery
        XCTAssertEqual(repairedRecovery, .clean)
        _ = try await restored.append(.userMessage("after repair"), sessionID: sessionID, durability: .durable)
        let appendedRecovery = await restored.recovery
        XCTAssertEqual(appendedRecovery, .clean)
        let reloaded = try AgentJournal.load(from: url)
        let sequences = await reloaded.snapshot().map(\.sequence)
        XCTAssertEqual(sequences, [1, 2])
    }

    func testTerminalChecksumMismatchIsCorruptTail() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        _ = try await journal.append(.userMessage("keep me"), sessionID: sessionID, durability: .durable)
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0x01
        try data.write(to: url)
        let restored = try AgentJournal.load(from: url)
        let checksumRecovery = await restored.recovery
        let checksumRecords = await restored.snapshot()
        let pending = await restored.pendingMutations()
        XCTAssertEqual(checksumRecovery, .corruptTail)
        XCTAssertEqual(checksumRecords.count, 1)
        XCTAssertEqual(pending.count, 0)
    }

    func testTerminalInvalidJSONFrameIsCorruptTail() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        try append(frame(payload: Data(#"{"not":"a-journal-frame"}"#.utf8)), to: url)
        let restored = try AgentJournal.load(from: url)
        let jsonRecovery = await restored.recovery
        let jsonRecords = await restored.snapshot()
        XCTAssertEqual(jsonRecovery, .corruptTail)
        XCTAssertEqual(jsonRecords.count, 1)
    }

    func testTerminalInvalidLengthWithNonzeroPayloadIsRepairableCorruptTail() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        var invalidTail = Data(bytes(UInt32(AgentJournal.maximumFrameSize + 1)))
        invalidTail.append(contentsOf: bytes(0))
        invalidTail.append(0x7f)
        try append(invalidTail, to: url)

        let restored = try AgentJournal.load(from: url)
        let recovery = await restored.recovery
        let recordCount = await restored.snapshot().count
        XCTAssertEqual(recovery, .corruptTail)
        XCTAssertEqual(recordCount, 1)
        try await restored.discardCorruptTail()
        _ = try await restored.append(.userMessage("after repair"), sessionID: sessionID, durability: .durable)
        let reloaded = try AgentJournal.load(from: url)
        let reloadedRecovery = await reloaded.recovery
        XCTAssertEqual(reloadedRecovery, .clean)
    }

    func testValidV2SessionScopedDuplicateIdentitiesRemainLoadableAndFailClosed() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let checkpointID = UUID()
        let sharedKey = "legacy-shared-operation"
        let first = try legacyRecord(
            schemaVersion: 2, sequence: 1, sessionID: UUID(), runID: UUID(), checkpointID: checkpointID,
            event: .pendingMutation(mutationIntent(idempotencyKey: sharedKey, callID: "legacy-first"))
        )
        let second = try legacyRecord(
            schemaVersion: 2, sequence: 2, sessionID: UUID(), runID: UUID(), checkpointID: checkpointID,
            event: .pendingMutation(mutationIntent(idempotencyKey: sharedKey, callID: "legacy-second"))
        )
        try writeLegacyJournal(schemaVersion: 2, records: [first, second], to: url)

        let restored = try AgentJournal.load(from: url)
        let pendingCount = await restored.pendingMutations().count
        XCTAssertEqual(pendingCount, 2)
        let retry = ToolMutationAdmissionRequest(
            sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "legacy-retry"),
            name: "update_listing", argumentsJSON: #"{"id":"listing-1"}"#,
            resources: [.named(.init(namespace: "property.listing", id: "listing-1"))],
            idempotencyKey: sharedKey,
            receiptExpectation: try .init(
                targets: [.init(namespace: "property.listing", id: "listing-1")], revision: .present
            )
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await restored.admit(retry)
        } verify: { error in
            XCTAssertEqual(error as? AgentJournalError, .mutationPending)
        }
    }

    func testLegacyV1PendingMutationSurvivesCompactionAndRestart() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let runID = UUID()
        let checkpointID = UUID()
        let intentJSON = #"{"call":{"id":"legacy-call","name":"update_listing","argumentsJSON":"{\"id\":\"listing-1\"}","completeness":"complete"},"resources":[{"named":{"_0":{"namespace":"property.listing","id":"listing-1"}}}],"idempotencyKey":"legacy-key"}"#
        let intent = try JSONDecoder().decode(PendingMutationIntent.self, from: Data(intentJSON.utf8))
        var records = [try legacyRecord(
            schemaVersion: 1, sequence: 1, sessionID: sessionID, runID: runID,
            checkpointID: checkpointID, event: .pendingMutation(intent)
        )]
        for sequence in 2...40 {
            records.append(try legacyRecord(
                schemaVersion: 1, sequence: UInt64(sequence), sessionID: sessionID, runID: runID,
                checkpointID: checkpointID, event: .userMessage(String(repeating: "old-history-", count: 32))
            ))
        }
        try writeLegacyJournal(schemaVersion: 1, records: records, to: url)

        let journal = try AgentJournal.load(from: url)
        let pendingBeforeCompaction = await journal.pendingMutations().map(\.state)
        let compacted = try await journal.compactIfNeeded(maxJournalBytes: 1)
        XCTAssertEqual(pendingBeforeCompaction, [.needsReconciliation])
        XCTAssertTrue(compacted)

        let restarted = try AgentJournal.load(from: url)
        let restartedPending = await restarted.pendingMutations().map(\.state)
        let compactedSchema = await restarted.snapshot().first?.schemaVersion
        XCTAssertEqual(restartedPending, [.needsReconciliation])
        XCTAssertEqual(compactedSchema, 1)
    }

    func testMiddleChecksumMismatchFailsClosed() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: UUID(), durability: .durable)
        _ = try await journal.append(.userMessage("second"), sessionID: UUID(), durability: .durable)
        var data = try Data(contentsOf: url)
        let headerCount = Data("SWIFTAGENT-JOURNAL-1".utf8).count
        let length = Int(readUInt32(data, at: headerCount))
        data[headerCount + 8 + length - 1] ^= 0x01
        try data.write(to: url)
        XCTAssertThrowsError(try AgentJournal.load(from: url)) { error in
            XCTAssertEqual(error as? AgentJournalError, .checksumMismatch)
        }
    }

    func testMiddleSequenceCorruptionFailsClosed() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        _ = try await journal.append(.userMessage("second"), sessionID: sessionID, durability: .durable)
        let records = await journal.snapshot()
        let bogus = try mutatedSequence(records[1], sequence: 99)
        let extra = try mutatedSequence(records[1], sequence: 100)
        try append(frame(payload: try JSONEncoder().encode(TestJournalFrame(schemaVersion: 2, records: [bogus]))), to: url)
        try append(frame(payload: try JSONEncoder().encode(TestJournalFrame(schemaVersion: 2, records: [extra]))), to: url)
        XCTAssertThrowsError(try AgentJournal.load(from: url)) { error in
            XCTAssertEqual(error as? AgentJournalError, .invalidRecord)
        }
    }

    func testCorruptTailKeepsPendingMutationPrefixUntilRepair() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let runID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        let call = ToolCall(id: .init(rawValue: "call-1"), name: "update_listing",
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        let expectation = try ToolReceiptExpectation(
            targets: [EvidenceReference(namespace: "property.listing", id: "listing-1")],
            revision: .present
        )
        let intent = try PendingMutationIntent(
            call: call,
            resources: [.named(EvidenceReference(namespace: "property.listing", id: "listing-1"))],
            idempotencyKey: "op-1",
            receiptExpectation: expectation
        )
        _ = try await journal.append(.pendingMutation(intent), sessionID: sessionID, runID: runID, durability: .durable)
        try append(Data(repeating: 0, count: 64), to: url)
        let restored = try AgentJournal.load(from: url)
        let mutationRecovery = await restored.recovery
        let pending = await restored.pendingMutations()
        XCTAssertEqual(mutationRecovery, .corruptTail)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].state, .intent)
        try await restored.discardCorruptTail()
        let recovered = try await restored.recoverPendingMutations(sessionID: sessionID)
        XCTAssertEqual(recovered.map(\.state), [.needsReconciliation])
    }

    func testStaleJournalInstanceCannotOverwriteAConcurrentDurableAppend() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let first = try AgentJournal(persistenceURL: url)
        let second = try AgentJournal(persistenceURL: url)
        _ = try await first.append(.sessionCreated, sessionID: UUID(), durability: .durable)

        do {
            _ = try await second.append(.sessionCreated, sessionID: UUID(), durability: .durable)
            XCTFail("Expected stale journal append to fail")
        } catch {
            XCTAssertEqual(error as? AgentJournalError, .concurrentWriter)
        }
    }

    func testCompactionShrinksHistoryAndPreservesLatestCheckpointAcrossRestart() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        for index in 0..<40 {
            _ = try await journal.appendCheckpoint([
                .userMessage(String(repeating: "audit-\(index)-", count: 20)),
                .checkpoint(history: [.user([.text("checkpoint-\(index)")])], steeringIDs: []),
            ], sessionID: sessionID, runID: UUID(), durability: .durable)
        }
        let before = try fileSize(url)

        let compacted = try await journal.compactIfNeeded(maxJournalBytes: 1)
        XCTAssertTrue(compacted)

        let after = try fileSize(url)
        XCTAssertLessThan(after, before / 4)
        let restored = try AgentJournal.load(from: url)
        let checkpoint = await restored.latestCheckpoint(sessionID: sessionID)
        XCTAssertEqual(checkpoint?.history, [.user([.text("checkpoint-39")])])
    }

    func testCompactionWaitsForMeaningfulReclaimInsteadOfRewritingEveryCheckpoint() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID()
        for _ in 0..<30 {
            _ = try await journal.append(.sessionCreated, sessionID: UUID(), durability: .durable)
        }
        _ = try await journal.append(.checkpoint(history: [.user([.text("first")])], steeringIDs: []),
                                     sessionID: sessionID, durability: .durable)
        _ = try await journal.append(.checkpoint(history: [.user([.text("second")])], steeringIDs: []),
                                     sessionID: sessionID, durability: .durable)

        let compacted = try await journal.compactIfNeeded(maxJournalBytes: 4_096)

        XCTAssertFalse(compacted)
    }

    func testCompactionPreservesPendingMutationAndRecoveryDoesNotReplay() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID(), runID = UUID()
        try await appendCompactionHistory(to: journal, sessionID: sessionID)
        let intent = try mutationIntent(idempotencyKey: "compact-pending")
        _ = try await journal.append(.pendingMutation(intent), sessionID: sessionID, runID: runID, durability: .durable)

        let compacted = try await journal.compactIfNeeded(maxJournalBytes: 1)
        XCTAssertTrue(compacted)
        let restored = try AgentJournal.load(from: url)
        let beforeRecovery = await restored.pendingMutations().map(\.state)
        let recovered = try await restored.recoverPendingMutations().map(\.state)
        let pendingCount = await restored.pendingMutations().count
        XCTAssertEqual(beforeRecovery, [.intent])
        XCTAssertEqual(recovered, [.needsReconciliation])
        XCTAssertEqual(pendingCount, 1)
    }

    func testCompactionPreservesSettledIdempotencyConflict() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let sessionID = UUID(), runID = UUID()
        let intent = try mutationIntent(idempotencyKey: "settled-key")
        _ = try await journal.append(.pendingMutation(intent), sessionID: sessionID, runID: runID, durability: .durable)
        let receipt = ToolReceipt(operationID: "settled-key", status: .succeeded,
                                  confirmedTargets: [.init(namespace: "property.listing", id: "listing-1")], revision: "v2")
        try await journal.settleMutation(sessionID: sessionID, runID: runID,
                                         callID: intent.call.id, receipt: receipt,
                                         output: .object(["updated": .bool(true)]))
        _ = try await journal.compactIfNeeded(maxJournalBytes: 1)
        let restored = try AgentJournal.load(from: url)

        await XCTAssertThrowsErrorAsync {
            _ = try await restored.append(.pendingMutation(try self.mutationIntent(idempotencyKey: "settled-key")),
                                          sessionID: sessionID, runID: UUID(), durability: .durable)
        } verify: { error in
            XCTAssertEqual(error as? AgentJournalError, .mutationIntentConflict)
        }
    }

    func testStaleWriterFailsClosedAfterCompaction() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let compacting = try AgentJournal(persistenceURL: url)
        try await appendCompactionHistory(to: compacting, sessionID: sessionID)
        _ = try await compacting.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        _ = try await compacting.append(.checkpoint(history: [.user([.text("latest")])], steeringIDs: []),
                                         sessionID: sessionID, durability: .durable)
        let stale = try AgentJournal.load(from: url)

        let compacted = try await compacting.compactIfNeeded(maxJournalBytes: 1)
        XCTAssertTrue(compacted)
        await XCTAssertThrowsErrorAsync {
            _ = try await stale.append(.userMessage("stale"), sessionID: sessionID, durability: .durable)
        } verify: { error in
            XCTAssertEqual(error as? AgentJournalError, .concurrentWriter)
        }
    }

    func testCompactionFailuresLeaveTheExistingJournalLoadable() async throws {
        for fault in [AgentJournalCompactionFault.temporaryWrite, .temporarySync, .replace] {
            let url = temporaryURL()
            defer { cleanup(url) }
            let sessionID = UUID()
            let journal = try AgentJournal(persistenceURL: url)
            try await appendCompactionHistory(to: journal, sessionID: sessionID)
            _ = try await journal.append(.checkpoint(history: [.user([.text("keep")])], steeringIDs: []),
                                         sessionID: sessionID, durability: .durable)
            await XCTAssertThrowsErrorAsync {
                _ = try await journal.compactIfNeeded(maxJournalBytes: 1, fault: fault)
            }
            let restored = try AgentJournal.load(from: url)
            let history = await restored.latestCheckpoint(sessionID: sessionID)?.history
            XCTAssertEqual(history, [.user([.text("keep")])])
        }
    }

    func testDirectorySyncFailureAdoptsTheAlreadyReplacedJournal() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        try await appendCompactionHistory(to: journal, sessionID: sessionID)
        _ = try await journal.append(.checkpoint(history: [.user([.text("keep")])], steeringIDs: []),
                                     sessionID: sessionID, durability: .durable)

        await XCTAssertThrowsErrorAsync {
            _ = try await journal.compactIfNeeded(maxJournalBytes: 1, fault: .directorySync)
        }
        _ = try await journal.append(.userMessage("after sync failure"), sessionID: sessionID, durability: .durable)
        let restored = try AgentJournal.load(from: url)
        let checkpoint = await restored.latestCheckpoint(sessionID: sessionID)
        XCTAssertEqual(checkpoint?.history, [.user([.text("keep")])])
    }

    func testCompactionRejectsCorruptTailUntilExplicitRepair() async throws {
        let url = temporaryURL()
        defer { cleanup(url) }
        let sessionID = UUID()
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: sessionID, durability: .durable)
        try append(Data(repeating: 0, count: 64), to: url)
        let restored = try AgentJournal.load(from: url)

        await XCTAssertThrowsErrorAsync {
            _ = try await restored.compactIfNeeded(maxJournalBytes: 1)
        } verify: { error in
            XCTAssertEqual(error as? AgentJournalError, .repairRequired)
        }
        let recovery = await restored.recovery
        XCTAssertEqual(recovery, .corruptTail)
    }

    func testExistingRegularLockFileDoesNotPreventALaterDurableAppend() async throws {
        let url = temporaryURL()
        let lockURL = URL(fileURLWithPath: url.path + ".lock")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: lockURL)
        }
        let journal = try AgentJournal(persistenceURL: url)
        XCTAssertTrue(FileManager.default.createFile(atPath: lockURL.path, contents: Data("stale".utf8)))

        _ = try await journal.append(.sessionCreated, sessionID: UUID(), durability: .durable)

        let records = await journal.snapshot()
        XCTAssertEqual(records.count, 1)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swift-agent-journal-\(UUID().uuidString).log")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".lock")
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
    }

    private func mutationIntent(idempotencyKey: String, callID: String = "compact-call") throws -> PendingMutationIntent {
        let call = ToolCall(id: .init(rawValue: callID), name: "update_listing",
                            argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
        return try PendingMutationIntent(
            call: call,
            resources: [.named(.init(namespace: "property.listing", id: "listing-1"))],
            idempotencyKey: idempotencyKey,
            receiptExpectation: .init(targets: [.init(namespace: "property.listing", id: "listing-1")], revision: .present)
        )
    }

    private func appendCompactionHistory(to journal: AgentJournal, sessionID: UUID) async throws {
        for index in 0..<8 {
            _ = try await journal.appendCheckpoint([
                .userMessage(String(repeating: "history-\(index)-", count: 8)),
                .checkpoint(history: [.user([.text("checkpoint-\(index)")])], steeringIDs: []),
            ], sessionID: sessionID, runID: UUID(), durability: .durable)
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func legacyRecord(
        schemaVersion: Int,
        sequence: UInt64,
        sessionID: UUID,
        runID: UUID?,
        checkpointID: UUID,
        event: AgentJournalEvent
    ) throws -> AgentJournalRecord {
        let fixture = AgentJournalRecordFixture(
            id: UUID(), sequence: sequence, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            schemaVersion: schemaVersion, sessionID: sessionID, runID: runID,
            checkpointID: checkpointID, event: event
        )
        return try JSONDecoder().decode(AgentJournalRecord.self, from: JSONEncoder().encode(fixture))
    }

    private func writeLegacyJournal(schemaVersion: Int, records: [AgentJournalRecord], to url: URL) throws {
        let payload = try JSONEncoder().encode(TestJournalFrame(schemaVersion: schemaVersion, records: records))
        var data = Data("SWIFTAGENT-JOURNAL-1".utf8)
        data.append(frame(payload: payload))
        guard FileManager.default.createFile(atPath: url.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func frame(payload: Data) -> Data {
        var frame = Data()
        frame.append(contentsOf: bytes(UInt32(payload.count)))
        frame.append(contentsOf: bytes(crc32(payload)))
        frame.append(payload)
        return frame
    }

    private func mutatedSequence(_ record: AgentJournalRecord, sequence: UInt64) throws -> AgentJournalRecord {
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["sequence"] = sequence
        let mutated = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(AgentJournalRecord.self, from: mutated)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24
            | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8
            | UInt32(data[offset + 3])
    }

    private func bytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private func crc32(_ data: Data) -> UInt32 {
        var checksum: UInt32 = 0xffffffff
        for byte in data {
            checksum ^= UInt32(byte)
            for _ in 0..<8 {
                checksum = (checksum & 1) == 0 ? checksum >> 1 : (checksum >> 1) ^ 0xedb88320
            }
        }
        return checksum ^ 0xffffffff
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    verify: (Error) -> Void = { _ in }
) async {
    do {
        try await expression()
        XCTFail("Expected error")
    } catch {
        verify(error)
    }
}

private struct TestJournalFrame: Codable {
    let schemaVersion: Int
    let records: [AgentJournalRecord]
}

private struct AgentJournalRecordFixture: Codable {
    let id: UUID
    let sequence: UInt64
    let timestamp: Date
    let schemaVersion: Int
    let sessionID: UUID
    let runID: UUID?
    let checkpointID: UUID
    let event: AgentJournalEvent
}
