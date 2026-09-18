import AgentModels
import Foundation

/// Typed tool implemented by hosts. Authors declare Codable input/output and
/// a policy. The runtime erases JSON for the model; tool code should not
/// build argument dictionaries by hand.
public protocol AgentTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolSchema { get }
    static var outputSchema: ToolSchema { get }
    var policy: ToolPolicy { get }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement]
    func resourceRequirements(for input: Input) throws -> [ToolResource]
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation?
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output>
}

/// Trusted runtime admission required immediately before a mutation executor runs.
package protocol ToolMutationAdmission: Sendable {
    @discardableResult
    func admit(_ request: ToolMutationAdmissionRequest) async throws -> ToolMutationAdmissionResult
}

package enum ToolMutationAdmissionResult: Sendable {
    case admitted
    case settled(receipt: ToolReceipt, output: JSONValue)
}

package struct ToolMutationAdmissionRequest: Codable, Equatable, Sendable {
    package let sessionID: UUID
    package let runID: UUID
    package let callID: ToolCallID
    package let name: String
    package let argumentsJSON: String
    package let resources: [ToolResource]
    package let idempotencyKey: String
    package let receiptExpectation: ToolReceiptExpectation?

    package init(
        sessionID: UUID,
        runID: UUID,
        callID: ToolCallID,
        name: String,
        argumentsJSON: String,
        resources: [ToolResource],
        idempotencyKey: String,
        receiptExpectation: ToolReceiptExpectation?
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.callID = callID
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.resources = resources
        self.idempotencyKey = idempotencyKey
        self.receiptExpectation = receiptExpectation
    }
}

public enum ToolAuthorization: Sendable { case allowed, denied }

/// A business-domain failure that a read-only tool may explicitly expose to
/// the model when its policy opts into recoverable errors.
public struct RecoverableToolError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: JSONValue?

    public init(code: String, message: String, details: JSONValue? = nil) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecoverableToolErrorValidationError.emptyCode
        }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecoverableToolErrorValidationError.emptyMessage
        }
        self.code = code
        self.message = message
        self.details = details
    }

    package var payload: JSONValue {
        var fields: [String: JSONValue] = ["code": .string(code), "message": .string(message)]
        if let details { fields["details"] = details }
        return .object(fields)
    }
}

public enum RecoverableToolErrorValidationError: Error, Equatable, Sendable {
    case emptyCode
    case emptyMessage
}

extension AgentTool {
    public func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [] }
    public func resourceRequirements(for input: Input) throws -> [ToolResource] { [.global] }
    public func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { nil }
    public func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { .denied }
}

/// Executor output and unverified metadata. The runtime validates receipts before acknowledging the result.
public struct ToolResult<Output: Codable & Sendable>: Sendable {
    public let output: Output
    public let evidence: [Evidence]
    public let receipt: ToolReceipt?
    package let isIdempotentReplay: Bool
    package let isModelVisibleError: Bool

    public init(output: Output, evidence: [Evidence] = [], receipt: ToolReceipt? = nil) {
        self.output = output
        self.evidence = evidence
        self.receipt = receipt
        isIdempotentReplay = false
        isModelVisibleError = false
    }

    package init(output: Output, evidence: [Evidence] = [], receipt: ToolReceipt?, isIdempotentReplay: Bool) {
        self.output = output
        self.evidence = evidence
        self.receipt = receipt
        self.isIdempotentReplay = isIdempotentReplay
        isModelVisibleError = false
    }

    package init(modelVisibleError output: Output) {
        self.output = output
        evidence = []
        receipt = nil
        isIdempotentReplay = false
        isModelVisibleError = true
    }
}
