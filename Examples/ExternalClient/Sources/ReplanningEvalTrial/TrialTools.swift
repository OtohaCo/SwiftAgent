import AgentCore
import AgentModels
import AgentTools
import Foundation

struct EvalSearch: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let candidates: [String]; let note: String }
    static let name = "search_candidates"
    static let description = "Find generic test resources and their available references."
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(properties: [
        "candidates": .array(items: .string), "note": .string,
    ], required: ["candidates", "note"])
    let task: EvalTask
    let probe: TrialProbe
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)

    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.global] }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.searchReturned()
        // X may appear in controlled test data, but only the trusted read tool
        // signs A and B. No test code rewrites a model call or mints Evidence for X.
        let firstSearch = await probe.searches == 1
        let candidates = task.group == "controlled_error" && firstSearch ? ["X", "A", "B"] : ["A", "B"]
        return .init(output: .init(candidates: candidates,
            note: candidates.contains("X") ? "X is listed but may be stale; use an evidenced reference." :
                "Only evidenced references can be committed."), evidence: [
            .init(namespace: "eval.resource", id: "A", issuedAt: Date()),
            .init(namespace: "eval.resource", id: "B", issuedAt: Date()),
        ])
    }
}

struct EvalCommit: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let committed: String }
    static let name = "commit_resource"
    static let description = "Commit one evidenced generic test resource. Do not use a reference without Evidence."
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["committed": .string], required: ["committed"])
    let task: EvalTask
    let probe: TrialProbe
    let file: URL
    let policy = try! ToolPolicy.mutation(authorization: .required, evidence: .required)

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "eval.resource", id: input.id))]
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "eval.resource", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "eval.resource", id: input.id)], revision: .present)
    }
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        task.scenario == "permission_denied" ? .denied : .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.executorEnteredEffect()
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(input.id)\n".utf8))
        try handle.synchronize()
        await probe.effectSynced()
        if task.scenario == "unknown_after_write" {
            throw EvalTrialError.dryRunFailure
        }
        return .init(output: .init(committed: input.id), receipt: .init(
            operationID: context.idempotencyKey ?? "missing", status: .succeeded,
            confirmedTargets: [.init(namespace: "eval.resource", id: input.id)],
            revision: "temporary-file-v1"))
    }
}
