@testable import AgentCore
@testable import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct SegmentedJournalStoreTests {
    @Test func appendRestoreAndSharedIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-v4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "account/one")
        let session = UUID(), run = UUID()
        let first: ModelMessage = .user([.text("hello")])
        _ = try await journal.appendCheckpoint([.sessionCreated, .checkpoint(history: [first], steeringIDs: [])],
                                                sessionID: session, runID: run, durability: .durable)
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == [first])
        #expect(try await journal.readMessages(sessionID: session).map(\.message) == [first])

        let target = EvidenceReference(namespace: "test.file", id: "temporary")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let key = "stable-operation/tool/{\"id\":\"temporary\"}"
        let callID = ToolCallID(rawValue: "first-call")
        let request = ToolMutationAdmissionRequest(sessionID: session, runID: run, callID: callID,
                                                    name: "write", argumentsJSON: #"{"id":"temporary"}"#,
                                                    resources: [.named(target)], idempotencyKey: key,
                                                    receiptExpectation: expectation)
        guard case .admitted = try await journal.admit(request) else { Issue.record("expected admission"); return }
        let receipt = ToolReceipt(operationID: key, status: .succeeded,
                                  confirmedTargets: [target], revision: "2")
        let result: ModelMessage = .tool(.init(callID: callID, content: [.text("written")], isError: false))
        try await journal.commitMutation(sessionID: session, runID: run, callID: callID,
                                         receipt: receipt, output: .string("written"),
                                         history: [first, result], steeringIDs: [])
        #expect(try await journal.pendingMutations(sessionID: session).isEmpty)
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == [first, result])
        let retry = ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "retry"),
                                                 name: "write", argumentsJSON: #"{"id":"temporary"}"#,
                                                 resources: [.named(target)], idempotencyKey: key,
                                                 receiptExpectation: expectation)
        guard case .settled(let replayReceipt, let output) = try await reopened.admit(retry) else {
            Issue.record("retry must reuse the result"); return
        }
        #expect(replayReceipt == receipt)
        #expect(output == .string("written"))
        try await reopened.close()
    }

    @Test func oldFileIsNotOpenedOrOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-old-\(UUID().uuidString)")
        let old = Data("SWIFTAGENT-JOURNAL-1".utf8)
        try old.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: url) }
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.create(at: url, operationDomain: "one") }
        #expect(try Data(contentsOf: url) == old)
    }

    @Test func segmentsRotateAndReclaimWithoutLosingFormalMessages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-gc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "gc", policy: policy)
        let session = UUID(), other = UUID()
        var formal: [ModelMessage] = []
        for index in 0..<15 {
            formal.append(.user([.text("turn \(index) " + String(repeating: "x", count: 70))]))
            let id = index.isMultiple(of: 3) ? other : session
            let messages = id == other ? Array(formal.enumerated().filter { $0.offset.isMultiple(of: 3) }.map(\.element))
                                       : Array(formal.enumerated().filter { !$0.offset.isMultiple(of: 3) }.map(\.element))
            _ = try await journal.appendCheckpoint([.checkpoint(history: messages, steeringIDs: [])],
                                                    sessionID: id, runID: UUID(), durability: .durable)
        }
        for _ in 0..<20 {
            let status = try await journal.requestMaintenance()
            if status?.sealedSegments == 0 { break }
        }
        let status = try #require(await journal.maintenanceStatus())
        #expect(status.sealedSegments == 0)
        let segmentFiles = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("segments"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "seg" }
        #expect(segmentFiles.count == 1)
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history.count == 10)
        #expect(try await journal.latestCheckpoint(sessionID: other)?.history.count == 5)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.readMessages(sessionID: other).count == 5)
        #expect(try await reopened.readMessages(sessionID: session).count == 10)
        try await reopened.close()
    }

    @Test func onlyOneStoreHandleOwnsTheDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "same")
        #expect(throws: AgentJournalError.storeInUse) {
            _ = try AgentIncrementalJournal.open(at: directory.appendingPathComponent("..")
                .appendingPathComponent(directory.lastPathComponent))
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        try await reopened.close()
    }

    @Test func unicodeMessagesKeepIdentityAfterReclamation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-unicode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "unicode", policy: policy)
        let session = UUID()
        let original: [ModelMessage] = (0..<8).map { .user([.text("日本語の記録 🐈 \($0)" + String(repeating: "字", count: 40))]) }
        for count in 1...original.count {
            _ = try await journal.appendCheckpoint([.checkpoint(history: Array(original.prefix(count)), steeringIDs: [])],
                                                    sessionID: session, runID: UUID(), durability: .durable)
        }
        let identifiers = try await journal.readMessages(sessionID: session, limit: 100).map(\.id)
        for _ in 0..<16 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        let recovered = try await reopened.readMessages(sessionID: session, limit: 100)
        #expect(recovered.map(\.message) == original)
        #expect(recovered.map(\.id) == identifiers)
        try await reopened.close()
    }

    @Test func independentProcessCannotOpenAndCrashReleasesOwnership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-process-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try AgentIncrementalJournal.create(at: directory, operationDomain: "one-owner")
        let denied = try launch("probe", directory: directory)
        denied.waitUntilExit()
        #expect(denied.terminationStatus == 42)
        try await owner.close()

        let child = try launch("hold", directory: directory)
        defer { if child.isRunning { _ = kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let output = child.standardOutput as! Pipe
        #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("READY\n".utf8))
        #expect(throws: AgentJournalError.storeInUse) { _ = try AgentIncrementalJournal.open(at: directory) }
        _ = kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal)

        let recovered = try AgentIncrementalJournal.open(at: directory)
        try await recovered.close()
        let commit = try launch("commit-and-exit", directory: directory)
        commit.waitUntilExit()
        #expect(commit.terminationStatus == 0)
        let restarted = try AgentIncrementalJournal.open(at: directory)
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
        #expect(try await restarted.latestCheckpoint(sessionID: session)?.history == [
            .user([.text("committed before process exit")])
        ])
        try await restarted.close()
    }

    @Test(arguments: [JournalFileFaultStage.beforeAppend, .partialAppend, .beforeAppendSync,
                      .afterAppendSync, .beforeManagedWrite, .beforeManagedSync, .afterIndexSync])
    func failedPrepublicationBatchNeverAppearsAsCommitted(_ stage: JournalFileFaultStage) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "fault", fault: { try gate.check($0) })
        gate.arm(stage)
        let session = UUID()
        await #expect(throws: (any Error).self) {
            _ = try await journal?.appendCheckpoint([
                .checkpoint(history: [.user([.text("not committed")])], steeringIDs: [])
            ], sessionID: session, runID: UUID(), durability: .durable)
        }
        journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session) == nil)
        #expect(try await reopened.readMessages(sessionID: session).isEmpty)
        _ = try await reopened.appendCheckpoint([
            .checkpoint(history: [.user([.text("recovered writer")])], steeringIDs: [])
        ], sessionID: session, runID: UUID(), durability: .durable)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == [.user([.text("recovered writer")])])
        try await reopened.close()
    }

    @Test func uncertainRootSyncQuarantinesIntentAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-uncertain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "uncertain", fault: { try gate.check($0) })
        gate.arm(.afterCurrentReplace)
        let session = UUID()
        let target = EvidenceReference(namespace: "fixture", id: "one")
        let request = ToolMutationAdmissionRequest(sessionID: session, runID: UUID(), callID: .init(rawValue: "call"),
                                                    name: "write", argumentsJSON: "{}",
                                                    resources: [.named(target)], idempotencyKey: "effect-one",
                                                    receiptExpectation: try .init(targets: [target], revision: .present))
        await #expect(throws: (any Error).self) { _ = try await journal?.admit(request) }
        journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let unknown = try await reopened.recoverPendingMutations(sessionID: session)
        #expect(unknown.map(\.state) == [.needsReconciliation])
        await #expect(throws: AgentJournalError.mutationRequiresReconciliation) {
            _ = try await reopened.admit(request)
        }
        try await reopened.close()
    }

    @Test func unpublishedTailIsTruncatedButCommittedFrameDamageFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-tail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "tail")
        let session = UUID()
        _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("safe")])], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        try await journal.close()
        let segmentDirectory = directory.appendingPathComponent("segments")
        let segment = try #require(FileManager.default.contentsOfDirectory(at: segmentDirectory,
            includingPropertiesForKeys: nil).first { $0.pathExtension == "seg" })
        let original = try Data(contentsOf: segment)
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0, 0, 0, 100, 1, 2]))
        try handle.close()
        let recovered = try AgentIncrementalJournal.open(at: directory)
        #expect(try await recovered.latestCheckpoint(sessionID: session)?.history == [.user([.text("safe")])])
        try await recovered.close()
        #expect(try Data(contentsOf: segment) == original)
        var damaged = original
        damaged[damaged.count - 1] ^= 0xff
        try damaged.write(to: segment)
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
    }

    @Test func unknownSchemaAndDamagedRootFailWithoutReset() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-format-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "format")
        try await journal.close()
        let format = directory.appendingPathComponent("format.json")
        let original = try Data(contentsOf: format)
        let modified = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "\"schema\":1", with: "\"schema\":999")
        try Data(modified.utf8).write(to: format)
        #expect(throws: AgentJournalError.unsupportedFormat) { _ = try AgentIncrementalJournal.open(at: directory) }
        try original.write(to: format)
        let current = directory.appendingPathComponent("CURRENT")
        try Data("not a root".utf8).write(to: current)
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
        #expect(try Data(contentsOf: current) == Data("not a root".utf8))
    }

    @Test func maintenanceCandidatePreservesForegroundCommitsAfterItsSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-interleave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pause = JournalMaintenancePause()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192,
                                                  maxUnreclaimedBytes: 32768)
        let journal = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "interleave", policy: policy,
            fault: { if $0 == .afterMaintenanceSnapshot { pause.waitOnce() } })
        let first = UUID(), second = UUID()
        var history: [ModelMessage] = []
        for index in 0..<15 {
            history.append(.user([.text("before \(index)")]))
            _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                                   sessionID: first, runID: UUID(), durability: .durable)
            if pause.didEnter { break }
        }
        await pause.waitUntilEntered()
        history.append(.assistant(content: [.text("after S+1")], toolCalls: []))
        _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                               sessionID: first, runID: UUID(), durability: .durable)
        let target = EvidenceReference(namespace: "fixture", id: "second")
        let run = UUID(), call = ToolCallID(rawValue: "post-snapshot")
        _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("S+2")])], steeringIDs: [])],
                                               sessionID: second, runID: run, durability: .durable)
        _ = try await journal.admit(.init(sessionID: second, runID: run, callID: call, name: "write",
                                          argumentsJSON: "{}", resources: [.named(target)],
                                          idempotencyKey: "after-snapshot-operation",
                                          receiptExpectation: .init(targets: [target], revision: .present)))
        let receipt = ToolReceipt(operationID: "after-snapshot-operation", status: .succeeded,
                                  confirmedTargets: [target], revision: "committed")
        try await journal.commitMutation(sessionID: second, runID: run, callID: call,
                                         receipt: receipt, output: .string("persisted"),
                                         history: [.user([.text("S+2")]),
                                                   .tool(.init(callID: call, content: [.text("persisted")], isError: false))],
                                         steeringIDs: [])
        let beforeMaintenance = try #require(try await journal.storeStatus())
        pause.release()
        for _ in 0..<25 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        let afterMaintenance = try #require(try await journal.storeStatus())
        #expect(afterMaintenance.logicalSequence == beforeMaintenance.logicalSequence)
        #expect(afterMaintenance.layoutGeneration > beforeMaintenance.layoutGeneration)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: first)?.history == history)
        #expect(try await reopened.latestCheckpoint(sessionID: second)?.history.count == 2)
        #expect(try await reopened.mutationStatus(identity: "after-snapshot-operation")?.receipt == receipt)
        try await reopened.close()
    }

    @Test func orphanBlobIsReclaimedWithoutTouchingUnknownOrLinkedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-orphans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384)
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "orphans", policy: policy,
            fault: { try gate.check($0) })
        let ownedID = try #require(await journal?.storeIdentity()?.storeID)
        gate.arm(.beforeAppend)
        await #expect(throws: (any Error).self) {
            _ = try await journal?.appendCheckpoint([
                .checkpoint(history: [.user([.text(String(repeating: "large-output", count: 300))])], steeringIDs: [])
            ], sessionID: UUID(), runID: UUID(), durability: .durable)
        }
        journal = nil
        let stranger = directory.appendingPathComponent("tmp/keep-my-file.txt")
        try Data("keep".utf8).write(to: stranger)
        let managedOrphan = directory.appendingPathComponent("tmp/\(ownedID.uuidString)_\(UUID().uuidString).tmp")
        try Data("orphan".utf8).write(to: managedOrphan)
        let unknownUUID = directory.appendingPathComponent("tmp/\(UUID().uuidString).tmp")
        try Data("unknown".utf8).write(to: unknownUUID)
        let foreignSegment = directory.appendingPathComponent(
            "segments/\(UUID().uuidString)_\(UUID().uuidString).seg")
        try Data("another store".utf8).write(to: foreignSegment)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("journal-outside-\(UUID().uuidString)")
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = directory.appendingPathComponent("tmp/\(ownedID.uuidString)_\(UUID().uuidString).tmp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        for _ in 0..<256 { _ = try await reopened.requestMaintenance() }
        let blobs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("blobs"),
            includingPropertiesForKeys: nil)
        let survivors = try blobs.flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        #expect(survivors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: managedOrphan.path))
        #expect(try Data(contentsOf: unknownUUID) == Data("unknown".utf8))
        #expect(try Data(contentsOf: foreignSegment) == Data("another store".utf8))
        #expect(try Data(contentsOf: stranger) == Data("keep".utf8))
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        try await reopened.close()
    }

    @Test(arguments: [JournalFileFaultStage.afterIndexSync, .afterCurrentReplace])
    func settlementAndConversationStayInTheSamePublishedBatch(_ stage: JournalFileFaultStage) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-settlement-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "settlement", fault: { try gate.check($0) })
        let session = UUID(), run = UUID(), call = ToolCallID(rawValue: "mutation")
        let target = EvidenceReference(namespace: "fixture", id: "target")
        let request = ToolMutationAdmissionRequest(sessionID: session, runID: run, callID: call,
                                                    name: "write", argumentsJSON: "{}",
                                                    resources: [.named(target)], idempotencyKey: "effect",
                                                    receiptExpectation: try .init(targets: [target], revision: .present))
        _ = try await journal?.admit(request)
        let receipt = ToolReceipt(operationID: "effect", status: .succeeded,
                                  confirmedTargets: [target], revision: "v2")
        let history: [ModelMessage] = [
            .user([.text("commit")]),
            .assistant(content: [], toolCalls: [.init(id: call, name: "write", argumentsJSON: "{}", completeness: .complete)]),
            .tool(.init(callID: call, content: [.text("done")], isError: false)),
        ]
        gate.arm(stage)
        await #expect(throws: (any Error).self) {
            try await journal?.commitMutation(sessionID: session, runID: run,
                                               callID: call, receipt: receipt,
                                               output: .string("done"), history: history, steeringIDs: [])
        }
        journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let status = try #require(try await reopened.mutationStatus(identity: "effect"))
        if stage == .afterIndexSync {
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

    @Test func publishedMaintenanceCanResumeDeletionAfterFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-gc-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192,
                                                  maxUnreclaimedBytes: 32768)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "gc-failure", policy: policy, fault: { try gate.check($0) })
        let session = UUID()
        var history: [ModelMessage] = []
        for index in 0..<8 {
            history.append(.user([.text("item \(index)")]))
            _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])],
                                                   sessionID: session, runID: UUID(), durability: .durable)
        }
        gate.arm(.beforeSegmentDelete)
        // An automatic candidate might have won the race. A manual pass must
        // still be safe and eventually remove every sealed segment.
        _ = try? await journal.requestMaintenance()
        for _ in 0..<20 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == history)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == history)
        try await reopened.close()
    }

    @Test func uncertainStartupReturnsAnOwnedFailedRunWithoutCallingModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-start-unknown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(
            at: directory, operationDomain: "unknown-start", fault: { try gate.check($0) })
        let probe = FixtureModelProbe()
        let agent = try Agent(model: .init(provider: "journal-fixture", name: "fixture"),
                              provider: FixtureModel(probe: probe))
        let sessionID = UUID()
        var session: AgentSession? = try agent.makeSession(id: sessionID, journal: journal)
        gate.arm(.afterCurrentReplace)
        let run = try await session!.run("input that may have committed")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await probe.calls == 0)
        session = nil
        journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: sessionID)?.history == [
            .user([.text("input that may have committed")])
        ])
        try await reopened.close()
    }

    @Test func closeWaitsForTheSessionLeaseAndCannotUnlockAnActiveRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "close")
        let sessionID = UUID()
        try await journal.acquireSessionLease(sessionID: sessionID)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        #expect(throws: AgentJournalError.storeInUse) { _ = try AgentIncrementalJournal.open(at: directory) }
        await journal.releaseSessionLease(sessionID: sessionID)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        try await reopened.close()
    }

    @Test func failedCloseRetainsOwnershipUntilRetrySucceeds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-close-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "close-fault", fault: { try gate.check($0) })
        gate.arm(.beforeClose)
        await #expect(throws: (any Error).self) { try await journal.close() }
        #expect(throws: AgentJournalError.storeInUse) { _ = try AgentIncrementalJournal.open(at: directory) }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        try await reopened.close()
    }

    @Test func failedCreationDoesNotBecomeAnEmptyUsableLedger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-create-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        gate.arm(.beforeCurrentReplace)
        #expect(throws: (any Error).self) {
            _ = try AgentIncrementalJournal.createForTesting(at: directory,
                operationDomain: "create", fault: { try gate.check($0) })
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: (any Error).self) { _ = try AgentIncrementalJournal.open(at: directory) }
        #expect(throws: (any Error).self) {
            _ = try AgentIncrementalJournal.create(at: directory, operationDomain: "replacement")
        }
    }

    @Test func rotationFailureDoesNotDiscardThePublishedBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-rotation-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "rotate", policy: policy, fault: { try gate.check($0) })
        gate.arm(.beforeRotation)
        let session = UUID()
        let first = ModelMessage.user([.text("published before rotation")])
        _ = try await journal.appendCheckpoint([.checkpoint(history: [first], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        #expect(try await journal.latestCheckpoint(sessionID: session)?.history == [first])
        #expect(try await journal.maintenanceStatus()?.lastError != nil)
        _ = try await journal.appendCheckpoint([.checkpoint(history: [first, .user([.text("next")])], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history.count == 2)
        try await reopened.close()
    }

    @Test func unpublishedMaintenanceCandidateCannotReplaceTheOldRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-candidate-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = JournalFaultGate()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        var journal: AgentJournal? = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "candidate", policy: policy, fault: { try gate.check($0) })
        gate.arm(.beforeMaintenancePublish)
        let session = UUID()
        let original = ModelMessage.user([.text("must survive an unpublished candidate")])
        _ = try await journal?.appendCheckpoint([.checkpoint(history: [original], steeringIDs: [])],
                                                sessionID: session, runID: UUID(), durability: .durable)
        _ = try? await journal?.requestMaintenance()
        journal = nil
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == [original])
        for _ in 0..<8 { if try await reopened.requestMaintenance()?.sealedSegments == 0 { break } }
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == [original])
        try await reopened.close()
    }

    @Test func activeReaderPinsOldSegmentUntilItsReadFinishes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-reader-pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = JournalMaintenancePause(), reader = JournalMaintenancePause()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "read-pin", policy: policy, fault: { stage in
                if stage == .afterMaintenanceSnapshot { candidate.waitOnce() }
                if stage == .beforeSessionRead { reader.waitOnce() }
            })
        let session = UUID()
        _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("pinned")])], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        await candidate.waitUntilEntered()
        let reading = Task { try await journal.readMessages(sessionID: session) }
        await reader.waitUntilEntered()
        candidate.release()
        let segmentDirectory = directory.appendingPathComponent("segments")
        let duringRead = try FileManager.default.contentsOfDirectory(at: segmentDirectory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "seg" }
        #expect(duringRead.count == 2)
        reader.release()
        #expect(try await reading.value.map(\.message) == [.user([.text("pinned")])])
        for _ in 0..<8 { if try await journal.requestMaintenance()?.sealedSegments == 0 { break } }
        let afterRead = try FileManager.default.contentsOfDirectory(at: segmentDirectory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "seg" }
        #expect(afterRead.count == 1)
        try await journal.close()
    }

    @Test func domainLabelDoesNotJoinIndependentStores() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("journal-domains-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let first = try AgentIncrementalJournal.create(at: parent.appendingPathComponent("a"), operationDomain: "same-label")
        let second = try AgentIncrementalJournal.create(at: parent.appendingPathComponent("b"), operationDomain: "same-label")
        let identityA = try #require(await first.storeIdentity())
        let identityB = try #require(await second.storeIdentity())
        #expect(identityA.storeID != identityB.storeID)
        #expect(identityA.operationDomain == identityB.operationDomain)
        let target = EvidenceReference(namespace: "fixture", id: "shared-label")
        let session = UUID()
        for journal in [first, second] {
            let request = ToolMutationAdmissionRequest(sessionID: session, runID: UUID(), callID: .init(rawValue: "call"),
                                                        name: "write", argumentsJSON: "{}",
                                                        resources: [.named(target)], idempotencyKey: "identity",
                                                        receiptExpectation: try .init(targets: [target], revision: .present))
            guard case .admitted = try await journal.admit(request) else { Issue.record("each store admits independently"); return }
        }
        try await first.close()
        try await second.close()
    }

    @Test func asyncOpenChecksDeadlineAndNeverCreatesMissingStores() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-async-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: AgentJournalError.deadlineExceeded) {
            _ = try await AgentIncrementalJournal.createAsync(
                at: directory, operationDomain: "budget", deadline: .now.advanced(by: .milliseconds(-1)))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: AgentJournalError.persistenceUnavailable("store does not exist; call create explicitly")) {
            _ = try await AgentIncrementalJournal.openAsync(at: directory)
        }
        let journal = try await AgentIncrementalJournal.createAsync(at: directory, operationDomain: "budget")
        try await journal.close()
        let reopened = try await AgentIncrementalJournal.openAsync(at: directory)
        try await reopened.close()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AgentIncrementalJournal.openAsync(at: directory)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        let afterCancellation = try AgentIncrementalJournal.open(at: directory)
        try await afterCancellation.close()
    }

    @Test func cancellationOfMaintenanceWaiterKeepsItsCandidateOwnedUntilPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-cancel-maint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pause = JournalMaintenancePause()
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 4096,
                                                  maxUnreclaimedBytes: 16384, maxSegmentBatches: 1)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "cancel-maint", policy: policy, fault: {
                if $0 == .afterMaintenanceSnapshot { pause.waitOnce() }
            })
        let session = UUID(), expected = ModelMessage.user([.text("preserved")])
        _ = try await journal.appendCheckpoint([.checkpoint(history: [expected], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        await pause.waitUntilEntered()
        let waiting = Task { try await journal.requestMaintenance() }
        waiting.cancel()
        pause.release()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == [expected])
        try await reopened.close()
    }

    @Test func indexedStateAndLayoutDamageFailInsteadOfReturningEmptyHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-index-damage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "damage")
        let session = UUID()
        _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("formal fact")])], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        try await journal.close()
        let messageRoot = directory.appendingPathComponent("messages")
        let shard = try #require(FileManager.default.contentsOfDirectory(at: messageRoot,
            includingPropertiesForKeys: nil).first)
        let indexURL = try #require(FileManager.default.contentsOfDirectory(at: shard,
            includingPropertiesForKeys: nil).first)
        let saved = try Data(contentsOf: indexURL)
        var broken = saved
        broken[broken.count - 3] ^= 0x01
        try broken.write(to: indexURL)
        let opened = try AgentIncrementalJournal.open(at: directory)
        await #expect(throws: (any Error).self) {
            _ = try await opened.readMessages(sessionID: session)
        }
        try await opened.close()
        try saved.write(to: indexURL)

        let current = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("CURRENT"))) as! [String: Any]
        let rootID = try #require(current["root"] as? String)
        let format = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as! [String: Any]
        let ownedID = try #require(format["storeID"] as? String)
        let rootURL = directory.appendingPathComponent("roots/\(ownedID)_\(rootID).json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: rootURL)) as! [String: Any]
        let layoutID = try #require(root["layout"] as? String)
        let layoutURL = directory.appendingPathComponent("layouts/\(ownedID)_\(layoutID).json")
        let layout = try Data(contentsOf: layoutURL)
        var damaged = layout
        damaged[damaged.count - 3] ^= 0x01
        try damaged.write(to: layoutURL)
        #expect(throws: AgentJournalError.checksumMismatch) { _ = try AgentIncrementalJournal.open(at: directory) }
        #expect(try Data(contentsOf: layoutURL) == damaged)
    }

    @Test func externallyChangedCurrentRootIsRejectedByTheActiveOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-external-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "owned")
        let session = UUID()
        let first = ModelMessage.user([.text("first")])
        _ = try await journal.appendCheckpoint([.checkpoint(history: [first], steeringIDs: [])],
                                               sessionID: session, runID: UUID(), durability: .durable)
        let current = directory.appendingPathComponent("CURRENT")
        let saved = try Data(contentsOf: current)
        var altered = saved
        altered[altered.count - 3] ^= 0x01
        try altered.write(to: current)
        await #expect(throws: AgentJournalError.concurrentWriter) { _ = try await journal.storeStatus() }
        await #expect(throws: AgentJournalError.concurrentWriter) {
            _ = try await journal.appendCheckpoint([
                .checkpoint(history: [first, .user([.text("must not overwrite")])], steeringIDs: [])
            ], sessionID: session, runID: UUID(), durability: .durable)
        }
        #expect(try Data(contentsOf: current) == altered)
        try saved.write(to: current)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == [first])
        try await reopened.close()
    }

    @Test func largeSettledOutputSurvivesRotationPackingAndReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192,
                                                  maxUnreclaimedBytes: 32768)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "large", policy: policy)
        let first = UUID(), run = UUID(), call = ToolCallID(rawValue: "large-result")
        let target = EvidenceReference(namespace: "fixture", id: "large")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let request = ToolMutationAdmissionRequest(sessionID: first, runID: run, callID: call,
                                                    name: "write", argumentsJSON: "{}",
                                                    resources: [.named(target)], idempotencyKey: "large-effect",
                                                    receiptExpectation: expectation)
        _ = try await journal.admit(request)
        let huge = String(repeating: "漢🙂", count: 200_000)
        let receipt = ToolReceipt(operationID: "large-effect", status: .succeeded,
                                  confirmedTargets: [target], revision: "v3")
        try await journal.commitMutation(sessionID: first, runID: run, callID: call,
                                         receipt: receipt, output: .string(huge),
                                         history: [
                                            .user([.text("write large result")]),
                                            .assistant(content: [], toolCalls: [.init(id: call, name: "write", argumentsJSON: "{}", completeness: .complete)]),
                                            .tool(.init(callID: call, content: [.json(.string(huge))], isError: false)),
                                         ], steeringIDs: [])
        for index in 0..<12 {
            let session = UUID()
            _ = try await journal.appendCheckpoint([.checkpoint(history: [.user([.text("rotate \(index)")])], steeringIDs: [])],
                                                   sessionID: session, runID: UUID(), durability: .durable)
        }
        for _ in 0..<16 { if try await journal.requestMaintenance()?.sealedSegments == 0 { break } }
        #expect(try await journal.mutationStatus(identity: "large-effect")?.replayOutput == .string(huge))
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.latestCheckpoint(sessionID: first)?.history.last ==
                .tool(.init(callID: call, content: [.json(.string(huge))], isError: false)))
        let retry = ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "retry"),
                                                 name: "write", argumentsJSON: "{}",
                                                 resources: [.named(target)], idempotencyKey: "large-effect",
                                                 receiptExpectation: expectation)
        guard case .settled(let replayed, let output) = try await reopened.admit(retry) else {
            Issue.record("large output should replay"); return
        }
        #expect(replayed == receipt)
        #expect(output == .string(huge))
        try await reopened.close()
    }

    @Test(arguments: [11, 29, 47])
    func referenceStateMatchesAcrossDifferentMaintenanceAndRestartPoints(_ seed: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192,
                                                  maxUnreclaimedBytes: 65536)
        var journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "model-\(seed)", policy: policy)
        let sessions = (0..<3).map { _ in UUID() }
        var expected: [UUID: [ModelMessage]] = [:]
        var settled: [String: (ToolReceipt, JSONValue)] = [:]
        var pending: Set<String> = []
        var generator = UInt64(seed)
        for turn in 0..<24 {
            generator = generator &* 6_364_136_223_846_793_005 &+ 1
            let id = sessions[Int(generator % UInt64(sessions.count))]
            let message = ModelMessage.user([.text("seed \(seed) turn \(turn)")])
            expected[id, default: []].append(message)
            _ = try await journal.appendCheckpoint([.checkpoint(history: expected[id]!, steeringIDs: [])],
                                                   sessionID: id, runID: UUID(), durability: .durable)
            let mutationSession = UUID(), run = UUID(), call = ToolCallID(rawValue: "call-\(turn)")
            let identity = "model-\(seed)-operation-\(turn)"
            let target = EvidenceReference(namespace: "fixture", id: "item-\(turn)")
            let request = ToolMutationAdmissionRequest(sessionID: mutationSession, runID: run,
                                                        callID: call, name: "write", argumentsJSON: "{}",
                                                        resources: [.named(target)], idempotencyKey: identity,
                                                        receiptExpectation: try .init(targets: [target], revision: .present))
            _ = try await journal.admit(request)
            if turn.isMultiple(of: 3) {
                let receipt = ToolReceipt(operationID: identity, status: .succeeded,
                                          confirmedTargets: [target], revision: "v1")
                let output = JSONValue.string("done-\(turn)")
                try await journal.commitMutation(sessionID: mutationSession, runID: run, callID: call,
                                                 receipt: receipt, output: output,
                                                 history: [.user([.text("work")]),
                                                           .assistant(content: [], toolCalls: [.init(id: call, name: "write", argumentsJSON: "{}", completeness: .complete)]),
                                                           .tool(.init(callID: call, content: [.json(output)], isError: false))],
                                                 steeringIDs: [])
                settled[identity] = (receipt, output)
            } else {
                let state = try await journal.recoverPendingMutations(sessionID: mutationSession)
                if turn % 3 == 1 {
                    try await journal.abortMutation(try #require(state.first),
                                                    confirmedNoEffect: AgentNoEffectConfirmation(basis: "fixture rejected \(turn)"))
                } else { pending.insert(identity) }
            }
            if turn.isMultiple(of: 5) { _ = try? await journal.requestMaintenance() }
            if turn.isMultiple(of: 7) {
                try await journal.close()
                journal = try AgentIncrementalJournal.open(at: directory, policy: policy)
            }
        }
        for id in sessions {
            #expect(try await journal.latestCheckpoint(sessionID: id)?.history == expected[id])
        }
        for (identity, outcome) in settled {
            let status = try #require(try await journal.mutationStatus(identity: identity))
            #expect(status.state == .settled)
            #expect(status.receipt == outcome.0)
            #expect(status.replayOutput == outcome.1)
        }
        for identity in pending {
            #expect(try await journal.mutationStatus(identity: identity)?.state == .needsReconciliation)
        }
        try await journal.close()
    }

    private func launch(_ mode: String, directory: URL) throws -> Process {
        let process = Process()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var search = root.appendingPathComponent(".build/out/Products/Debug")
        var binary: URL?
        for candidate in [search.appendingPathComponent("JournalTestProcess"),
                          root.appendingPathComponent(".build/debug/JournalTestProcess")] {
            if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }
        }
        if binary == nil, let testBundle = ProcessInfo.processInfo.arguments.first(where: { $0.hasSuffix(".xctest") }) {
            search = URL(fileURLWithPath: testBundle).deletingLastPathComponent()
        }
        for _ in 0..<6 where binary == nil {
            let candidate = search.appendingPathComponent("JournalTestProcess")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { binary = candidate; break }
            search.deleteLastPathComponent()
        }
        process.executableURL = try #require(binary)
        process.arguments = [mode, directory.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        return process
    }
}

