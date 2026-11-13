@testable import AgentCore
@testable import AgentJournalFileStore
import AgentModels
import Foundation

struct SegmentedFileBackendHarness: JournalBackendHarness {
    let name = "segmented-file"

    private func policy(small: Bool) throws -> JournalMaintenancePolicy {
        if small {
            return try JournalMaintenancePolicy(
                segmentBytes: 1024,
                maxWorkBytes: 8192,
                maxUnreclaimedBytes: 32768,
                maxSegmentBatches: 2
            )
        }
        return .default
    }

    func create(
        at directory: URL,
        operationDomain: String,
        smallMaintenanceSegments: Bool,
        capabilities: JournalContractCapabilities,
        fault: (@Sendable (JournalContractFaultStage) throws -> Void)?
    ) throws -> AgentJournal {
        let maintenancePolicy = try policy(small: smallMaintenanceSegments)
        if let fault {
            return try AgentIncrementalJournal.createForTesting(
                at: directory,
                operationDomain: operationDomain,
                policy: maintenancePolicy,
                supportsAdmissionRejections: capabilities.supportsAdmissionRejections,
                supportsAuthorizationAudit: capabilities.supportsAuthorizationAudit,
                supportsConfirmedNoEffect: capabilities.supportsConfirmedNoEffect,
                supportsPerCallFollowUps: capabilities.supportsPerCallFollowUps,
                supportsRunRecords: capabilities.supportsRunRecords,
                supportsImageContent: capabilities.supportsImageContent,
                supportsNativeContext: capabilities.supportsNativeContext,
                supportsContextHandoff: capabilities.supportsContextHandoff,
                supportsIncompleteContextHandoff: capabilities.supportsIncompleteContextHandoff,
                fault: { stage in
                    switch stage {
                    case .beforeCurrentReplace:
                        try fault(.beforeCommit)
                    case .afterCurrentReplace:
                        try fault(.afterCommitBeforeAck)
                    case .afterMaintenanceSnapshot:
                        try fault(.duringMaintenanceSnapshot)
                    case .beforeSessionRead:
                        try fault(.beforeSessionRead)
                    default:
                        break
                    }
                }
            )
        }
        if capabilities.supportsIncompleteContextHandoff {
            return try AgentIncrementalJournal.createForIncompleteContextHandoff(
                at: directory,
                operationDomain: operationDomain,
                policy: maintenancePolicy
            )
        }
        return try AgentIncrementalJournal.create(
            at: directory,
            operationDomain: operationDomain,
            policy: maintenancePolicy,
            supportsAdmissionRejections: capabilities.supportsAdmissionRejections,
            supportsAuthorizationAudit: capabilities.supportsAuthorizationAudit,
            supportsConfirmedNoEffect: capabilities.supportsConfirmedNoEffect,
            supportsPerCallFollowUps: capabilities.supportsPerCallFollowUps,
            supportsRunRecords: capabilities.supportsRunRecords,
            supportsImageContent: capabilities.supportsImageContent,
            supportsNativeContext: capabilities.supportsNativeContext,
            supportsContextHandoff: capabilities.supportsContextHandoff,
            supportsFileContent: capabilities.supportsFileContent
        )
    }

    func createAsync(
        at directory: URL,
        operationDomain: String,
        capabilities: JournalContractCapabilities,
        deadline: ContinuousClock.Instant?
    ) async throws -> AgentJournal {
        if capabilities.supportsIncompleteContextHandoff {
            return try await AgentIncrementalJournal.createForIncompleteContextHandoffAsync(
                at: directory,
                operationDomain: operationDomain,
                deadline: deadline
            )
        }
        return try await AgentIncrementalJournal.createAsync(
            at: directory,
            operationDomain: operationDomain,
            supportsAdmissionRejections: capabilities.supportsAdmissionRejections,
            supportsAuthorizationAudit: capabilities.supportsAuthorizationAudit,
            supportsConfirmedNoEffect: capabilities.supportsConfirmedNoEffect,
            supportsPerCallFollowUps: capabilities.supportsPerCallFollowUps,
            supportsRunRecords: capabilities.supportsRunRecords,
            supportsImageContent: capabilities.supportsImageContent,
            supportsNativeContext: capabilities.supportsNativeContext,
            supportsContextHandoff: capabilities.supportsContextHandoff,
            supportsFileContent: capabilities.supportsFileContent,
            deadline: deadline
        )
    }

    func open(at directory: URL, smallMaintenanceSegments: Bool) throws -> AgentJournal {
        try AgentIncrementalJournal.open(at: directory, policy: policy(small: smallMaintenanceSegments))
    }

    func upgradeForIncompleteContextHandoff(at directory: URL) throws -> AgentJournal {
        try AgentIncrementalJournal.upgradeForIncompleteContextHandoff(at: directory)
    }

    func openAsync(
        at directory: URL,
        writerLockWait: JournalWriterLockWait,
        deadline: ContinuousClock.Instant?
    ) async throws -> AgentJournal {
        try await AgentIncrementalJournal.openAsync(
            at: directory,
            writerLockWait: writerLockWait,
            deadline: deadline
        )
    }

    func corruptCommittedPayload(at directory: URL) throws {
        let segmentDirectory = directory.appendingPathComponent("segments")
        let files = try FileManager.default.contentsOfDirectory(
            at: segmentDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "seg" }
        guard let segment = try files.first(where: { try Data(contentsOf: $0).count > 0 }) else {
            throw AgentJournalError.persistenceUnavailable("missing non-empty segment")
        }
        var data = try Data(contentsOf: segment)
        data[data.count - 1] ^= 0xff
        try data.write(to: segment)
    }

    func writeUnsupportedSchemaVersion(at directory: URL) throws {
        let format = directory.appendingPathComponent("format.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: format)) as? [String: Any] ?? [:]
        object["schema"] = 999
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: format)
    }

    func corruptStoredImagePayload(at directory: URL) throws {
        let imagesRoot = directory.appendingPathComponent("images")
        let files = (FileManager.default.enumerator(at: imagesRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath }) ?? []
        guard let imageFile = files.first else {
            throw AgentJournalError.persistenceUnavailable("missing image file")
        }
        var bytes = try Data(contentsOf: imageFile)
        bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: imageFile)
    }
}
