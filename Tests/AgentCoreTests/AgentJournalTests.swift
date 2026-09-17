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
        let restored = try AgentJournal.load(from: url)
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

    func testCommittedFrameChecksumFailureFailsClosed() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(atPath: url.path + ".lock") }
        let journal = try AgentJournal(persistenceURL: url)
        _ = try await journal.append(.sessionCreated, sessionID: UUID(), durability: .durable)
        var data = try Data(contentsOf: url)
        data[data.count - 1] ^= 0x01
        try data.write(to: url)

        XCTAssertThrowsError(try AgentJournal.load(from: url)) { error in
            XCTAssertEqual(error as? AgentJournalError, .checksumMismatch)
        }
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

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swift-agent-journal-\(UUID().uuidString).log")
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
