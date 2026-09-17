import AgentTools
import Foundation
import Testing

struct ToolResourceCoordinatorTests {
    @Test func validatesResourcesAndPreservesExactReferenceIdentity() throws {
        let reference = EvidenceReference(namespace: "files", id: "one")
        #expect(throws: ToolResourceError.empty) { try ToolResource.validate([]) }
        #expect(throws: ToolResourceError.duplicate) { try ToolResource.validate([.global, .global]) }
        #expect(throws: ToolResourceError.duplicate) {
            try ToolResource.validate([.named(reference), .named(reference)])
        }
        for invalid in [EvidenceReference(namespace: " \n", id: "one"),
                        EvidenceReference(namespace: "files", id: "\t")] {
            #expect(throws: ToolResourceError.invalidReference(invalid)) {
                try ToolResource.validate([.named(invalid)])
            }
        }
        let exact: [ToolResource] = [
            .named(.init(namespace: "files", id: "\u{00E9}")),
            .named(.init(namespace: "files", id: "e\u{0301}")),
            .named(.init(namespace: "Files", id: "one")), .named(reference), .global,
        ]
        try ToolResource.validate(exact)
        #expect(Set(exact).count == 5)
        #expect(try JSONDecoder().decode([ToolResource].self, from: JSONEncoder().encode(exact)) == exact)
    }

    @Test func sharedReadsOverlapAcrossParallelAndSequential() async throws {
        let coordinator = ToolResourceCoordinator()
        let first = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .parallel)
        let second = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .sequential)
        #expect(first != second)
        await coordinator.release(first)
        await coordinator.release(second)
    }

    @Test func acquireRejectsInvalidResourcesBeforeAdmission() async throws {
        let coordinator = ToolResourceCoordinator()
        let invalid = EvidenceReference(namespace: "files", id: " \n")
        for (resources, error): ([ToolResource], ToolResourceError) in [
            ([], .empty), ([.global, .global], .duplicate), ([.named(invalid)], .invalidReference(invalid)),
        ] {
            await #expect(throws: error) {
                try await coordinator.acquire(resources: resources, effect: .readOnly, execution: .exclusive)
            }
        }
        let lease = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .exclusive)
        await coordinator.release(lease)
    }

    @Test func disjointExclusiveLeasesPreserveByteExactIdentity() async throws {
        let coordinator = ToolResourceCoordinator()
        let first = try await coordinator.acquire(
            resources: [.named(.init(namespace: "files", id: "\u{00E9}"))],
            effect: .readOnly, execution: .exclusive)
        let second = try await coordinator.acquire(
            resources: [.named(.init(namespace: "files", id: "e\u{0301}"))],
            effect: .readOnly, execution: .exclusive)
        #expect(first != second)
        await coordinator.release(first)
        await coordinator.release(second)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func cancellationBeforeAcquireLeavesNoLeaseOrWaiter() async throws {
        let coordinator = ToolResourceCoordinator()
        let gate = ResourceGate()
        let task = Task {
            await gate.hold()
            return try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .exclusive)
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        let lease = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .exclusive)
        let grants = ResourceGrants()
        let waiting = await coordinator.start(resources: [.global], label: "waiting", grants: grants)
        await coordinator.release(UUID())
        #expect(grants.values.isEmpty)
        await coordinator.release(lease)
        let next = try await waiting.value
        await coordinator.release(lease)
        let blocked = await coordinator.start(resources: [.global], execution: .exclusive, label: "blocked", grants: grants)
        #expect(grants.values == ["waiting"])
        await coordinator.release(next)
        let last = try await blocked.value
        await coordinator.release(last)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func conflictingWaitersStayOrderedWhileDisjointReadsProgress() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        let first = try await coordinator.acquire(resources: [a], effect: .readOnly, execution: .parallel)
        let grants = ResourceGrants()
        let writer = await coordinator.start(resources: [a], execution: .exclusive, label: "writer", grants: grants)
        let reader = await coordinator.start(resources: [a], label: "reader", grants: grants)
        let disjoint = await coordinator.start(resources: [b], label: "disjoint", grants: grants)
        let disjointLease = try await disjoint.value
        #expect(grants.values == ["disjoint"])
        await coordinator.release(first)
        let writerLease = try await writer.value
        #expect(grants.values == ["disjoint", "writer"])
        await coordinator.release(writerLease)
        let readerLease = try await reader.value
        #expect(grants.values == ["disjoint", "writer", "reader"])
        await coordinator.release(readerLease)
        await coordinator.release(disjointLease)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func globalConflictsInEitherDirectionAndNamedListsUseAnyOverlap() async throws {
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        for (held, waiting) in [([ToolResource.global], [a]), ([a], [.global]), ([a, b], [b])] {
            let coordinator = ToolResourceCoordinator()
            let first = try await coordinator.acquire(resources: held, effect: .readOnly, execution: .exclusive)
            let grants = ResourceGrants()
            let next = await coordinator.start(resources: waiting, label: "next", grants: grants)
            #expect(grants.values.isEmpty)
            await coordinator.release(first)
            let lease = try await next.value
            #expect(grants.values == ["next"])
            await coordinator.release(lease)
        }
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func disjointMutationsSerializeButDisjointReadCanProceed() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        let c = ToolResource.named(.init(namespace: "files", id: "c"))
        let first = try await coordinator.acquire(resources: [a], effect: .mutation, execution: .exclusive)
        let grants = ResourceGrants()
        let second = await coordinator.start(resources: [b], effect: .mutation, execution: .exclusive,
                                             label: "mutation", grants: grants)
        let read = await coordinator.start(resources: [c], label: "read", grants: grants)
        let readLease = try await read.value
        #expect(grants.values == ["read"])
        await coordinator.release(first)
        let secondLease = try await second.value
        #expect(grants.values == ["read", "mutation"])
        await coordinator.release(secondLease)
        await coordinator.release(readLease)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func cancelledWaiterIsRemovedAndNoLongerBlocksReaders() async throws {
        let coordinator = ToolResourceCoordinator()
        let first = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .parallel)
        let grants = ResourceGrants()
        let writer = await coordinator.start(resources: [.global], execution: .exclusive, label: "writer", grants: grants)
        let reader = await coordinator.start(resources: [.global], label: "reader", grants: grants)
        #expect(grants.values.isEmpty)
        writer.cancel()
        await #expect(throws: CancellationError.self) { try await writer.value }
        let lease = try await reader.value
        #expect(grants.values == ["reader"])
        await coordinator.release(lease)
        await coordinator.release(first)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func cancellingTaskAfterAcquireReturnsDoesNotReleaseActiveLease() async throws {
        let coordinator = ToolResourceCoordinator()
        let grants = ResourceGrants()
        let gate = ResourceGate()
        let holder = await coordinator.start(resources: [.global], execution: .exclusive,
                                             label: "holder", grants: grants, gate: gate)
        await gate.waitUntilEntered()
        holder.cancel()
        let waiting = await coordinator.start(resources: [.global], label: "waiting", grants: grants)
        #expect(grants.values == ["holder"])
        await gate.open()
        let heldLease = try await holder.value
        #expect(grants.values == ["holder"])
        await coordinator.release(heldLease)
        let nextLease = try await waiting.value
        await coordinator.release(nextLease)
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Test func cancellationAtGrantReleasesOnlyTheUnreturnedLease() async throws {
        for cancelFirst in [true, false] {
            let coordinator = ToolResourceCoordinator()
            let first = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .exclusive)
            let grants = ResourceGrants()
            let queued = await coordinator.start(resources: [.global], execution: .exclusive, label: "cancelled", grants: grants)
            await coordinator.cancelAtGrant(queued, releasing: first, cancelFirst: cancelFirst)
            await #expect(throws: CancellationError.self) { try await queued.value }
            let next = try await coordinator.acquire(resources: [.global], effect: .readOnly, execution: .exclusive)
            #expect(grants.values.isEmpty)
            await coordinator.release(next)
        }
    }
}

private final class ResourceGrants: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private actor ResourceGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var held: CheckedContinuation<Void, Never>?

    func hold() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }

    func open() { held?.resume(); held = nil }
}

private extension ToolResourceCoordinator {
    // Immediate execution on this actor reaches acquire's suspension before start returns.
    @available(macOS 26.0, iOS 26.0, *)
    func start(resources: [ToolResource], effect: ToolPolicy.Effect = .readOnly,
               execution: ToolPolicy.Execution = .parallel, label: String,
               grants: ResourceGrants, gate: ResourceGate? = nil) -> Task<UUID, Error> {
        Task.immediate {
            let lease = try await self.acquire(resources: resources, effect: effect, execution: execution)
            grants.append(label)
            if let gate { await gate.hold() }
            return lease
        }
    }

    func cancelAtGrant(_ task: Task<UUID, Error>, releasing lease: UUID, cancelFirst: Bool) {
        if cancelFirst { task.cancel() }
        release(lease)
        if !cancelFirst { task.cancel() }
    }
}
