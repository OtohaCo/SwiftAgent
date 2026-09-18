/// Scheduling and integrity rules for one tool. Prefer `readOnly()` and
/// `mutation()` unless a read tool must run sequentially.
public struct ToolPolicy: Hashable, Codable, Sendable {
    public enum Effect: String, Hashable, Codable, Sendable { case readOnly, mutation }
    public enum Execution: String, Hashable, Codable, Sendable { case parallel, sequential, exclusive }
    public enum Idempotency: String, Hashable, Codable, Sendable { case safe, keyed, requiresReceipt }
    public enum Authorization: String, Hashable, Codable, Sendable { case required, notRequired }
    public enum EvidencePolicy: String, Hashable, Codable, Sendable { case none, required }
    public enum RecoverableErrors: String, Hashable, Codable, Sendable { case failClosed, modelVisible }

    public let effect: Effect
    public let execution: Execution
    public let idempotency: Idempotency
    /// Scheduling limit; declaring a timeout does not enforce it.
    public let timeout: Duration
    public let authorization: Authorization
    public let evidence: EvidencePolicy
    public let recoverableErrors: RecoverableErrors

    private enum CodingKeys: String, CodingKey {
        case effect, execution, idempotency, timeout, authorization, evidence, recoverableErrors
    }

    public init(
        effect: Effect,
        execution: Execution,
        idempotency: Idempotency,
        timeout: Duration,
        authorization: Authorization = .required,
        evidence: EvidencePolicy = .none,
        recoverableErrors: RecoverableErrors = .failClosed
    ) throws {
        guard timeout > .zero else { throw ToolPolicyError.invalidTimeout }
        guard effect != .mutation || execution == .exclusive else {
            throw ToolPolicyError.mutationRequiresExclusiveExecution
        }
        guard effect == .readOnly || recoverableErrors == .failClosed else {
            throw ToolPolicyError.mutationCannotExposeRecoverableErrors
        }
        self.effect = effect
        self.execution = execution
        self.idempotency = idempotency
        self.timeout = timeout
        self.authorization = authorization
        self.evidence = evidence
        self.recoverableErrors = recoverableErrors
    }

    /// Parallel, retry-safe observation. Authorization still defaults to required.
    public static func readOnly(
        timeout: Duration = .seconds(5),
        authorization: Authorization = .required,
        evidence: EvidencePolicy = .none,
        recoverableErrors: RecoverableErrors = .failClosed
    ) throws -> ToolPolicy {
        try ToolPolicy(
            effect: .readOnly, execution: .parallel, idempotency: .safe,
            timeout: timeout, authorization: authorization, evidence: evidence,
            recoverableErrors: recoverableErrors
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

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            effect: container.decode(Effect.self, forKey: .effect),
            execution: container.decode(Execution.self, forKey: .execution),
            idempotency: container.decode(Idempotency.self, forKey: .idempotency),
            timeout: container.decode(Duration.self, forKey: .timeout),
            authorization: container.decode(Authorization.self, forKey: .authorization),
            evidence: container.decode(EvidencePolicy.self, forKey: .evidence),
            recoverableErrors: container.decodeIfPresent(RecoverableErrors.self, forKey: .recoverableErrors) ?? .failClosed
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(effect, forKey: .effect)
        try container.encode(execution, forKey: .execution)
        try container.encode(idempotency, forKey: .idempotency)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(authorization, forKey: .authorization)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(recoverableErrors, forKey: .recoverableErrors)
    }
}

public enum ToolPolicyError: Error, Equatable, Sendable {
    case invalidTimeout
    case mutationRequiresExclusiveExecution
    case mutationCannotExposeRecoverableErrors
}
