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
    func admit(_ request: ToolMutationAdmissionRequest) async throws
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

    public init(output: Output, evidence: [Evidence] = [], receipt: ToolReceipt? = nil) {
        self.output = output
        self.evidence = evidence
        self.receipt = receipt
    }
}
