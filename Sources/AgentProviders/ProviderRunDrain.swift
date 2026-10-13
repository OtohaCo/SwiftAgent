import AgentModels
import Foundation

/// Synchronous registration closes the cancellation/producer-start race. A Host
/// credential callback which ignores cancellation remains physical work until it returns.
final class ProviderRunDrain: @unchecked Sendable {
    struct Key: Hashable { let session: UUID; let run: UUID }
    private let lock = NSLock()
    private var active: [Key: Int] = [:]
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    func begin(_ request: ModelRequest) -> Key? {
        guard let session = request.sessionID, let run = request.runID else { return nil }
        let key = Key(session: session, run: run)
        lock.withLock { active[key, default: 0] += 1 }
        return key
    }
    func end(_ key: Key?) {
        guard let key else { return }
        let finished: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard let count = active[key] else { return [] }
            if count > 1 { active[key] = count - 1; return [] }
            active.removeValue(forKey: key)
            return waiters.removeValue(forKey: key) ?? []
        }
        for waiter in finished { waiter.resume() }
    }
    func wait(sessionID: UUID, runID: UUID) async {
        let key = Key(session: sessionID, run: runID)
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                guard active[key] != nil else { return true }
                waiters[key, default: []].append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
