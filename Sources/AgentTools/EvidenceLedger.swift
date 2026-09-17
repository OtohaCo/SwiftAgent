import AgentModels
import Foundation

/// Trusted observations are scoped by runtime identity, never by model-supplied scope fields.
public actor EvidenceLedger: Equatable {
    public nonisolated static func == (lhs: EvidenceLedger, rhs: EvidenceLedger) -> Bool { lhs === rhs }
    private struct Key: Hashable { let sessionID: UUID; let reference: EvidenceReference }
    private struct Entry { let evidence: Evidence; let runID: UUID }
    private var entries: [Key: Entry] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public func record(_ evidence: [Evidence], sessionID: UUID, runID: UUID, deadline: ContinuousClock.Instant? = nil) throws {
        try checkActive(deadline)
        let instant = try currentTime()
        var references = Set<EvidenceReference>()
        for item in evidence {
            guard item.reference.isValid, item.issuedAt.timeIntervalSince1970.isFinite,
                  item.issuedAt <= instant,
                  item.expiresAt.map({ $0.timeIntervalSince1970.isFinite && $0 > instant && $0 > item.issuedAt }) ?? true,
                  (try? JSONEncoder().encode(item.metadata)) != nil else {
                throw EvidenceError.invalidEvidence(item.reference)
            }
            guard references.insert(item.reference).inserted else { throw EvidenceError.duplicateEvidence(item.reference) }
            if let current = entries[Key(sessionID: sessionID, reference: item.reference)], current.evidence.issuedAt > item.issuedAt {
                throw EvidenceError.staleEvidence(item.reference)
            }
        }
        try checkActive(deadline)
        for item in evidence { entries[Key(sessionID: sessionID, reference: item.reference)] = Entry(evidence: item, runID: runID) }
    }

    public func validate(_ requirements: [EvidenceRequirement], sessionID: UUID, runID: UUID, deadline: ContinuousClock.Instant? = nil) throws {
        _ = try resolve(requirements, sessionID: sessionID, runID: runID, deadline: deadline)
    }

    /// Returns a validated snapshot in requirement order, or throws without returning a partial batch.
    public func resolve(_ requirements: [EvidenceRequirement], sessionID: UUID, runID: UUID, deadline: ContinuousClock.Instant? = nil) throws -> [Evidence] {
        try checkActive(deadline)
        try Self.checkRequirements(requirements)
        let instant = try currentTime()
        var resolved: [Evidence] = []
        for requirement in requirements {
            guard let entry = entries[Key(sessionID: sessionID, reference: requirement.reference)],
                  requirement.scope == .sameSession || entry.runID == runID,
                  entry.evidence.issuedAt <= instant,
                  entry.evidence.expiresAt.map({ $0 > instant }) ?? true,
                  requirement.metadata.allSatisfy({ key, value in
                      guard let observed = ToolSchemaValidator.exactValue(entry.evidence.metadata, key) else { return false }
                      return ToolSchemaValidator.jsonEqual(observed, value)
                  }) else {
                throw EvidenceError.unavailable(requirement.reference)
            }
            resolved.append(entry.evidence)
        }
        try checkActive(deadline)
        return resolved
    }

    package nonisolated static func checkRequirements(_ requirements: [EvidenceRequirement]) throws {
        guard !requirements.isEmpty else { throw EvidenceError.emptyRequirements }
        for requirement in requirements {
            guard requirement.reference.isValid, (try? JSONEncoder().encode(requirement.metadata)) != nil else {
                throw EvidenceError.invalidRequirement(requirement.reference)
            }
        }
    }

    private func checkActive(_ deadline: ContinuousClock.Instant?) throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now >= deadline { throw EvidenceError.deadlineExceeded }
    }

    private func currentTime() throws -> Date {
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite else { throw EvidenceError.invalidClock }
        return instant
    }
}

public enum EvidenceError: Error, Equatable, Sendable {
    case unavailable(EvidenceReference)
    case invalidEvidence(EvidenceReference)
    case duplicateEvidence(EvidenceReference)
    case staleEvidence(EvidenceReference)
    case invalidRequirement(EvidenceReference)
    case emptyRequirements
    case invalidClock
    case deadlineExceeded
}
