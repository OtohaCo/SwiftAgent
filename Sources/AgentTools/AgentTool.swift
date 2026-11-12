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
    /// What the model sees and what arguments and output are checked against. Defaults to the
    /// type's name, description and schemas; a `RuntimeAgentTool` supplies its own.
    var definition: ModelToolDefinition { get }
    var policy: ToolPolicy { get }
    /// For a mutation tool, the read-only policy of a call that, for this input, only observes, or nil to keep
    /// `policy`. Such a call is scheduled, authorized and settled as a read: a shared lease, beside neighbouring
    /// parallel reads when its execution is `.parallel`, and no mutation intent or reconciliation. Its receipt is
    /// still checked when `receiptExpectation(for:)` declares one. Decide from the input alone: the runtime asks
    /// again before audited dispatch and expects the same answer. A policy that is not read-only, or one returned
    /// by a tool whose own policy proves no effect (`.confirmedNoEffect`), fails the call's preparation.
    func readOnlyPolicy(for input: Input) throws -> ToolPolicy?
    /// The most a result of this tool may add to the conversation, in bytes of encoded JSON output; a larger
    /// one is cut before it is committed, with a notice the model reads (`AgentToolResultLimit`). At least
    /// `AgentToolResultLimit.minimumBytes`; defaults to `AgentToolResultLimit.defaultBytes`.
    var maximumResultBytes: Int { get }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement]
    /// What the call's scheduler lease covers. Mutations and exclusive calls wait only for calls whose resources
    /// overlap theirs (`.global` overlaps all), so a mutation must name everything another Session's call could
    /// touch at the same time; the default, `[.global]`, waits for every other call. Empty, duplicate or blank
    /// names fail before the call runs.
    func resourceRequirements(for input: Input) throws -> [ToolResource]
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation?
    /// Declare immutable action versions; checked again just before audited dispatch.
    func authorizationBinding(for input: Input) throws -> ToolAuthorizationBinding
    /// Runs before the executor and before any mutation intent. `.denied`, or a thrown error, is told to
    /// the model as this call's error result and the Run goes on (ADR 0016): a `RecoverableToolError` with
    /// its own code and message, anything else in fixed words. Cancel the Run to stop it instead.
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output>
}

extension AgentTool {
    public func authorizationBinding(for input: Input) throws -> ToolAuthorizationBinding { .init() }
}

/// Trusted runtime admission required immediately before a mutation executor runs.
package protocol ToolMutationAdmission: Sendable {
    var noEffectProofVersion: Int { get }
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
    public var definition: ModelToolDefinition {
        ModelToolDefinition(name: Self.name, description: Self.description, inputSchema: Self.inputSchema.json, outputSchema: Self.outputSchema.json)
    }

    public func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] { [] }
    public func readOnlyPolicy(for input: Input) throws -> ToolPolicy? { nil }
    public func resourceRequirements(for input: Input) throws -> [ToolResource] { [.global] }
    public func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { nil }
    public var maximumResultBytes: Int { AgentToolResultLimit.defaultBytes }
    public func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { .denied }
}

/// Executor output and unverified metadata. The runtime validates receipts before acknowledging the result.
public struct ToolResult<Output: Codable & Sendable>: Sendable {
    public internal(set) var output: Output
    public let evidence: [Evidence]
    public let receipt: ToolReceipt?
    /// Names of tools bound to this Run that the model is told about from the Run's next model
    /// request on, typically deferred tools a Host's tool-search tool found. Each must be exactly the
    /// name of a tool the Run has, or the call fails with `ToolRegistryError.unknownTool`; like output
    /// validation, that check follows the executor, so for a mutation the effect may have happened.
    /// Declaring grants nothing: a declared tool's call passes the same authorization, Evidence,
    /// mutation admission and Receipt checks as any other. Applied only once this result is
    /// committed; a settled mutation replay returns its stored output and declares nothing. Declare
    /// from read-only tools.
    public let declaredTools: [String]
    /// Images the model may look at after the output, such as a screenshot or a video frame (ADR 0012).
    /// At most `ModelImage.maximumImagesPerMessage`; more fail the call after the executor ran, like an
    /// invalid output. Whether the model is sent them or their text substitutes is the Run's image
    /// policy. A settled mutation replay returns its stored output without images.
    public let images: [ModelImage]
    package let isIdempotentReplay: Bool
    package let isModelVisibleError: Bool
    package var confirmedNoEffect: ToolNoEffectProof? = nil
    /// Refused before admission (ADR 0016): no executor entry, no mutation intent, no receipt.
    package var notAdmitted = false

    public init(output: Output, evidence: [Evidence] = [], receipt: ToolReceipt? = nil, declaredTools: [String] = [],
                images: [ModelImage] = []) {
        self.output = output
        self.evidence = evidence
        self.receipt = receipt
        self.declaredTools = declaredTools
        self.images = images
        isIdempotentReplay = false
        isModelVisibleError = false
    }

    package init(output: Output, evidence: [Evidence] = [], receipt: ToolReceipt?, isIdempotentReplay: Bool) {
        self.output = output
        self.evidence = evidence
        self.receipt = receipt
        declaredTools = []
        images = []
        self.isIdempotentReplay = isIdempotentReplay
        isModelVisibleError = false
    }

    package init(modelVisibleError output: Output) {
        self.output = output
        evidence = []
        receipt = nil
        declaredTools = []
        images = []
        isIdempotentReplay = false
        isModelVisibleError = true
    }
}

/// A tool whose name, description and schemas are known only at runtime: one declared by a Host's
/// configuration, or offered by an external server. Its arguments and output are JSON, checked against
/// its definition's schemas like any other tool's; authorization, Evidence, Receipts and mutation
/// admission apply unchanged, under the definition's name. The type's static name, description and
/// schemas are not used.
public protocol RuntimeAgentTool: AgentTool where Input == JSONValue, Output == JSONValue {
    /// The definition given at runtime. Its output schema is required.
    var runtimeDefinition: ModelToolDefinition { get }
}

extension RuntimeAgentTool {
    public var definition: ModelToolDefinition { runtimeDefinition }
    public static var name: String { "" }
    public static var description: String { "" }
    public static var inputSchema: ToolSchema { .object(properties: [:]) }
    public static var outputSchema: ToolSchema { .object(properties: [:]) }
}

extension ToolMutationAdmission {
    package var noEffectProofVersion: Int { 1 }
}
