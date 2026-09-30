import AgentCore
import AgentJournalFileStore
import Foundation
import Testing

struct AuditPersistenceTests {
    @Test func auditStoreIsSchemaFiveAndOrdinaryStoresRemainThreeOrFour() async throws {
        for audit in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-format-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "format", supportsAuthorizationAudit: audit)
            let format = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as! [String: Any]
            #expect(format["schema"] as? Int == (audit ? 5 : 3))
            #expect(journal.supportsAuthorizationAudit == audit)
            try await journal.close()
            let reopened = try AgentIncrementalJournal.open(at: directory)
            #expect(reopened.supportsAuthorizationAudit == audit)
            try await reopened.close()
        }
    }

    @Test func typedFactsSurviveMaintenanceAndDoNotCreateConversation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-facts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192, maxUnreclaimedBytes: 32768)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "facts", policy: policy, supportsAuthorizationAudit: true)
        let identity = try #require(await journal.storeIdentity())
        let links = AuditRecordLinks(storeID: identity.storeID, operationDomain: identity.operationDomain,
            sessionID: UUID(), runID: UUID(), invocationID: UUID(), modelCallID: "same-text", proposalID: UUID())
        try await journal.appendAudit([.init(links: links, fact: .disposition(.init(state: .notExecuted, reasonCode: "fixture")))])
        #expect(try await journal.latestCheckpoint(sessionID: links.sessionID) == nil)
        let original = try await journal.auditRecords(includeRestrictedPayload: true)
        #expect(original.records.count == 1)
        for _ in 0..<8 { _ = try await journal.requestMaintenance() }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        #expect(try await reopened.auditRecords(includeRestrictedPayload: true).records == original.records)
        #expect(try await reopened.latestCheckpoint(sessionID: links.sessionID) == nil)
        try await reopened.close()
    }

    @Test func uncertainPublicationMustBeReopenedAndNeverBlindlyRetried() async throws {
        for committed in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-unknown-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = AuditPublicationFault(committed: committed)
            let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "unknown",
                supportsAuthorizationAudit: true, fault: { try fault.check($0) })
            let identity = try #require(await journal.storeIdentity())
            let links = AuditRecordLinks(storeID: identity.storeID, operationDomain: identity.operationDomain,
                sessionID: UUID(), runID: UUID(), invocationID: UUID(), modelCallID: "call", proposalID: UUID())
            fault.arm()
            await #expect(throws: AgentJournalError.commitUnknown) {
                try await journal.appendAudit([.init(links: links, fact: .disposition(.init(state: .notExecuted)))])
            }
            await #expect(throws: AgentJournalError.commitUnknown) { try await journal.auditRecords() }
            try await journal.close()
            let reopened = try AgentIncrementalJournal.open(at: directory)
            #expect(try await reopened.auditRecords().records.count == (committed ? 1 : 0))
            try await reopened.close()
        }
    }
}

private final class AuditPublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let committed: Bool
    init(committed: Bool) { self.committed = committed }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        let eligible: Bool
        if committed { if case .afterCurrentReplace = stage { eligible = true } else { eligible = false } }
        else { if case .afterAppendSync = stage { eligible = true } else { eligible = false } }
        guard eligible else { return }
        let fail = lock.withLock { let fail = armed; armed = false; return fail }
        if fail { throw AgentJournalError.persistenceUnavailable("audit publication fixture") }
    }
}
