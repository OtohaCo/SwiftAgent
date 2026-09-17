import AgentModels
import AgentTools
import Foundation
import Testing

struct EvidenceLedgerTests {
    @Test func genericEvidenceRoundTripsAndHonorsRunAndSessionScope() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let ledger = EvidenceLedger(now: { now })
        let session = UUID(), run = UUID()
        let evidence = Evidence(namespace: "property.listing", id: "r-1", issuedAt: now,
                                expiresAt: now.addingTimeInterval(10), metadata: ["revision": .string("v1")])
        #expect(try JSONDecoder().decode(Evidence.self, from: JSONEncoder().encode(evidence)) == evidence)
        try await ledger.record([evidence], sessionID: session, runID: run)
        try await ledger.validate([.init(reference: evidence.reference)], sessionID: session, runID: run)
        await #expect(throws: (any Error).self) {
            try await ledger.validate([.init(reference: evidence.reference)], sessionID: session, runID: UUID())
        }
        try await ledger.validate([.init(reference: evidence.reference, scope: .sameSession)], sessionID: session, runID: UUID())
        await #expect(throws: (any Error).self) {
            try await ledger.validate([.init(reference: evidence.reference, scope: .sameSession)], sessionID: UUID(), runID: run)
        }
    }

    @Test func expiryMetadataAndOpaqueIdentityFailClosed() async throws {
        let clock = EvidenceTestClock(Date(timeIntervalSince1970: 100))
        let ledger = EvidenceLedger(now: { clock.now() })
        let session = UUID(), run = UUID()
        let item = Evidence(namespace: "cad.document", id: "\u{e9}", issuedAt: clock.now(),
                            expiresAt: clock.now().addingTimeInterval(1), metadata: ["revision": .string("v2")])
        try await ledger.record([item], sessionID: session, runID: run)
        try await ledger.validate([.init(reference: item.reference, metadata: ["revision": .string("v2")])], sessionID: session, runID: run)
        for requirement in [
            EvidenceRequirement(reference: item.reference, metadata: ["revision": .string("v1")]),
            .init(reference: .init(namespace: "cad.document", id: "e\u{301}")),
        ] {
            await #expect(throws: (any Error).self) { try await ledger.validate([requirement], sessionID: session, runID: run) }
        }
        clock.set(Date(timeIntervalSince1970: 101))
        await #expect(throws: (any Error).self) { try await ledger.validate([.init(reference: item.reference)], sessionID: session, runID: run) }
        await #expect(throws: (any Error).self) { try await ledger.validate([], sessionID: session, runID: run) }
    }

    @Test func invalidBatchCannotPartiallyGrantEvidence() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let good = Evidence(namespace: "resource", id: "good", issuedAt: now)
        let bad = [
            Evidence(namespace: "", id: "bad", issuedAt: now),
            Evidence(namespace: "resource", id: "bad", issuedAt: now.addingTimeInterval(1)),
            Evidence(namespace: "resource", id: "bad", issuedAt: now, expiresAt: now),
            Evidence(namespace: "resource", id: "bad", issuedAt: now, metadata: ["value": .number(.nan)]),
        ]
        for item in bad {
            let ledger = EvidenceLedger(now: { now })
            let session = UUID(), run = UUID()
            await #expect(throws: (any Error).self) { try await ledger.record([good, item], sessionID: session, runID: run) }
            await #expect(throws: (any Error).self) { try await ledger.validate([.init(reference: good.reference)], sessionID: session, runID: run) }
        }
    }

    @Test func duplicateAndOlderObservationsCannotReplaceLatestEvidence() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let ledger = EvidenceLedger(now: { now })
        let session = UUID(), firstRun = UUID(), secondRun = UUID()
        let latest = Evidence(namespace: "resource", id: "1", issuedAt: now, metadata: ["revision": .number(2)])
        let older = Evidence(namespace: "resource", id: "1", issuedAt: now.addingTimeInterval(-1), metadata: ["revision": .number(1)])
        await #expect(throws: (any Error).self) { try await ledger.record([latest, latest], sessionID: session, runID: firstRun) }
        try await ledger.record([latest], sessionID: session, runID: secondRun)
        await #expect(throws: (any Error).self) { try await ledger.record([older], sessionID: session, runID: firstRun) }
        try await ledger.validate([.init(reference: latest.reference, metadata: ["revision": .number(2)])], sessionID: session, runID: secondRun)
        await #expect(throws: (any Error).self) { try await ledger.validate([.init(reference: latest.reference)], sessionID: session, runID: firstRun) }
    }

    @Test func cancelledAndExpiredPublicationCannotGrantEvidence() async throws {
        let now = Date(timeIntervalSince1970: 100)
        let ledger = EvidenceLedger(now: { now })
        let session = UUID(), run = UUID()
        let item = Evidence(namespace: "resource", id: "1", issuedAt: now)
        await #expect(throws: EvidenceError.deadlineExceeded) {
            try await ledger.record([item], sessionID: session, runID: run, deadline: .now.advanced(by: .seconds(-1)))
        }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let task = Task {
            for await _ in gate.stream {}
            try await ledger.record([item], sessionID: session, runID: run)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: EvidenceError.unavailable(item.reference)) {
            try await ledger.validate([.init(reference: item.reference)], sessionID: session, runID: run)
        }
    }

    @Test func metadataUsesExactUnicodeAndNewerEvidenceDoesNotFallBack() async throws {
        let clock = EvidenceTestClock(Date(timeIntervalSince1970: 100))
        let ledger = EvidenceLedger(now: { clock.now() })
        let session = UUID(), run = UUID()
        let old = Evidence(namespace: "resource", id: "1", issuedAt: clock.now(), metadata: ["revision": .string("\u{e9}")])
        try await ledger.record([old], sessionID: session, runID: run)
        await #expect(throws: EvidenceError.self) {
            try await ledger.validate([.init(reference: old.reference, metadata: ["revision": .string("e\u{301}")])], sessionID: session, runID: run)
        }
        clock.set(Date(timeIntervalSince1970: 101))
        let fresh = Evidence(namespace: "resource", id: "1", issuedAt: clock.now(), expiresAt: Date(timeIntervalSince1970: 102), metadata: [:])
        try await ledger.record([fresh], sessionID: session, runID: run)
        await #expect(throws: EvidenceError.self) {
            try await ledger.validate([.init(reference: old.reference, metadata: old.metadata)], sessionID: session, runID: run)
        }
        clock.set(Date(timeIntervalSince1970: 102))
        await #expect(throws: EvidenceError.self) {
            try await ledger.validate([.init(reference: old.reference)], sessionID: session, runID: run)
        }
    }

    @Test func publicEvidenceValuesKeepOpaqueUnicodeDistinct() {
        let date = Date(timeIntervalSince1970: 100)
        let a = Evidence(namespace: "resource", id: "\u{e9}", issuedAt: date)
        let b = Evidence(namespace: "resource", id: "e\u{301}", issuedAt: date)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
        let x = EvidenceRequirement(reference: a.reference, metadata: ["revision": .string("\u{e9}")])
        let y = EvidenceRequirement(reference: a.reference, metadata: ["revision": .string("e\u{301}")])
        #expect(x != y)
        #expect(Set([x, y]).count == 2)
    }

    @Test func equalTimestampUsesLastPublishedObservationAndInvalidClockFailsClosed() async throws {
        let clock = EvidenceTestClock(Date(timeIntervalSince1970: 100))
        let ledger = EvidenceLedger(now: { clock.now() })
        let session = UUID(), a = UUID(), b = UUID()
        let first = Evidence(namespace: "resource", id: "1", issuedAt: clock.now(), metadata: ["revision": .number(1)])
        let last = Evidence(namespace: "resource", id: "1", issuedAt: clock.now(), metadata: ["revision": .number(2)])
        try await ledger.record([first], sessionID: session, runID: a)
        try await ledger.record([last], sessionID: session, runID: b)
        try await ledger.validate([.init(reference: last.reference, metadata: last.metadata)], sessionID: session, runID: b)
        await #expect(throws: EvidenceError.unavailable(first.reference)) {
            try await ledger.validate([.init(reference: first.reference)], sessionID: session, runID: a)
        }
        clock.set(Date(timeIntervalSince1970: .nan))
        await #expect(throws: EvidenceError.invalidClock) { try await ledger.record([last], sessionID: session, runID: b) }
        await #expect(throws: EvidenceError.invalidClock) { try await ledger.validate([.init(reference: last.reference)], sessionID: session, runID: b) }
    }
}

// All mutable clock access is protected by the lock; production code uses actor isolation.
final class EvidenceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func set(_ date: Date) { lock.lock(); defer { lock.unlock() }; self.date = date }
}
