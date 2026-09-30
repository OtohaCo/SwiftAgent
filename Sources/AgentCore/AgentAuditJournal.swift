import AgentModels
import AgentTools
import Foundation

extension AgentJournal {
    package func validateAuditProposalReference(_ proposalID: UUID?, sessionID: UUID) throws {
        guard let proposalID else { return }
        let page = try auditRecords(matching: .init(proposalID: proposalID), limit: 1)
        guard let record = page.records.first, record.links.sessionID == sessionID,
              case .proposal = record.fact else { throw AgentAuthorizationError.invalidProposalReference }
    }

    package func auditDigest(_ bytes: Data) throws -> String {
        guard let store, supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
        return store.auditDigest(bytes)
    }

    package func makeAuditRecords(_ drafts: [JournalAuditDraft], view: any JournalStoreView,
                                 journalSequence: UInt64) throws -> [AuditRecord] {
        guard !drafts.isEmpty else { return [] }
        guard let store, supportsAuthorizationAudit, drafts.count <= 64 else { throw AgentAuthorizationError.auditUnavailable }
        let first = try view.auditHighWater() + 1
        return try drafts.enumerated().map { offset, draft in
            guard draft.links.storeID == store.storeID, draft.links.operationDomain == store.operationDomain else {
                throw AgentJournalError.invalidRecord
            }
            let id = UUID(), sequence = first + UInt64(offset), journal = journalSequence + UInt64(offset)
            let unsigned = AuditRecord(auditRecordID: id, sequence: sequence, journalRecordSequence: journal,
                sdkObservedAt: draft.observedAt, links: draft.links, fact: draft.fact, digest: "")
            let record = AuditRecord(auditRecordID: id, sequence: sequence, journalRecordSequence: journal,
                sdkObservedAt: draft.observedAt, links: draft.links, fact: draft.fact,
                digest: store.auditDigest(try unsigned.unsignedBytes()))
            try record.validate()
            return record
        }
    }

    package func appendAudit(_ drafts: [JournalAuditDraft], admitsNewWork: Bool = false,
                             backlog: AuditBacklogPolicy? = nil) throws {
        guard !closing else { throw AgentJournalError.storeClosed }
        guard let store, supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
        try writeStore(store) { view in
            try checkAuditBacklog(backlog, view: view)
            let records = try makeAuditRecords(drafts, view: view, journalSequence: view.nextRecordSequence())
            try view.publishAudit(.init(records: records, admitsNewWork: admitsNewWork))
        }
        scheduleMaintenanceIfNeeded()
    }

    package func checkAuditAvailability(backlog: AuditBacklogPolicy?) throws {
        guard !closing else { throw AgentJournalError.storeClosed }
        guard let store, supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
        try store.read { view in
            let highWater = try view.auditHighWater()
            // Bounded check of the latest published typed payload/index, without a history scan.
            if highWater > 0 { _ = try view.auditRecord(sequence: highWater) }
            try checkAuditBacklog(backlog, view: view)
        }
    }

    func checkAuditBacklog(_ backlog: AuditBacklogPolicy?, view: any JournalStoreView) throws {
        guard let backlog else { return }
        let highWater = try view.auditHighWater()
        let acknowledged = try view.auditExportCheckpoint(backlog.exportConfigurationID)?.throughSequence ?? 0
        guard acknowledged <= highWater,
              highWater - acknowledged < backlog.maximumUnacknowledgedRecords else {
            throw AgentAuthorizationError.backlogExceeded
        }
    }

    package func auditMutationSource(identity: String) throws -> JournalStoredMutation? {
        guard let store else { throw AgentAuthorizationError.auditUnavailable }
        return try store.read { try $0.identity(identity) }
    }

    package func commitAuditedCheckpoint(history: [ModelMessage], steeringIDs: [UUID],
                                         sessionID: UUID, runID: UUID, drafts: [JournalAuditDraft]) throws {
        _ = try appendCheckpoint([.checkpoint(history: history, steeringIDs: steeringIDs)],
            sessionID: sessionID, runID: runID, timestamp: Date(), durability: .durable,
            allowMutationSettlement: false, auditDrafts: drafts)
    }

