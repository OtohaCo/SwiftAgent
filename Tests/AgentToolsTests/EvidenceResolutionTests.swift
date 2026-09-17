import AgentTools
import Foundation
import Testing

struct EvidenceResolutionTests {
    @Test func resolvesTrustedMetadataInRequestedOrderWithoutChangingStoredValues() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let ledger = EvidenceLedger(now: { now })
        let session = UUID(), run = UUID()
        let first = Evidence(namespace: "cad.document", id: "a", issuedAt: now, metadata: ["title": .string("Verified drawing")])
        let second = Evidence(namespace: "cad.document", id: "b", issuedAt: now, metadata: ["revision": .string("v2")])
        try await ledger.record([first, second], sessionID: session, runID: run)
        let context = ToolContext(sessionID: session, runID: run, callID: .init(rawValue: "read"), evidenceLedger: ledger)
        var resolved = try await context.resolveEvidence([.init(reference: second.reference), .init(reference: first.reference)])
        #expect(resolved == [second, first])
        resolved.removeAll()
        #expect(try await context.resolveEvidence([.init(reference: first.reference)]) == [first])
    }

    @Test func resolutionRejectsCrossSessionStaleScopeExpiryAndMetadataMismatch() async throws {
        let clock = EvidenceTestClock(Date(timeIntervalSince1970: 100))
        let ledger = EvidenceLedger(now: { clock.now() })
        let session = UUID(), run = UUID()
        let item = Evidence(namespace: "property.listing", id: "a", issuedAt: clock.now(),
                            expiresAt: Date(timeIntervalSince1970: 101), metadata: ["revision": .string("v2")])
        try await ledger.record([item], sessionID: session, runID: run)
        for (s, r, requirement) in [
            (UUID(), run, EvidenceRequirement(reference: item.reference, scope: .sameSession)),
            (session, UUID(), EvidenceRequirement(reference: item.reference)),
            (session, run, EvidenceRequirement(reference: item.reference, metadata: ["revision": .string("v1")])),
        ] {
            let context = ToolContext(sessionID: s, runID: r, callID: .init(rawValue: "read"), evidenceLedger: ledger)
            await #expect(throws: EvidenceError.unavailable(item.reference)) { try await context.resolveEvidence([requirement]) }
        }
        let later = ToolContext(sessionID: session, runID: UUID(), callID: .init(rawValue: "read"), evidenceLedger: ledger)
        #expect(try await later.resolveEvidence([.init(reference: item.reference, scope: .sameSession)]) == [item])
        clock.set(Date(timeIntervalSince1970: 101))
        await #expect(throws: EvidenceError.unavailable(item.reference)) {
            try await later.resolveEvidence([.init(reference: item.reference, scope: .sameSession)])
        }
    }

    @Test func unavailableBatchCancellationAndDeadlineNeverReturnPartialResults() async throws {
        let now = Date()
        let ledger = EvidenceLedger()
        let session = UUID(), run = UUID()
        let item = Evidence(namespace: "resource", id: "a", issuedAt: now)
        let absent = EvidenceReference(namespace: "resource", id: "absent")
        try await ledger.record([item], sessionID: session, runID: run)
        let context = ToolContext(sessionID: session, runID: run, callID: .init(rawValue: "read"), evidenceLedger: ledger)
        await #expect(throws: EvidenceError.unavailable(absent)) {
            try await context.resolveEvidence([.init(reference: item.reference), .init(reference: absent)])
        }
        await #expect(throws: EvidenceError.emptyRequirements) { try await context.resolveEvidence([]) }
        let missing = ToolContext(sessionID: session, runID: run, callID: .init(rawValue: "read"))
        await #expect(throws: ToolInvocationError.evidenceUnavailable) {
            try await missing.resolveEvidence([.init(reference: item.reference)])
        }
        let expired = ToolContext(sessionID: session, runID: run, callID: .init(rawValue: "read"),
                                  deadline: .now.advanced(by: .seconds(-1)), evidenceLedger: ledger)
        await #expect(throws: ToolInvocationError.deadlineExceeded) {
            try await expired.resolveEvidence([.init(reference: item.reference)])
        }
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream {}
            return try await context.resolveEvidence([.init(reference: item.reference)])
        }
        task.cancel()
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
