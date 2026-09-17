import AgentModels
import AgentTools
import Foundation
import Testing

struct ToolReceiptRuntimeTests {
    private let arguments: JSONValue = .object(["id": .string("d1"), "expectedRevision": .string("v1")])

    @Test func validatedReceiptSurvivesTypeErasureAndInvalidReceiptsDoNotProduceResults() async throws {
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"), idempotencyKey: "op-1")
        let log = InvocationLog()
        let valid = try AnyAgentTool(ReceiptReadTool(mode: .valid, log: log))
        let result = try await valid.invoke(arguments: arguments, context: context)
        #expect(result.receipt?.operationID == "op-1")
        #expect(result.receipt?.confirmedTargets == [.init(namespace: "cad.document", id: "d1")])
        for (mode, error) in [(ReceiptMode.missing, ToolReceiptError.missing), (.wrongOperation, .operationMismatch),
                               (.wrongTargets, .targetsMismatch), (.unchangedRevision, .revisionMismatch),
                               (.textOnly, .missing), (.failed, .unsuccessful(.failed, .conflict))] {
            let tool = try AnyAgentTool(ReceiptReadTool(mode: mode, log: log))
            await #expect(throws: error) { try await tool.invoke(arguments: arguments, context: context) }
        }
        #expect(await log.contexts.count == 7)
    }

    @Test func missingExpectationOrOperationBindingRejectsBeforeExecutor() async throws {
        let log = InvocationLog()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"))
        let missingKey = try AnyAgentTool(ReceiptReadTool(mode: .valid, log: log))
        await #expect(throws: ToolInvocationError.missingIdempotencyKey) { try await missingKey.invoke(arguments: arguments, context: context) }
        let missingExpectation = try AnyAgentTool(ReceiptReadTool(mode: .valid, log: log, declaresExpectation: false))
        await #expect(throws: ToolInvocationError.receiptValidationUnavailable) { try await missingExpectation.invoke(arguments: arguments, context: context) }
        #expect(await log.contexts.isEmpty)
    }

    @Test func invalidReceiptCannotPublishEvidence() async throws {
        let ledger = EvidenceLedger()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), idempotencyKey: "op", evidenceLedger: ledger)
        let evidence = Evidence(namespace: "resource", id: "new", issuedAt: Date())
        let registry = try ToolRegistry(tools: [AnyAgentTool(ReceiptReadTool(mode: .missing, log: InvocationLog(), evidence: [evidence]))])
        let call = ToolCall(id: context.callID, name: ReceiptReadTool.name,
                            argumentsJSON: #"{"id":"d1","expectedRevision":"v1"}"#, completeness: .complete)
        await #expect(throws: ToolReceiptError.missing) { try await registry.prepare(call, context: context).invoke() }
        await #expect(throws: EvidenceError.unavailable(evidence.reference)) {
            try await ledger.validate([.init(reference: evidence.reference)], sessionID: context.sessionID, runID: context.runID)
        }
    }

    @Test func undeclaredReceiptIsRejectedAndSafeIdempotencyDoesNotWaiveADeclaredReceipt() async throws {
        let log = InvocationLog()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), idempotencyKey: "op")
        let undeclared = try AnyAgentTool(ReceiptReadTool(mode: .valid, log: log, declaresExpectation: false, idempotency: .safe))
        await #expect(throws: ToolReceiptError.unexpectedReceipt) { try await undeclared.invoke(arguments: arguments, context: context) }
        let declared = try AnyAgentTool(ReceiptReadTool(mode: .missing, log: log, idempotency: .safe))
        await #expect(throws: ToolReceiptError.missing) { try await declared.invoke(arguments: arguments, context: context) }
    }

    @Test func validReceiptDeclarationCannotBypassMutationAdmissionGate() async throws {
        let log = InvocationLog()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), idempotencyKey: "op")
        let tool = try AnyAgentTool(ReceiptReadTool(mode: .valid, log: log, effect: .mutation))
        await #expect(throws: ToolInvocationError.mutationIntegrityUnavailable) { try await tool.invoke(arguments: arguments, context: context) }
        #expect(await log.contexts.isEmpty)
    }

    @Test func validReceiptWithInvalidOutputCannotPublishEvidence() async throws {
        let ledger = EvidenceLedger()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), idempotencyKey: "op", evidenceLedger: ledger)
        let evidence = Evidence(namespace: "resource", id: "new", issuedAt: Date())
        let base = try ReceiptReadTool(mode: .valid, log: InvocationLog(), evidence: [evidence])
        let registry = try ToolRegistry(tools: [AnyAgentTool(BadReceiptOutputTool(base: base))])
        let call = ToolCall(id: context.callID, name: BadReceiptOutputTool.name,
                            argumentsJSON: #"{"id":"d1","expectedRevision":"v1"}"#, completeness: .complete)
        await #expect(throws: ToolRegistryError.self) { try await registry.prepare(call, context: context).invoke() }
        await #expect(throws: EvidenceError.unavailable(evidence.reference)) {
            try await ledger.validate([.init(reference: evidence.reference)], sessionID: context.sessionID, runID: context.runID)
        }
    }

    @Test func receiptRequirementDoesNotReplaceEvidenceRequirement() async throws {
        let ledger = EvidenceLedger()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), idempotencyKey: "op", evidenceLedger: ledger)
        let log = InvocationLog()
        let base = try ReceiptReadTool(mode: .valid, log: log)
        let tool = try AnyAgentTool(EvidenceReceiptTool(base: base))
        await #expect(throws: EvidenceError.self) { try await tool.invoke(arguments: arguments, context: context) }
        #expect(await log.contexts.isEmpty)
        try await ledger.record([.init(namespace: "cad.document", id: "d1", issuedAt: Date(), metadata: ["revision": .string("v1")])],
                                sessionID: context.sessionID, runID: context.runID)
        #expect(try await tool.invoke(arguments: arguments, context: context).receipt?.revision == "v2")
        #expect(await log.contexts.count == 1)
    }
}

