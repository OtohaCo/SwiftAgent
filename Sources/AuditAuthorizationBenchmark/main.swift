import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main struct AuditAuthorizationBenchmark {
    static func main() async throws {
        let samples = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 20
        guard samples > 0, samples <= 200 else { throw AgentAuthorizationError.invalidConfiguration }
        var results: [[String: Any]] = []
        for scenario in ["legacy", "required-allow", "required-deny", "unrelated-100", "long-session-60", "export-behind-100"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-benchmark-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let audited = scenario != "legacy", denying = scenario == "required-deny"
            let journal = try AgentIncrementalJournal.create(at: root.appendingPathComponent("journal"),
                operationDomain: "audit-benchmark", supportsAuthorizationAudit: audited)
            let authorizer = BenchmarkAuthorizer(deny: denying), counters = BenchmarkCounters()
            let authorization = audited ? AgentAuthorizationConfiguration(mode: .requiredAudit, authorizer: authorizer,
                identity: .init(securityDomain: "benchmark", subjectID: "user", actingSubjectID: "agent",
                    backend: .init(instanceID: "local", version: "1", accountID: "fixture", credentialGeneration: "1"))) : .init()
            let agent = try Agent(model: .init(provider: "benchmark", name: "script"), provider: BenchmarkProvider(),
                tools: [BenchmarkWrite(file: root.appendingPathComponent("effect"), counters: counters)],
                configuration: .init(runTimeout: .seconds(60), authorization: authorization))
            let session = try agent.makeSession(journal: journal)
            if scenario == "unrelated-100" || scenario == "long-session-60" {
                let seed = try Agent(model: .init(provider: "benchmark", name: "script"), provider: BenchmarkTextProvider())
                for index in 0..<(scenario == "unrelated-100" ? 100 : 60) {
                    let target = scenario == "unrelated-100" ? try seed.makeSession(journal: journal) : session
                    let run = try await target.run("seed-\(index)")
                    _ = try await run.wait(); try await run.waitForDrain()
                }
            }
            if scenario == "export-behind-100" {
                for index in 0..<100 {
                    let run = try await agent.makeSession(journal: journal).run("write-\(index)")
                    _ = try await run.wait(); try await run.waitForDrain()
                }
            }
            let before = try await require(journal.storageMetrics())
            var latencies: [Double] = []
            let beforeAuthorizations = await authorizer.calls
            let beforeExecutions = await counters.executions
            for index in 0..<samples {
                let start = DispatchTime.now().uptimeNanoseconds
                let run = try await session.run("measure-\(index)", operationID: "measure-\(index)")
                do { _ = try await run.wait() } catch AgentAuthorizationError.authorizationDenied { guard denying else { throw AgentAuthorizationError.authorizationDenied } }
                try await run.waitForDrain()
                latencies.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            let after = try await require(journal.storageMetrics())
            latencies.sort()
            results.append([
                "scenario": scenario, "samples": samples,
                "p50Milliseconds": latencies[(samples - 1) / 2], "p95Milliseconds": latencies[Int(Double(samples - 1) * 0.95)],
                "minMilliseconds": latencies.first!, "maxMilliseconds": latencies.last!,
                "bytesRead": after.bytesRead - before.bytesRead, "bytesWritten": after.bytesWritten - before.bytesWritten,
                "decodedBatches": after.decodedBatches - before.decodedBatches,
                "encodedBatches": after.encodedBatches - before.encodedBatches,
                "committedBatches": after.committedBatches - before.committedBatches,
                "authorizerCalls": await authorizer.calls - beforeAuthorizations,
                "executorEntered": await counters.executions - beforeExecutions,
                "note": "New temporary store; same process; OS cache uncontrolled; includes Run and physical drain; maintenance included in metrics"
            ])
            try await journal.close()
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
    private static func require<T>(_ value: T?) throws -> T { guard let value else { throw AgentAuthorizationError.auditUnavailable }; return value }
}

private actor BenchmarkAuthorizer: AgentAuthorizer {
    let deny: Bool; private(set) var calls = 0
    init(deny: Bool) { self.deny = deny }
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        calls += 1
        return .init(request: request, outcome: deny ? .deny : .allow,
            subject: .init(issuer: "benchmark", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "local", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
    }
}
private actor BenchmarkCounters {
    private(set) var executions = 0
    func entered() { executions += 1 }
}
private struct BenchmarkWrite: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "benchmark_write", description = "Temporary file mutation"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"]), outputSchema = ToolSchema.string
    let file: URL; let counters: BenchmarkCounters
    let policy = try! ToolPolicy.mutation(timeout: .seconds(30), authorization: .notRequired, evidence: .none)
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "benchmark", id: "file"))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "benchmark", id: "file")], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await counters.entered(); try Data(input.id.utf8).write(to: file, options: .atomic)
        return .init(output: input.id, receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "benchmark", id: "file")], revision: "1"))
    }
}
private struct BenchmarkProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "benchmark", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("done")); try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn))); return
            }
            let id = request.runID?.uuidString ?? UUID().uuidString
            let call = ToolCall(id: .init(rawValue: id), name: BenchmarkWrite.name, argumentsJSON: "{\"id\":\"\(id)\"}", completeness: .complete)
            try emit(.toolCallStarted(call.id, name: call.name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}
private struct BenchmarkTextProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "benchmark", capabilities: [.multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture", model: request.model), text = String(repeating: "x", count: 256)
            try emit(.responseStarted(info)); try emit(.textDelta(text)); try emit(.responseCompleted(.init(info: info, content: [.text(text)], stopReason: .endTurn)))
        }
    }
}
