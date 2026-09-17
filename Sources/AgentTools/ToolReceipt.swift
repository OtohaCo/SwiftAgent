import Foundation

/// Confirmation supplied by a trusted executor, not decoded from model-facing
/// output. A missing or mismatched receipt is not success.
public struct ToolReceipt: Codable, Equatable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case succeeded, failed, indeterminate }
    public enum Failure: String, Codable, Sendable { case rejected, conflict, unavailable, unknown }

    public let operationID: String
    public let status: Status
    public let confirmedTargets: [EvidenceReference]
    public let revision: String?
    public let failure: Failure?

    public init(operationID: String, status: Status, confirmedTargets: [EvidenceReference],
                revision: String? = nil, failure: Failure? = nil) {
        self.operationID = operationID
        self.status = status
        self.confirmedTargets = confirmedTargets
        self.revision = revision
        self.failure = failure
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operationID.utf8.elementsEqual(rhs.operationID.utf8)
            && lhs.status == rhs.status && lhs.confirmedTargets == rhs.confirmedTargets && lhs.failure == rhs.failure
            && lhs.revision.map { Array($0.utf8) } == rhs.revision.map { Array($0.utf8) }
    }
}

public struct ToolReceiptExpectation: Codable, Equatable, Hashable, Sendable {
    public enum Revision: Codable, Equatable, Hashable, Sendable {
        case optional
        case present
        case exact(String)
        case changed(from: String)
    }

    public let targets: [EvidenceReference]
    public let revision: Revision

    public init(targets: [EvidenceReference], revision: Revision = .optional) throws {
        guard !targets.isEmpty, targets.allSatisfy(\.isValid), Set(targets).count == targets.count else {
            throw ToolReceiptError.invalidExpectation
        }
        switch revision {
        case .exact(let value), .changed(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolReceiptError.invalidExpectation }
        case .optional, .present: break
        }
        self.targets = targets
        self.revision = revision
    }
}

public enum ToolReceiptValidator {
    public static func validate(_ receipt: ToolReceipt?, operationID: String, expectation: ToolReceiptExpectation) throws {
        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolReceiptError.invalidOperationID }
        guard let receipt else { throw ToolReceiptError.missing }
        guard !receipt.operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolReceiptError.invalidOperationID }
        guard receipt.operationID.utf8.elementsEqual(operationID.utf8) else { throw ToolReceiptError.operationMismatch }
        guard receipt.status == .succeeded else { throw ToolReceiptError.unsuccessful(receipt.status, receipt.failure) }
        guard receipt.failure == nil else { throw ToolReceiptError.inconsistentStatus }
        guard !receipt.confirmedTargets.isEmpty, receipt.confirmedTargets.allSatisfy(\.isValid),
              Set(receipt.confirmedTargets).count == receipt.confirmedTargets.count else { throw ToolReceiptError.invalidTargets }
        guard Set(receipt.confirmedTargets) == Set(expectation.targets) else { throw ToolReceiptError.targetsMismatch }
        if let revision = receipt.revision, revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolReceiptError.invalidRevision
        }
        switch expectation.revision {
        case .optional: break
        case .present:
            guard receipt.revision != nil else { throw ToolReceiptError.revisionMismatch }
        case .exact(let expected):
            guard let revision = receipt.revision, revision.utf8.elementsEqual(expected.utf8) else { throw ToolReceiptError.revisionMismatch }
        case .changed(let previous):
            guard let revision = receipt.revision, !revision.utf8.elementsEqual(previous.utf8) else { throw ToolReceiptError.revisionMismatch }
        }
    }
}

public enum ToolReceiptError: Error, Equatable, Sendable {
    case invalidExpectation
    case invalidOperationID
    case missing
    case operationMismatch
    case unsuccessful(ToolReceipt.Status, ToolReceipt.Failure?)
    case inconsistentStatus
    case invalidTargets
    case targetsMismatch
    case invalidRevision
    case revisionMismatch
    case unexpectedReceipt
}
