@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

@Suite struct JournalCommitAndRecoveryContractTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-contract-\(label)-\(UUID())")
    }

    @Test(arguments: JournalContractBackends.all)
    func multiSessionCheckpointsMessagePagingAndUnicodeIdentitySurviveMaintenanceAndReopen(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("checkpoints")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "commit-recovery",
            smallMaintenanceSegments: true
        )
        let primary = UUID(), secondary = UUID()
        var primaryHistory: [ModelMessage] = []
        var secondaryHistory: [ModelMessage] = []

        for index in 0..<18 {
            if index.isMultiple(of: 3) {
                secondaryHistory.append(.user([.text("secondary-\(index)-日本語-🎉")]))
                _ = try await journal.appendCheckpoint(
                    [.checkpoint(history: secondaryHistory, steeringIDs: [])],
                    sessionID: secondary,
                    runID: UUID(),
                    durability: .durable
                )
            } else {
                primaryHistory.append(.user([.text("primary-\(index)-中文-" + String(repeating: "z", count: 80))]))
                _ = try await journal.appendCheckpoint(
                    [.checkpoint(history: primaryHistory, steeringIDs: [])],
                    sessionID: primary,
                    runID: UUID(),
                    durability: .durable
                )
            }
        }

        let initialIDs = try await journal.readMessages(sessionID: primary, after: 0, limit: 100).map(\.id)
        #expect(initialIDs.count == 12)
        let secondPage = try await journal.readMessages(sessionID: primary, after: 5, limit: 4)
        #expect(secondPage.map(\.id) == Array(initialIDs[5..<9]))
        #expect(secondPage.map(\.message) == Array(primaryHistory[5..<9]))

        for _ in 0..<16 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        #expect(try await journal.latestCheckpoint(sessionID: primary)?.history == primaryHistory)
        #expect(try await journal.latestCheckpoint(sessionID: secondary)?.history == secondaryHistory)
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        let reopenedPrimary = try await reopened.readMessages(sessionID: primary, after: 0, limit: 100)
        #expect(reopenedPrimary.map(\.id) == initialIDs)
        #expect(reopenedPrimary.map(\.message) == primaryHistory)
        #expect(try await reopened.readMessages(sessionID: secondary, after: 0, limit: 100).map(\.message) == secondaryHistory)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func domainLabelDoesNotJoinIndependentStores(_ backend: any JournalBackendHarness) async throws {
        let parent = tempDir("domains")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let first = try backend.create(at: parent.appendingPathComponent("a"), operationDomain: "same-label")
        let second = try backend.create(at: parent.appendingPathComponent("b"), operationDomain: "same-label")
        let identityA = try #require(await first.storeIdentity())
        let identityB = try #require(await second.storeIdentity())
        #expect(identityA.storeID != identityB.storeID)
        #expect(identityA.operationDomain == identityB.operationDomain)

        let target = EvidenceReference(namespace: "fixture", id: "shared-label")
        let session = UUID()
        for journal in [first, second] {
            let request = ToolMutationAdmissionRequest(
                sessionID: session,
                runID: UUID(),
                callID: .init(rawValue: "call"),
                name: "write",
                argumentsJSON: "{}",
                resources: [.named(target)],
                idempotencyKey: "identity",
                receiptExpectation: try .init(targets: [target], revision: .present)
            )
            guard case .admitted = try await journal.admit(request) else {
                Issue.record("each store must admit independently")
                return
            }
        }
        try await first.close()
        try await second.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func preExistingPlainFileIsNeitherOpenedNorOverwritten(_ backend: any JournalBackendHarness) throws {
        let url = tempDir("plain-file")
        let existing = Data("SWIFTAGENT-JOURNAL-1".utf8)
        try existing.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) { _ = try backend.open(at: url) }
        #expect(throws: (any Error).self) { _ = try backend.create(at: url, operationDomain: "one") }
        #expect(try Data(contentsOf: url) == existing)
    }

    @Test(arguments: JournalContractBackends.all)
    func asyncOpenAndCreateEnforceDeadlinesAndNeverCreateMissingStores(
        _ backend: any JournalBackendHarness
    ) async throws {
        let missing = tempDir("missing")
        defer { try? FileManager.default.removeItem(at: missing) }

        await #expect(throws: (any Error).self) {
            _ = try await backend.openAsync(at: missing, writerLockWait: .failFast, deadline: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        let expired = ContinuousClock.now - .milliseconds(10)
        await #expect(throws: AgentJournalError.deadlineExceeded) {
            _ = try await backend.createAsync(
                at: missing,
                operationDomain: "expired",
                capabilities: .init(),
                deadline: expired
            )
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test(arguments: JournalContractBackends.all)
    func pairedToolSettlementAndOutOfOrderToolResultsPreserveStableMessageIDs(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("stable-ids")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "out-of-order",
            smallMaintenanceSegments: true
        )
        let session = UUID(), run = UUID()
        let callA = ToolCall(id: .init(rawValue: "A"), name: "read", argumentsJSON: "{}", completeness: .complete)
        let callB = ToolCall(id: .init(rawValue: "B"), name: "write", argumentsJSON: "{}", completeness: .complete)
        let target = EvidenceReference(namespace: "test", id: "file")

        _ = try await journal.admit(.init(
            sessionID: session,
            runID: run,
            callID: callB.id,
            name: callB.name,
            argumentsJSON: callB.argumentsJSON,
            resources: [.named(target)],
            idempotencyKey: "effect-B",
            receiptExpectation: try .init(targets: [target], revision: .present)
        ))
        let input = ModelMessage.user([.text("both")])
        let resultA = ModelMessage.tool(.init(callID: callA.id, content: [.text("read")], isError: false))
        let resultB = ModelMessage.tool(.init(callID: callB.id, content: [.text("write")], isError: false))
        let partial: [ModelMessage] = [input, .assistant(content: [], toolCalls: [callB]), resultB]
        try await journal.commitMutation(
            sessionID: session,
            runID: run,
            callID: callB.id,
            receipt: .init(operationID: "effect-B", status: .succeeded, confirmedTargets: [target], revision: "1"),
            output: .string("write"),
            history: partial,
            steeringIDs: []
        )
        let settledMessageID = try #require(try await journal.readMessages(sessionID: session, after: 2, limit: 1).first?.id)

        let complete: [ModelMessage] = [input, .assistant(content: [], toolCalls: [callA, callB]), resultA, resultB]
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: complete, steeringIDs: [])],
            sessionID: session,
            runID: run,
            durability: .durable
        )
        for _ in 0..<8 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        let restored = try await reopened.readMessages(sessionID: session, after: 0, limit: 10)
        #expect(restored.map(\.message) == complete)
        #expect(restored.last?.id == settledMessageID)
        #expect(try await reopened.mutationStatus(identity: "effect-B")?.state == .settled)
        try await reopened.close()
    }
}
