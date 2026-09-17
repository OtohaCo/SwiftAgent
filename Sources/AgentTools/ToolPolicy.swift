/// Scheduling and integrity rules for one tool. Prefer `readOnly()` and
/// `mutation()` unless a read tool must run sequentially.
public struct ToolPolicy: Hashable, Codable, Sendable {
    public enum Effect: String, Hashable, Codable, Sendable { case readOnly, mutation }
    public enum Execution: String, Hashable, Codable, Sendable { case parallel, sequential, exclusive }
    public enum Idempotency: String, Hashable, Codable, Sendable { case safe, keyed, requiresReceipt }
    public enum Authorization: String, Hashable, Codable, Sendable { case required, notRequired }
    public enum EvidencePolicy: String, Hashable, Codable, Sendable { case none, required }

    public let effect: Effect
    public let execution: Execution
    public let idempotency: Idempotency
    /// Scheduling limit; declaring a timeout does not enforce it.
    public let timeout: Duration
    public let authorization: Authorization
    public let evidence: EvidencePolicy

    public init(
        effect: Effect,
        execution: Execution,
        idempotency: Idempotency,
        timeout: Duration,
        authorization: Authorization = .required,
        evidence: EvidencePolicy = .none
    ) throws {
        guard timeout > .zero else { throw ToolPolicyError.invalidTimeout }
        guard effect != .mutation || execution == .exclusive else {
            throw ToolPolicyError.mutationRequiresExclusiveExecution
        }
        self.effect = effect
        self.execution = execution
        self.idempotency = idempotency
        self.timeout = timeout
        self.authorization = authorization
        self.evidence = evidence
    }

    /// Parallel, retry-safe observation. Authorization still defaults to required.
    public static func readOnly(
        timeout: Duration = .seconds(5),
        authorization: Authorization = .required,
        evidence: EvidencePolicy = .none
    ) throws -> ToolPolicy {
        try ToolPolicy(
            effect: .readOnly, execution: .parallel, idempotency: .safe,
            timeout: timeout, authorization: authorization, evidence: evidence
        )
    }

    /// Exclusive mutation. Existing files and other unique targets should also
    /// declare Evidence and a receipt expectation on the tool itself.
    public static func mutation(
        idempotency: Idempotency = .requiresReceipt,
        timeout: Duration = .seconds(5),
        authorization: Authorization = .required,
        evidence: EvidencePolicy = .required
    ) throws -> ToolPolicy {
        try ToolPolicy(
            effect: .mutation, execution: .exclusive, idempotency: idempotency,
            timeout: timeout, authorization: authorization, evidence: evidence
        )
    }
}

public enum ToolPolicyError: Error, Equatable, Sendable {
    case invalidTimeout
    case mutationRequiresExclusiveExecution
}
