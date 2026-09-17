public protocol AgentTool: Sendable {
    associatedtype Input: Codable & Sendable
    associatedtype Output: Codable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolSchema { get }
    static var outputSchema: ToolSchema { get }
    var policy: ToolPolicy { get }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement]
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output>
}

public enum ToolAuthorization: Sendable { case allowed, denied }

extension AgentTool {
    public func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [] }
    public func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { .denied }
}

/// Typed executor output. This is not a mutation receipt or a verified success claim.
public struct ToolResult<Output: Codable & Sendable>: Sendable {
    public let output: Output
    public let evidence: [Evidence]

    public init(output: Output, evidence: [Evidence] = []) {
        self.output = output
        self.evidence = evidence
    }
}
