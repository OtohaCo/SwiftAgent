import Foundation

/// A source of time that a test can substitute for the continuous clock.
package protocol AgentClockSource: Sendable {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

/// The time that run, tool and authorization deadlines are measured against. It is the
/// continuous clock unless a test installs another source for the current task tree,
/// so deadline behaviour can be checked without depending on how busy the machine is.
package enum AgentClock {
    @TaskLocal package static var source: (any AgentClockSource)?

    package static var now: ContinuousClock.Instant { source?.now ?? ContinuousClock.now }

    package static func sleep(until deadline: ContinuousClock.Instant) async throws {
        if let source { try await source.sleep(until: deadline) }
        else { try await ContinuousClock().sleep(until: deadline) }
    }
}
