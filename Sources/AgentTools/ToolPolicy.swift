public struct ToolPolicy: Hashable, Sendable {
    public enum Effect: Sendable { case readOnly, mutation }
    public enum Execution: Sendable { case parallel, sequential, exclusive }
    public enum Idempotency: Sendable { case safe, keyed, requiresReceipt }
    public enum Authorization: Sendable { case required, notRequired }
    public enum EvidencePolicy: Sendable { case none, required }

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
}

public enum ToolPolicyError: Error, Equatable, Sendable {
    case invalidTimeout
    case mutationRequiresExclusiveExecution
}
