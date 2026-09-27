import Dispatch

/// Runs actor-isolated file operations on an owned serial queue instead of a
/// cooperative or UI executor. This is available on the package's OS floors.
final class JournalIOExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SwiftAgent.AgentJournal.IO", qos: .utility)

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }
}
