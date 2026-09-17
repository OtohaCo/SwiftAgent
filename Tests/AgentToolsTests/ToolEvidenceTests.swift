import AgentModels
import AgentTools
import Foundation
import Testing

struct ToolEvidenceTests {
    @Test func validatedOutputPublishesEvidenceForLaterToolButModelArgumentsCannotGrantIt() async throws {
        let ledger = EvidenceLedger()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c1"), evidenceLedger: ledger)
        let log = InvocationLog()
        let registry = try ToolRegistry(tools: [AnyAgentTool(EvidenceSourceTool()), AnyAgentTool(EvidenceReaderTool(log: log))])
        let read = ToolCall(id: context.callID, name: "read_document", argumentsJSON: #"{"id":"d1"}"#, completeness: .complete)
        await #expect(throws: EvidenceError.self) { try await registry.prepare(read, context: context).invoke() }
        #expect(await log.contexts.isEmpty)
        let discover = ToolCall(id: context.callID, name: "discover", argumentsJSON: #"{"id":"d1"}"#, completeness: .complete)
        _ = try await registry.prepare(discover, context: context).invoke()
        #expect(try await registry.prepare(read, context: context).invoke().output == .string("read"))
        #expect(await log.contexts.count == 1)
    }

    @Test func invalidOutputDoesNotPublishItsEvidence() async throws {
        let ledger = EvidenceLedger()
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), evidenceLedger: ledger)
        let registry = try ToolRegistry(tools: [AnyAgentTool(EvidenceSourceTool(output: .object(["id": .number(1)])))])
        let call = ToolCall(id: context.callID, name: "discover", argumentsJSON: #"{"id":"d1"}"#, completeness: .complete)
        await #expect(throws: ToolRegistryError.self) { try await registry.prepare(call, context: context).invoke() }
        await #expect(throws: EvidenceError.self) {
            try await ledger.validate([.init(reference: .init(namespace: "cad.document", id: "d1"))], sessionID: context.sessionID, runID: context.runID)
        }
    }

    @Test func evidenceIsRevalidatedAfterAuthorizationWait() async throws {
        let clock = EvidenceTestClock(Date(timeIntervalSince1970: 100))
        let ledger = EvidenceLedger(now: { clock.now() })
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"), evidenceLedger: ledger)
        let log = InvocationLog()
        try await ledger.record([.init(namespace: "cad.document", id: "d1", issuedAt: clock.now(),
                                      expiresAt: clock.now().addingTimeInterval(1), metadata: ["revision": .string("v1")])],
                                sessionID: context.sessionID, runID: context.runID)
        let tool = try EvidenceReaderTool(log: log, authorization: .required, authorize: { clock.set(Date(timeIntervalSince1970: 101)) })
        let registry = try ToolRegistry(tools: [AnyAgentTool(tool)])
        let call = ToolCall(id: context.callID, name: "read_document", argumentsJSON: #"{"id":"d1"}"#, completeness: .complete)
        await #expect(throws: EvidenceError.self) { try await registry.prepare(call, context: context).invoke() }
        #expect(await log.contexts.isEmpty)
    }

    @Test func requiredEvidenceWithoutLedgerOrResolverFailsClosed() async throws {
        let context = ToolContext(sessionID: UUID(), runID: UUID(), callID: .init(rawValue: "c"))
        let log = InvocationLog()
        let reader = try AnyAgentTool(EvidenceReaderTool(log: log))
        await #expect(throws: ToolInvocationError.evidenceUnavailable) {
            try await reader.invoke(arguments: .object(["id": .string("d1")]), context: context)
        }
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                    timeout: .seconds(1), authorization: .notRequired, evidence: .required)
        let noResolver = try AnyAgentTool(RecordingTool(policy: policy, log: log))
        await #expect(throws: EvidenceError.emptyRequirements) {
            try await noResolver.invoke(arguments: .object(["value": .number(1)]), context: context)
        }
        #expect(await log.contexts.isEmpty)
    }
}

struct EvidenceSourceTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = JSONValue
    static let name = "discover"
    static let description = "Discover a document"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = inputSchema
    let policy: ToolPolicy
    let output: JSONValue?
    init(output: JSONValue? = nil) throws {
        self.output = output
        policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(1), authorization: .notRequired)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: output ?? .object(["id": .string(input.id)]), evidence: [
            .init(namespace: "cad.document", id: input.id, issuedAt: Date(), metadata: ["revision": .string("v1")]),
        ])
    }
}

struct EvidenceReaderTool: AgentTool {
    typealias Input = EvidenceSourceTool.Input
    typealias Output = String
    static let name = "read_document"
    static let description = "Read a verified document"
    static let inputSchema = EvidenceSourceTool.inputSchema
    static let outputSchema = ToolSchema.string
    let policy: ToolPolicy
    let log: InvocationLog
    let authorization: @Sendable () async -> Void
    init(log: InvocationLog, authorization: ToolPolicy.Authorization = .notRequired,
         authorize: @escaping @Sendable () async -> Void = {}) throws {
        self.log = log
        self.authorization = authorize
        policy = try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe,
                                timeout: .seconds(1), authorization: authorization, evidence: .required)
    }
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "cad.document", id: input.id), metadata: ["revision": .string("v1")])]
    }
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization { await authorization(); return .allowed }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(context)
        return ToolResult(output: "read")
    }
}
