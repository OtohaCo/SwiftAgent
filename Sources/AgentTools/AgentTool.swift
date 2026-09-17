public protocol AgentTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolSchema { get }
    static var outputSchema: ToolSchema { get }
    var policy: ToolPolicy { get }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement]
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation?
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output>
}

public enum ToolAuthorization: Sendable { case allowed, denied }

extension AgentTool {
    public func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [] }
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
