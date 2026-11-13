@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct JournalContractCapabilities: Sendable, Equatable {
    var supportsAdmissionRejections: Bool = false
    var supportsAuthorizationAudit: Bool = false
    var supportsConfirmedNoEffect: Bool = false
    var supportsPerCallFollowUps: Bool = false
    var supportsRunRecords: Bool = false
    var supportsImageContent: Bool = false
    var supportsNativeContext: Bool = false
    var supportsContextHandoff: Bool = false
    var supportsFileContent: Bool = false
    var supportsIncompleteContextHandoff: Bool = false
}

enum JournalContractFaultStage: String, Sendable, Equatable, CaseIterable {
    case beforeCommit
    case afterCommitBeforeAck
    case duringMaintenanceSnapshot
    case beforeSessionRead
}

protocol JournalBackendHarness: Sendable, CustomTestStringConvertible {
    var name: String { get }
    func create(
        at directory: URL,
        operationDomain: String,
        smallMaintenanceSegments: Bool,
        capabilities: JournalContractCapabilities,
        fault: (@Sendable (JournalContractFaultStage) throws -> Void)?
    ) throws -> AgentJournal
    func createAsync(
        at directory: URL,
        operationDomain: String,
        capabilities: JournalContractCapabilities,
        deadline: ContinuousClock.Instant?
    ) async throws -> AgentJournal
    func open(at directory: URL, smallMaintenanceSegments: Bool) throws -> AgentJournal
    /// The offline upgrade of a context-handoff store to incomplete-context handoff, on a closed store.
    func upgradeForIncompleteContextHandoff(at directory: URL) throws -> AgentJournal
    func openAsync(
        at directory: URL,
        writerLockWait: JournalWriterLockWait,
        deadline: ContinuousClock.Instant?
    ) async throws -> AgentJournal
    func corruptCommittedPayload(at directory: URL) throws
    func writeUnsupportedSchemaVersion(at directory: URL) throws
    func corruptStoredImagePayload(at directory: URL) throws
}

extension JournalBackendHarness {
    var testDescription: String { name }

    func create(
        at directory: URL,
        operationDomain: String,
        smallMaintenanceSegments: Bool = false,
        capabilities: JournalContractCapabilities = .init(),
        fault: (@Sendable (JournalContractFaultStage) throws -> Void)? = nil
    ) throws -> AgentJournal {
        try create(
            at: directory,
            operationDomain: operationDomain,
            smallMaintenanceSegments: smallMaintenanceSegments,
            capabilities: capabilities,
            fault: fault
        )
    }

    func open(at directory: URL) throws -> AgentJournal {
        try open(at: directory, smallMaintenanceSegments: false)
    }
}

enum JournalContractBackends {
    static let all: [any JournalBackendHarness] = [
        SegmentedFileBackendHarness(),
        SQLiteBackendHarness(),
    ]
}

final class ContractFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armedStage: JournalContractFaultStage?

    func arm(_ stage: JournalContractFaultStage) {
        lock.withLock { armedStage = stage }
    }

    func check(_ stage: JournalContractFaultStage) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard armedStage == stage else { return false }
            armedStage = nil
            return true
        }
        if shouldThrow {
            throw AgentJournalError.persistenceUnavailable("injected \(stage.rawValue)")
        }
    }
}

final class ContractStagePause: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var armed: Bool
    private var entered = false
    private var used = false

    init(armed: Bool = true) { self.armed = armed }

    var didEnter: Bool { lock.withLock { entered } }

    func arm() { lock.withLock { armed = true } }

    func waitOnce() {
        let shouldWait = lock.withLock { () -> Bool in
            guard armed, !used else { return false }
            used = true
            entered = true
            return true
        }
        if shouldWait { gate.wait() }
    }

    func waitUntilEntered() async {
        while !didEnter { try? await Task.sleep(for: .milliseconds(2)) }
    }

    func release() { gate.signal() }
}
