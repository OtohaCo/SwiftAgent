import Foundation

package actor ToolResourceCoordinator {
    private struct Request {
        let resources: Set<ToolResource>
        let mutation: Bool
        let exclusive: Bool

        func conflicts(with other: Request) -> Bool {
            if mutation && other.mutation { return true }
            guard exclusive || other.exclusive else { return false }
            return resources.contains(.global) || other.resources.contains(.global)
                || !resources.isDisjoint(with: other.resources)
        }
    }

    private struct Waiter {
        let id: UUID
        let request: Request
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var active: [UUID: Request] = [:]
    private var waiters: [Waiter] = []
    private var waiterCountObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    package init() {}

    package var pendingWaiterCount: Int { waiters.count }

    package func waitUntilPendingWaiterCountEquals(_ expected: Int) async {
        if waiters.count == expected { return }
        await withCheckedContinuation { continuation in
            if waiters.count == expected {
                continuation.resume()
            } else {
                waiterCountObservers.append((expected, continuation))
            }
        }
    }

    package func acquire(resources: [ToolResource], effect: ToolPolicy.Effect,
                         execution: ToolPolicy.Execution) async throws -> UUID {
        try ToolResource.validate(resources)
        try Task.checkCancellation()
        let id = UUID()
        let request = Request(resources: Set(resources), mutation: effect == .mutation,
                              exclusive: execution == .exclusive || effect == .mutation)
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, request: request, continuation: continuation))
                grantEligibleWaiters()
            }
        } onCancel: {
            // A delayed cancellation callback must never release an active lease.
            Task { await self.cancelWaiter(id) }
        }
        do {
            try Task.checkCancellation()
            return lease
        } catch {
            release(lease)
            throw error
        }
    }

    package func release(_ lease: UUID) {
        guard active.removeValue(forKey: lease) != nil else { return }
        grantEligibleWaiters()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
        grantEligibleWaiters()
    }

    private func grantEligibleWaiters() {
        var blocked: [Waiter] = []
        for waiter in waiters {
            // Only disjoint requests may pass an older blocked request.
            if active.values.contains(where: { waiter.request.conflicts(with: $0) })
                || blocked.contains(where: { waiter.request.conflicts(with: $0.request) }) {
                blocked.append(waiter)
            } else {
                active[waiter.id] = waiter.request
                waiter.continuation.resume(returning: waiter.id)
            }
        }
        waiters = blocked
        notifyWaiterCountObservers()
    }

    private func notifyWaiterCountObservers() {
        let count = waiters.count
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for observer in waiterCountObservers {
            if observer.0 == count {
                observer.1.resume()
            } else {
                remaining.append(observer)
            }
        }
        waiterCountObservers = remaining
    }
}
