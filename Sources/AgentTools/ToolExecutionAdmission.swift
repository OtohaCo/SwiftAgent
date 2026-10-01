import Foundation

/// AgentCore supplies the owner. No Host tool can forge a scope by constructing
/// a public ToolContext; this seam is package-only and cannot settle a Journal.
package protocol ToolExecutionAdmission: Sendable {
    var scopeInstanceID: UUID? { get }
    func check(runID: UUID, resources: [ToolResource]) async throws
    func admit(runID: UUID, resources: [ToolResource]) async throws -> UUID
    func release(_ ticket: UUID) async
}

extension ToolExecutionAdmission {
    package var scopeInstanceID: UUID? { nil }
}