enum ReceiptMode: Sendable { case valid, missing, wrongOperation, wrongTargets, unchangedRevision, textOnly, failed }

struct ReceiptReadTool: AgentTool {
    struct Input: Codable, Sendable { let id: String; let expectedRevision: String }
    typealias Output = JSONValue
    static let name = "confirm_document_read"
    static let description = "Read a document with an execution confirmation"
    static let inputSchema = ToolSchema.object(properties: ["id": .string, "expectedRevision": .string], required: ["id", "expectedRevision"])
    static let outputSchema = ToolSchema(json: .object(["type": .string("object")]))
    let policy: ToolPolicy
    let mode: ReceiptMode
    let log: InvocationLog
    let declaresExpectation: Bool
    let evidence: [Evidence]

    init(mode: ReceiptMode, log: InvocationLog, declaresExpectation: Bool = true, evidence: [Evidence] = [],
         effect: ToolPolicy.Effect = .readOnly, idempotency: ToolPolicy.Idempotency = .requiresReceipt) throws {
        self.mode = mode; self.log = log; self.declaresExpectation = declaresExpectation; self.evidence = evidence
        policy = try ToolPolicy(effect: effect, execution: effect == .mutation ? .exclusive : .sequential,
                                idempotency: idempotency, timeout: .seconds(1), authorization: .notRequired)
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        guard declaresExpectation else { return nil }
        return try ToolReceiptExpectation(targets: [.init(namespace: "cad.document", id: input.id)], revision: .changed(from: input.expectedRevision))
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(context)
        let receipt: ToolReceipt? = mode == .missing || mode == .textOnly ? nil : .init(
            operationID: mode == .wrongOperation ? "other" : (context.idempotencyKey ?? "missing"),
            status: mode == .failed ? .failed : .succeeded,
            confirmedTargets: [.init(namespace: "cad.document", id: mode == .wrongTargets ? "other" : input.id)],
            revision: mode == .unchangedRevision ? input.expectedRevision : "v2", failure: mode == .failed ? .conflict : nil
        )
        var output: [String: JSONValue] = ["message": .string("Done")]
        if mode == .textOnly { output["receipt"] = .object(["status": .string("succeeded")]) }
        return ToolResult(output: .object(output),
                          evidence: evidence, receipt: receipt)
    }
}

struct BadReceiptOutputTool: AgentTool {
    typealias Input = ReceiptReadTool.Input
    typealias Output = ReceiptReadTool.Output
    static let name = "bad_output_receipt"
    static let description = ReceiptReadTool.description
    static let inputSchema = ReceiptReadTool.inputSchema
    static let outputSchema = ToolSchema.object(properties: ["value": .integer], required: ["value"])
    let base: ReceiptReadTool
    var policy: ToolPolicy { base.policy }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try base.receiptExpectation(for: input) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { try await base.execute(input, context: context) }
}

struct EvidenceReceiptTool: AgentTool {
    typealias Input = ReceiptReadTool.Input
    typealias Output = ReceiptReadTool.Output
    static let name = "evidence_receipt"
    static let description = ReceiptReadTool.description
    static let inputSchema = ReceiptReadTool.inputSchema
    static let outputSchema = ReceiptReadTool.outputSchema
    let base: ReceiptReadTool
    let policy: ToolPolicy
    init(base: ReceiptReadTool) throws {
        self.base = base
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .requiresReceipt,
                                timeout: .seconds(1), authorization: .notRequired, evidence: .required)
    }
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "cad.document", id: input.id), metadata: ["revision": .string(input.expectedRevision)])]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try base.receiptExpectation(for: input) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { try await base.execute(input, context: context) }
}