    /// Read-only administration for a trusted Host. Uses a fixed high-water mark and bounded work.
    public func auditRecords(matching query: AuditQuery = .init(), afterExclusiveSequence: UInt64 = 0,
                             limit: Int = 100, cursor: AuditCursor? = nil,
                             includeRestrictedPayload: Bool = false) throws -> AuditPage {
        guard !closing else { throw AgentJournalError.storeClosed }
        guard let store, supportsAuthorizationAudit else { throw AgentAuthorizationError.auditStoreRequired }
        guard (1...100).contains(limit), query.operationID.map({ $0.utf8.count <= 96 * 1024 }) ?? true,
              query.logicalOperationID.map(AuditEncoding.identifier) ?? true else { throw AgentAuthorizationError.invalidQuery }
        let queryDigest = store.auditDigest(try AuditEncoding.encode(query))
        return try store.read { view in
            let current = try view.auditHighWater()
            let highWater: UInt64
            var ordinal: UInt64
            var after: UInt64
            let count = try query.indexKey.map(view.auditGroupCount) ?? current
            func member(_ ordinal: UInt64) throws -> UInt64 {
                if let key = query.indexKey { return try view.auditGroupMember(key, ordinal: ordinal) }
                return ordinal
            }
            if let cursor {
                guard cursor.storeID == store.storeID, cursor.queryDigest == queryDigest,
                      cursor.restricted == includeRestrictedPayload,
                      afterExclusiveSequence == 0 || afterExclusiveSequence == cursor.afterExclusiveSequence,
                      cursor.highWaterSequence <= current,
                      cursor.afterExclusiveSequence <= cursor.highWaterSequence,
                      cursor.nextOrdinal > 0, cursor.nextOrdinal <= count + 1,
                      cursor.digest == store.auditDigest(try cursorBytes(storeID: cursor.storeID, queryDigest: cursor.queryDigest,
                          highWater: cursor.highWaterSequence, after: cursor.afterExclusiveSequence,
                          ordinal: cursor.nextOrdinal, restricted: cursor.restricted)) else {
                    throw AgentAuthorizationError.cursorMismatch
                }
                highWater = cursor.highWaterSequence; ordinal = cursor.nextOrdinal; after = cursor.afterExclusiveSequence
                if ordinal > 1, try member(ordinal - 1) > after { throw AgentAuthorizationError.cursorMismatch }
                if ordinal <= count, try member(ordinal) <= after { throw AgentAuthorizationError.cursorMismatch }
            } else {
                guard afterExclusiveSequence <= current else { throw AgentAuthorizationError.invalidQuery }
                highWater = current; after = afterExclusiveSequence
                var lower: UInt64 = 1, upper = count + 1
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if try member(middle) <= after { lower = middle + 1 } else { upper = middle }
                }
                ordinal = lower
            }
            var records: [AuditRecord] = [], scanned = 0
            while ordinal <= count, records.count < limit, scanned < min(400, limit * 4) {
                let sequence = try member(ordinal)
                if sequence > highWater { break }
                guard sequence > after else { throw AgentJournalError.invalidRecord }
                let record = try view.auditRecord(sequence: sequence)
                guard query.indexKey.map({ record.links.indexKeys.contains($0) }) ?? true else { throw AgentJournalError.invalidRecord }
                if query.matches(record.links) { records.append(includeRestrictedPayload ? record : record.regularView()) }
                after = sequence; ordinal += 1; scanned += 1
            }
            let more = try ordinal <= count && member(ordinal) <= highWater
            let next = try more ? AuditCursor(storeID: store.storeID, queryDigest: queryDigest,
                highWaterSequence: highWater, afterExclusiveSequence: after, nextOrdinal: ordinal,
                restricted: includeRestrictedPayload,
                digest: store.auditDigest(cursorBytes(storeID: store.storeID, queryDigest: queryDigest,
                    highWater: highWater, after: after, ordinal: ordinal, restricted: includeRestrictedPayload))) : nil
            return AuditPage(records: records, highWaterSequence: highWater, nextCursor: next,
                             scannedThroughSequence: more ? after : highWater)
        }
    }

    private func cursorBytes(storeID: UUID, queryDigest: String, highWater: UInt64, after: UInt64,
                             ordinal: UInt64, restricted: Bool) throws -> Data {
        struct Fields: Codable {
            let version: Int; let storeID: UUID; let queryDigest: String; let highWater: UInt64
            let after: UInt64; let ordinal: UInt64; let restricted: Bool
        }
        return try AuditEncoding.encode(Fields(version: 1, storeID: storeID, queryDigest: queryDigest,
            highWater: highWater, after: after, ordinal: ordinal, restricted: restricted))
    }
}