private final class JournalFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var selected: JournalFileFaultStage?
    func arm(_ stage: JournalFileFaultStage) {
        lock.lock(); selected = stage; lock.unlock()
    }
    func check(_ stage: JournalFileFaultStage) throws {
        lock.lock()
        let selected = self.selected
        if selected == stage { self.selected = nil }
        lock.unlock()
        if selected == stage { throw AgentJournalError.persistenceUnavailable("injected \(stage)") }
    }
}

private final class JournalMaintenancePause: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entered = false
    private var used = false
    var didEnter: Bool {
        lock.lock(); defer { lock.unlock() }
        return entered
    }
    func waitOnce() {
        lock.lock()
        if used { lock.unlock(); return }
        used = true
        entered = true
        lock.unlock()
        gate.wait()
    }
    func waitUntilEntered() async {
        while !didEnter { try? await Task.sleep(for: .milliseconds(1)) }
    }
    func release() { gate.signal() }
}

private actor FixtureModelProbe {
    private(set) var calls = 0
    func record() { calls += 1 }
}

private struct FixtureModel: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "journal-fixture", capabilities: [.multiTurn])
    let probe: FixtureModelProbe
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            await probe.record()
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info))
            try emit(.responseCompleted(.init(info: info, content: [.text("unused")], stopReason: .endTurn)))
        }
    }
}
