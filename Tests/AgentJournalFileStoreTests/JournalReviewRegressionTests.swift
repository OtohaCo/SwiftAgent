@testable import AgentCore
@testable import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

@Suite struct JournalReviewRegressionTests {
    @Test func secondToolSettlementRestoresItsPairedAssistantCall() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "paired-tools")
        let session = UUID(), run = UUID()
        let read = ToolCall(id: .init(rawValue: "read"), name: "read", argumentsJSON: "{}", completeness: .complete)
        let write = ToolCall(id: .init(rawValue: "write"), name: "write", argumentsJSON: "{}", completeness: .complete)
        let input = ModelMessage.user([.text("do both")])
        let readResult = ModelMessage.tool(.init(callID: read.id, content: [.text("observed")], isError: false))
        let writeResult = ModelMessage.tool(.init(callID: write.id, content: [.text("written")], isError: false))
        let first: [ModelMessage] = [input, .assistant(content: [], toolCalls: [read]), readResult]
        _ = try await journal.appendCheckpoint([.checkpoint(history: first, steeringIDs: [])],
                                               sessionID: session, runID: run, durability: .durable)
        let target = EvidenceReference(namespace: "test", id: "file")
        _ = try await journal.admit(.init(sessionID: session, runID: run, callID: write.id,
                                          name: write.name, argumentsJSON: write.argumentsJSON,
                                          resources: [.named(target)], idempotencyKey: "write-once",
                                          receiptExpectation: try .init(targets: [target], revision: .present)))
        let complete: [ModelMessage] = [input, .assistant(content: [], toolCalls: [read, write]),
                                        readResult, writeResult]
        let receipt = ToolReceipt(operationID: "write-once", status: .succeeded,
                                  confirmedTargets: [target], revision: "1")
        try await journal.commitMutation(sessionID: session, runID: run, callID: write.id,
                                         receipt: receipt, output: .string("written"),
                                         history: complete, steeringIDs: [])
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == complete)
        #expect(try await reopened.mutationStatus(identity: "write-once")?.state == .settled)
        try await reopened.close()
    }

    @Test func earlierToolResultInsertedAfterSettledMutationKeepsStableMessageIDs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "out-of-order", policy: policy)
        let session = UUID(), run = UUID()
        let a = ToolCall(id: .init(rawValue: "A"), name: "read", argumentsJSON: "{}", completeness: .complete)
        let b = ToolCall(id: .init(rawValue: "B"), name: "write", argumentsJSON: "{}", completeness: .complete)
        let target = EvidenceReference(namespace: "test", id: "file")
        _ = try await journal.admit(.init(sessionID: session, runID: run, callID: b.id,
                                          name: b.name, argumentsJSON: b.argumentsJSON,
                                          resources: [.named(target)], idempotencyKey: "effect-B",
                                          receiptExpectation: try .init(targets: [target], revision: .present)))
        let input = ModelMessage.user([.text("both")])
        let resultA = ModelMessage.tool(.init(callID: a.id, content: [.text("read")], isError: false))
        let resultB = ModelMessage.tool(.init(callID: b.id, content: [.text("write")], isError: false))
        let first: [ModelMessage] = [input, .assistant(content: [], toolCalls: [b]), resultB]
        try await journal.commitMutation(sessionID: session, runID: run, callID: b.id,
                                         receipt: .init(operationID: "effect-B", status: .succeeded,
                                                        confirmedTargets: [target], revision: "1"),
                                         output: .string("write"), history: first, steeringIDs: [])
        let savedID = try #require(try await journal.readMessages(sessionID: session, after: 2).first?.id)
        let complete: [ModelMessage] = [input, .assistant(content: [], toolCalls: [a, b]), resultA, resultB]
        _ = try await journal.appendCheckpoint([.checkpoint(history: complete, steeringIDs: [])],
                                               sessionID: session, runID: run, durability: .durable)
        for _ in 0..<8 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == complete)
        #expect(try await reopened.readMessages(sessionID: session, after: 3).first?.id == savedID)
        #expect(try await reopened.mutationStatus(identity: "effect-B")?.state == .settled)
        try await reopened.close()
    }

    @Test func abortRetryAcceptsSemanticallyEquivalentArgumentOrder() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "semantic-abort")
        let target = EvidenceReference(namespace: "test", id: "file")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let first = ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "first"),
                                                name: "write", argumentsJSON: #"{"a":1,"b":2}"#,
                                                resources: [.named(target)], idempotencyKey: "same-effect",
                                                receiptExpectation: expectation)
        _ = try await journal.admit(first)
        let pending = try #require(try await journal.recoverPendingMutations(sessionID: first.sessionID).first)
        try await journal.abortMutation(pending,
            confirmedNoEffect: AgentNoEffectConfirmation(basis: "verified no effect"))
        let retry = ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "retry"),
                                                 name: "write", argumentsJSON: #"{"b":2,"a":1}"#,
                                                 resources: [.named(target)], idempotencyKey: "same-effect",
                                                 receiptExpectation: expectation)
        guard case .admitted = try await journal.admit(retry) else {
            Issue.record("equivalent retry must be admitted"); return
        }
        try await journal.close()
    }

    @Test func changedFormatDomainCannotRelabelAnExistingLedger() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "original-domain")
        try await journal.close()
        let url = directory.appendingPathComponent("format.json")
        let original = try Data(contentsOf: url)
        let changed = String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "original-domain", with: "different-domain")
        #expect(changed != String(decoding: original, as: UTF8.self))
        try Data(changed.utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
    }

    @Test func corruptMaximumFrameLengthFailsAsAnErrorInAChildProcess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "length")
        _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("one")])], steeringIDs: [])],
                                               sessionID: UUID(), runID: UUID(), durability: .durable)
        try await journal.close()
        let segment = try #require(FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("segments"), includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forUpdating: segment)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([0xff, 0xff, 0xff, 0xff]))
        try handle.close()
        let child = try launchProbe(directory)
        child.waitUntilExit()
        #expect(child.terminationReason == .exit)
        #expect(child.terminationStatus == 1)
    }

    @Test func openingAnActiveSegmentSymlinkNeverTruncatesAnExternalFile() async throws {
        let directory = temporaryDirectory()
        let outside = temporaryDirectory().appendingPathExtension("sentinel")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "symlink")
        try await journal.close()
        let segment = try #require(FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("segments"), includingPropertiesForKeys: nil).first)
        let sentinel = Data("EXTERNAL SENTINEL".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.removeItem(at: segment)
        try FileManager.default.createSymbolicLink(at: segment, withDestinationURL: outside)
        do {
            _ = try AgentIncrementalJournal.open(at: directory)
            Issue.record("symlink segment must be rejected")
        } catch { }
        #expect(try Data(contentsOf: outside) == sentinel)
    }

    @Test func zeroLengthActiveSegmentSymlinkIsRejectedAtOpen() async throws {
        let directory = temporaryDirectory()
        let outside = temporaryDirectory().appendingPathExtension("empty")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "empty-link")
        try await journal.close()
        let segment = try #require(FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("segments"), includingPropertiesForKeys: nil).first)
        try Data().write(to: outside)
        try FileManager.default.removeItem(at: segment)
        try FileManager.default.createSymbolicLink(at: segment, withDestinationURL: outside)
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
        #expect(try Data(contentsOf: outside).isEmpty)
    }

    @Test func formatSymlinkCannotBorrowAnotherFileIdentity() async throws {
        let directory = temporaryDirectory()
        let outside = temporaryDirectory().appendingPathExtension("format")
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "owned-format")
        try await journal.close()
        let format = directory.appendingPathComponent("format.json")
        let saved = try Data(contentsOf: format)
        try saved.write(to: outside)
        try FileManager.default.removeItem(at: format)
        try FileManager.default.createSymbolicLink(at: format, withDestinationURL: outside)
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
        #expect(try Data(contentsOf: outside) == saved)
    }

    @Test func garbageCollectionCannotFollowAManagedDirectorySymlink() async throws {
        let directory = temporaryDirectory()
        let outside = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "gc-symlink")
        let storeID = try #require(await journal.storeIdentity()?.storeID)
        try await journal.close()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("\(storeID.uuidString)_\(UUID().uuidString).tmp")
        try Data("external".utf8).write(to: sentinel)
        let tmp = directory.appendingPathComponent("tmp")
        try FileManager.default.moveItem(at: tmp, to: directory.appendingPathComponent("tmp.saved"))
        try FileManager.default.createSymbolicLink(at: tmp, withDestinationURL: outside)
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
        #expect(try Data(contentsOf: sentinel) == Data("external".utf8))
    }

    @Test func supersededIntentBlobIsReclaimedButSettledOutputRemains() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 3)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "blob-gc", policy: policy)
        let session = UUID(), run = UUID(), callID = ToolCallID(rawValue: "write")
        let args = #"{"payload":""# + String(repeating: "x", count: 2200) + #""}"#
        let target = EvidenceReference(namespace: "test", id: "item")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        _ = try await journal.admit(.init(sessionID: session, runID: run, callID: callID,
                                          name: "write", argumentsJSON: args,
                                          resources: [.named(target)], idempotencyKey: "effect",
                                          receiptExpectation: expectation))
        let receipt = ToolReceipt(operationID: "effect", status: .succeeded,
                                  confirmedTargets: [target], revision: "1")
        let history: [ModelMessage] = [
            .user([.text("write")]),
            .assistant(content: [], toolCalls: [.init(id: callID, name: "write",
                                                      argumentsJSON: args, completeness: .complete)]),
            .tool(.init(callID: callID, content: [.text("done")], isError: false)),
        ]
        try await journal.commitMutation(sessionID: session, runID: run, callID: callID,
                                         receipt: receipt, output: .string("done"),
                                         history: history, steeringIDs: [])
        _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                               sessionID: session, runID: run, durability: .durable)
        for _ in 0..<10 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        #expect(try blobCount(directory) == 1)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.mutationStatus(identity: "effect")?.replayOutput == .string("done"))
        try await reopened.close()
    }

    @Test func obsoleteProcessOnlySegmentsDoNotPublishEmptyStatePacks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.create(at: directory,
                                                         operationDomain: "empty-packs", policy: policy)
        let session = UUID()
        for turn in 0..<8 {
            _ = try await journal.append(.modelAttempt(turn: turn, model: .init(provider: "fixture", name: "test")),
                                         sessionID: session, runID: UUID(), durability: .durable)
        }
        for _ in 0..<20 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        let packs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("state"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "pack" }
        #expect(packs.count <= 1)
        try await journal.close()
    }

    @Test func statePacksSupersededByLaterProcessCommitsAreReclaimed() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.create(at: directory,
                                                         operationDomain: "obsolete-packs", policy: policy)
        let session = UUID()
        for turn in 0..<8 {
            _ = try await journal.append(.modelAttempt(turn: turn, model: .init(provider: "fixture", name: "test")),
                                         sessionID: session, runID: UUID(), durability: .durable)
            for _ in 0..<3 {
                if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
            }
        }
        for _ in 0..<24 { _ = try await journal.requestMaintenance() }
        let packs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("state"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "pack" }
        #expect(packs.count <= 1)
        try await journal.close()
    }

    @Test func publishedObsoletePackCleanupResumesAfterInterruptedDeletion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let gate = ReviewFaultOnce(.beforePackDelete)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "pack-retry", policy: policy, fault: { try gate.check($0) })
        let session = UUID()
        for turn in 0..<4 {
            _ = try await journal.append(.modelAttempt(turn: turn, model: .init(provider: "fixture", name: "test")),
                                         sessionID: session, runID: UUID(), durability: .durable)
            _ = try? await journal.requestMaintenance()
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        for _ in 0..<20 { _ = try await reopened.requestMaintenance() }
        let packs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("state"),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "pack" }
        #expect(packs.count <= 1)
        try await reopened.close()
    }

    @Test func automaticMaintenanceEventuallyReclaimsObsoletePacksWithoutHostCalls() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.create(at: directory,
                                                         operationDomain: "automatic-pack-gc", policy: policy)
        let session = UUID()
        for turn in 0..<8 {
            _ = try await journal.append(.modelAttempt(turn: turn, model: .init(provider: "fixture", name: "test")),
                                         sessionID: session, runID: UUID(), durability: .durable)
        }
        var complete = false
        for _ in 0..<5000 {
            let status = try #require(try await journal.storeStatus())
            let packs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("state"),
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "pack" }
            if status.sealedSegments == 0 && status.pendingGarbageSegments == 0 &&
               status.pendingGarbagePacks == 0 && packs.count <= 1 {
                complete = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(complete)
        try await journal.close()
    }

    @Test func publishedRootCanFinishDiscardedBlobCleanupAfterDeletionFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 3)
        let gate = ReviewFaultOnce(.beforeSegmentDelete)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "gc-retry", policy: policy, fault: { try gate.check($0) })
        let session = UUID(), run = UUID(), call = ToolCallID(rawValue: "large-intent")
        let args = #"{"payload":""# + String(repeating: "z", count: 2200) + #""}"#
        let target = EvidenceReference(namespace: "test", id: "item")
        _ = try await journal.admit(.init(sessionID: session, runID: run, callID: call,
                                          name: "write", argumentsJSON: args,
                                          resources: [.named(target)], idempotencyKey: "gc-effect",
                                          receiptExpectation: try .init(targets: [target], revision: .present)))
        let history: [ModelMessage] = [
            .user([.text("write")]),
            .assistant(content: [], toolCalls: [.init(id: call, name: "write", argumentsJSON: args,
                                                      completeness: .complete)]),
            .tool(.init(callID: call, content: [.text("done")], isError: false)),
        ]
        try await journal.commitMutation(sessionID: session, runID: run, callID: call,
                                         receipt: .init(operationID: "gc-effect", status: .succeeded,
                                                        confirmedTargets: [target], revision: "1"),
                                         output: .string("done"), history: history, steeringIDs: [])
        _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                               sessionID: session, runID: run, durability: .durable)
        _ = try? await journal.requestMaintenance()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        for _ in 0..<8 {
            _ = try await reopened.requestMaintenance()
        }
        #expect(try blobCount(directory) == 1)
        #expect(try await reopened.mutationStatus(identity: "gc-effect")?.state == .settled)
        try await reopened.close()
    }

    private func blobCount(_ directory: URL) throws -> Int {
        let root = directory.appendingPathComponent("blobs")
        let shards = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try shards.reduce(0) { count, shard in
            count + (try FileManager.default.contentsOfDirectory(at: shard,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "blob" }.count)
        }
    }

    private func launchProbe(_ directory: URL) throws -> Process {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let options = [root.appendingPathComponent(".build/out/Products/Debug/JournalTestProcess"),
                       root.appendingPathComponent(".build/debug/JournalTestProcess")]
        let process = Process()
        let executable: URL = try #require(options.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        process.executableURL = executable
        process.arguments = ["probe", directory.path]
        process.standardError = Pipe()
        try process.run()
        return process
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("swiftagent-review-\(UUID().uuidString)")
    }
}

private final class ReviewFaultOnce: @unchecked Sendable {
    private let lock = NSLock()
    private let stage: JournalFileFaultStage
    private var armed = true
    init(_ stage: JournalFileFaultStage) { self.stage = stage }
    func check(_ candidate: JournalFileFaultStage) throws {
        lock.lock()
        let fail = armed && stage == candidate
        if fail { armed = false }
        lock.unlock()
        if fail { throw AgentJournalError.persistenceUnavailable("injected GC interruption") }
    }
}
