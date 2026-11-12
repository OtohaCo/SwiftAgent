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

    /// A lease wait with a limit ends at it without leaving a waiter or a lease behind.
    @Test func aLimitedWaitEndsWithoutHoldingOrLeavingALease() async throws {
        let coordinator = ToolResourceCoordinator()
        let held = try await coordinator.acquire(resources: [.global], effect: .mutation, execution: .exclusive)
        await #expect(throws: ToolResourceCoordinator.WaitExpired.self) {
            _ = try await coordinator.acquire(resources: [.global], effect: .mutation, execution: .exclusive,
                                              until: .now.advanced(by: .milliseconds(80)))
        }
        #expect(await coordinator.pendingWaiterCount == 0)
        await #expect(throws: ToolResourceCoordinator.WaitExpired.self) {
            _ = try await coordinator.acquire(resources: [.global], effect: .mutation, execution: .exclusive, until: .now)
        }
        await coordinator.release(held)
        let next = try await coordinator.acquire(resources: [.global], effect: .mutation, execution: .exclusive,
                                                 until: .now.advanced(by: .seconds(5)))
        await coordinator.release(next)
        #expect(await coordinator.pendingWaiterCount == 0)
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

    @Test func conflictingWaitersStayOrderedWhileDisjointReadsProgress() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        let first = try await coordinator.acquire(resources: [a], effect: .readOnly, execution: .parallel)
        let grants = ResourceGrants()
        let writer = await coordinator.start(resources: [a], execution: .exclusive, label: "writer", grants: grants)
        let reader = await coordinator.start(resources: [a], label: "reader", grants: grants)
        let disjoint = await coordinator.start(resources: [b], label: "disjoint", grants: grants,
                                               waitForQueue: false)
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

    /// Mutations conflict only where their resources overlap (or one is global), as any other
    /// exclusive call does. Before, any two mutations on one scheduler waited for each other.
    @Test func mutationsOnDisjointResourcesHoldLeasesAtOnce() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        let c = ToolResource.named(.init(namespace: "files", id: "c"))
        let first = try await coordinator.acquire(resources: [a], effect: .mutation, execution: .exclusive)
        let second = try await coordinator.acquire(resources: [b], effect: .mutation, execution: .exclusive,
                                                   until: .now.advanced(by: .seconds(5)))
        let read = try await coordinator.acquire(resources: [c], effect: .readOnly, execution: .parallel,
                                                 until: .now.advanced(by: .seconds(5)))
        #expect(Set([first, second, read]).count == 3)
        #expect(await coordinator.pendingWaiterCount == 0)
        for lease in [first, second, read] { await coordinator.release(lease) }
    }

    @Test func mutationsSharingAResourceStayInOrder() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        let first = try await coordinator.acquire(resources: [a], effect: .mutation, execution: .exclusive)
        let grants = ResourceGrants()
        // A move touching a and b overlaps the held write on a; a later write on b waits behind it in order.
        let move = await coordinator.start(resources: [a, b], effect: .mutation, execution: .exclusive,
                                           label: "move", grants: grants)
        let later = await coordinator.start(resources: [b], effect: .mutation, execution: .exclusive,
                                            label: "later", grants: grants)
        #expect(grants.values.isEmpty)
        await coordinator.release(first)
        let moveLease = try await move.value
        #expect(grants.values == ["move"])
        await coordinator.release(moveLease)
        let laterLease = try await later.value
        #expect(grants.values == ["move", "later"])
        await coordinator.release(laterLease)
    }

    @Test func aGlobalMutationExcludesEveryCallInBothDirections() async throws {
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let cases: [(held: [ToolResource], heldEffect: ToolPolicy.Effect, waiting: [ToolResource],
                     effect: ToolPolicy.Effect, execution: ToolPolicy.Execution)] = [
            ([.global], .mutation, [a], .mutation, .exclusive),
            ([.global], .mutation, [a], .readOnly, .parallel),
            ([a], .mutation, [.global], .mutation, .exclusive),
            ([a], .readOnly, [.global], .mutation, .exclusive),
            ([.global], .mutation, [.global], .mutation, .exclusive),
        ]
        for item in cases {
            let coordinator = ToolResourceCoordinator()
            let held = try await coordinator.acquire(resources: item.held, effect: item.heldEffect,
                                                     execution: item.heldEffect == .mutation ? .exclusive : .parallel)
            let grants = ResourceGrants()
            let next = await coordinator.start(resources: item.waiting, effect: item.effect, execution: item.execution,
                                               label: "next", grants: grants)
            #expect(grants.values.isEmpty)
            await coordinator.release(held)
            let lease = try await next.value
            #expect(grants.values == ["next"])
            await coordinator.release(lease)
        }
    }

    @Test func aReadAndAMutationOfOneResourceWaitForEachOther() async throws {
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        for readFirst in [true, false] {
            let coordinator = ToolResourceCoordinator()
            let held = readFirst
                ? try await coordinator.acquire(resources: [a], effect: .readOnly, execution: .parallel)
                : try await coordinator.acquire(resources: [a], effect: .mutation, execution: .exclusive)
            let grants = ResourceGrants()
            let next = readFirst
                ? await coordinator.start(resources: [a], effect: .mutation, execution: .exclusive, label: "next", grants: grants)
                : await coordinator.start(resources: [a], effect: .readOnly, execution: .parallel, label: "next", grants: grants)
            #expect(grants.values.isEmpty)
            await coordinator.release(held)
            let lease = try await next.value
            #expect(grants.values == ["next"])
            await coordinator.release(lease)
        }
    }

    @Test func aMutationCancelledWhileWaitingLeavesNoWaiterAndUnblocksLaterCalls() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let held = try await coordinator.acquire(resources: [a], effect: .readOnly, execution: .parallel)
        let grants = ResourceGrants()
        let writer = await coordinator.start(resources: [a], effect: .mutation, execution: .exclusive,
                                             label: "writer", grants: grants)
        // Queued behind the waiting writer: an older conflicting waiter is never overtaken.
        let reader = await coordinator.start(resources: [a], label: "reader", grants: grants)
        #expect(grants.values.isEmpty)
        writer.cancel()
        await #expect(throws: CancellationError.self) { try await writer.value }
        let readerLease = try await reader.value
        #expect(grants.values == ["reader"])
        #expect(await coordinator.pendingWaiterCount == 0)
        await coordinator.release(readerLease)
        await coordinator.release(held)
    }

    /// The lease-wait limit applies to a mutation waiting on its own resource, and not to one on another.
    @Test func aLeaseWaitLimitEndsOnlyAWaitForAnOverlappingResource() async throws {
        let coordinator = ToolResourceCoordinator()
        let a = ToolResource.named(.init(namespace: "files", id: "a"))
        let b = ToolResource.named(.init(namespace: "files", id: "b"))
        let held = try await coordinator.acquire(resources: [a], effect: .mutation, execution: .exclusive)
        await #expect(throws: ToolResourceCoordinator.WaitExpired.self) {
            _ = try await coordinator.acquire(resources: [a], effect: .mutation, execution: .exclusive,
                                              until: .now.advanced(by: .milliseconds(80)))
        }
        #expect(await coordinator.pendingWaiterCount == 0)
        let other = try await coordinator.acquire(resources: [b], effect: .mutation, execution: .exclusive,
                                                  until: .now.advanced(by: .milliseconds(80)))
        await coordinator.release(other)
        await coordinator.release(held)
        #expect(await coordinator.pendingWaiterCount == 0)
    }

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
    func start(resources: [ToolResource], effect: ToolPolicy.Effect = .readOnly,
               execution: ToolPolicy.Execution = .parallel, label: String,
               grants: ResourceGrants, gate: ResourceGate? = nil,
               waitForQueue: Bool = true) async -> Task<UUID, Error> {
        let pendingBeforeStart = pendingWaiterCount
        let task = Task {
            let lease = try await self.acquire(resources: resources, effect: effect, execution: execution)
            grants.append(label)
            if let gate { await gate.hold() }
            return lease
        }
        if gate == nil, waitForQueue {
            await waitUntilPendingWaiterCountEquals(pendingBeforeStart + 1)
        }
        return task
    }

    func cancelAtGrant(_ task: Task<UUID, Error>, releasing lease: UUID, cancelFirst: Bool) {
        if cancelFirst { task.cancel() }
        release(lease)
        if !cancelFirst { task.cancel() }
    }
}
