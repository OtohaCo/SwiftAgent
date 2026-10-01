import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main struct JournalTestProcess {
    static func main() async {
        guard CommandLine.arguments.count >= 3 else { exit(64) }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let journal = try AgentIncrementalJournal.open(at: directory)
            switch mode {
            case "probe":
                try await journal.close()
                exit(0)
            case "read-no-effect":
                guard CommandLine.arguments.count == 5, let sessionID = UUID(uuidString: CommandLine.arguments[3]),
                      let runID = UUID(uuidString: CommandLine.arguments[4]) else { exit(64) }
                let confirmation = try await journal.executorNoEffectConfirmation(sessionID: sessionID, runID: runID, callID: .init(rawValue: "no-effect"))
                let history = try await journal.latestCheckpoint(sessionID: sessionID)?.history ?? []
                let paired = history.contains { if case .tool(let r) = $0 { return r.isError && r.callID.rawValue == "no-effect" }; return false }
                let page = try await journal.auditRecords(matching: .init(runID: runID))
                let executor = page.records.filter { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation && r.settlementSource == .executor }; return false }.count
                print("proof=\(confirmation?.executorProof?.version ?? 0) paired=\(paired) executor=\(executor) pending=\(try await journal.pendingMutations().count)")
                try await journal.close(); exit(0)
            case "no-effect-before-publication", "no-effect-after-publication":
                let id = UUID(uuidString: "00000000-0000-0000-0000-000000000610")!
                let agent = try Agent(model: .init(provider: "no-effect-process", name: "fixed"),
                    provider: NoEffectProcessProvider(large: CommandLine.arguments.count > 3), tools: [NoEffectProcessTool(hold: mode == "no-effect-before-publication")],
                    configuration: .init(runTimeout: .seconds(120), authorization: .init(mode: CommandLine.arguments.count > 3 ? .legacy : .requiredAudit,
                        authorizer: AuditProcessAuthorizer(deny: false),
                        identity: .init(securityDomain: "process-fixture", subjectID: "user", actingSubjectID: "agent",
                            backend: .init(instanceID: "local", version: "1", accountID: "fixture", credentialGeneration: "1")))))
                let run = try await agent.makeSession(id: id, journal: journal).run("conflict", operationID: "no-effect-process")
                _ = try await run.wait(); try await run.waitForDrain(); try await journal.close(); exit(0)
            case "read-audit":
                var cursor: AuditCursor?, count = 0, allowed = 0, denied = 0, applied = 0, observed = 0, results = 0
                var operationIDs: Set<String> = []
                repeat {
                    let page = try await journal.auditRecords(limit: 100, cursor: cursor, includeRestrictedPayload: true)
                    for record in page.records {
                        count += 1
                        if let operation = record.links.operationID { operationIDs.insert(operation) }
                        switch record.fact {
                        case .authorization(let a):
                            if a.layer == .enterprise, a.decision?.outcome == .allow { allowed += 1 }
                            if a.layer == .enterprise, a.decision?.outcome == .deny { denied += 1 }
                        case .disposition(let d):
                            if d.state == .dispatchPrepared { applied += 1 }
                            if d.state == .executorObserved { observed += 1 }
                        case .result: results += 1
                        case .proposal: break
                        }
                    }
                    cursor = page.nextCursor
                } while cursor != nil
                print("audit=\(count) allowed=\(allowed) denied=\(denied) applied=\(applied) observed=\(observed) results=\(results) pending=\(try await journal.pendingMutations().count) operations=\(operationIDs.count)")
                try await journal.close(); exit(0)
            case "audit-deny-and-exit", "audit-write-and-wait", "audit-write-and-settle":
                guard CommandLine.arguments.count == 4 else { exit(64) }
                let file = URL(fileURLWithPath: CommandLine.arguments[3])
                let agent = try Agent(model: .init(provider: "queue-process", name: "fixed"), provider: AuditProcessProvider(),
                    tools: [AuditProcessWrite(file: file, hold: mode == "audit-write-and-wait")],
                    configuration: .init(runTimeout: .seconds(120), authorization: .init(mode: CommandLine.arguments.count > 3 ? .legacy : .requiredAudit,
                        authorizer: AuditProcessAuthorizer(deny: mode == "audit-deny-and-exit"),
                        identity: .init(securityDomain: "process-fixture", subjectID: "user", actingSubjectID: "agent",
                            backend: .init(instanceID: "local", version: "1", accountID: "fixture", credentialGeneration: "1")))))
                let run = try await agent.makeSession(journal: journal).run("write", operationID: "audit-process-effect")
                do { _ = try await run.wait() }
                catch AgentAuthorizationError.authorizationDenied { guard mode == "audit-deny-and-exit" else { throw AgentAuthorizationError.authorizationDenied } }
                try await run.waitForDrain(); try await journal.close(); exit(0)
            case "read-admission-rejection":
                guard CommandLine.arguments.count == 6,
                      let sessionID = UUID(uuidString: CommandLine.arguments[3]),
                      let runID = UUID(uuidString: CommandLine.arguments[4]) else { exit(64) }
                let callID = ToolCallID(rawValue: CommandLine.arguments[5])
                let marker = try await journal.admissionRejection(
                    sessionID: sessionID, runID: runID, callID: callID)
                let messages = try await journal.readMessages(sessionID: sessionID)
                let pairs = messages.contains {
                    if case .assistant(_, let calls) = $0.message { return calls.contains { $0.id == callID } }
                    return false
                } && messages.contains {
                    if case .tool(let result) = $0.message { return result.callID == callID && result.isError }
                    return false
                }
                let line = "marker=\(marker?.toolName ?? "none") paired=\(pairs) messages=\(messages.count) "
                    + "pending=\(try await journal.pendingMutations(sessionID: sessionID).count)\n"
                FileHandle.standardOutput.write(Data(line.utf8))
                try await journal.close()
                exit(0)
            case "fork-window":
                try await holdForkWindow(journal: journal)
                exit(0)
            case "hold":
                FileHandle.standardOutput.write(Data("READY\n".utf8))
                while true { try await Task.sleep(for: .seconds(1)) }
            case "commit-and-exit":
                let session = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
                _ = try await journal.appendCheckpoint([
                    .checkpoint(history: [.user([.text("committed before process exit")])], steeringIDs: [])
                ], sessionID: session, runID: UUID(), durability: .durable)
                exit(0)
            case "queue-write-and-wait":
                guard CommandLine.arguments.count == 4 else { exit(64) }
                let file = URL(fileURLWithPath: CommandLine.arguments[3])
                let provider = QueueProcessProvider()
                let model = ModelID(provider: "queue-process", name: "fixed")
                let agent = try Agent(model: model, provider: provider)
                let id = UUID(uuidString: "00000000-0000-0000-0000-000000000321")!
                let session = try agent.makeSession(id: id, journal: journal)
                let dispatch = try await session.startFollowUpDispatch(
                    policy: .init(maxModelTurns: 3, maxToolCalls: 3, runTimeout: .seconds(120)),
                    resolver: QueueProcessResolver(session: session, provider: provider, file: file))
                try await dispatch.waitForDrain()
                exit(0)
            default: exit(64)
            }
        } catch AgentJournalError.storeInUse {
            exit(42)
        } catch {
            FileHandle.standardError.write(Data(String(describing: error).utf8))
            exit(1)
        }
    }
}

private struct QueueProcessProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-process", capabilities: [.streaming, .multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "child", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
                return
            }
            let call = ToolCall(id: .init(rawValue: "child-write"), name: QueueProcessWrite.name,
                                argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
            try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}

private struct QueueProcessResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: QueueProcessProvider
    let file: URL
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let scope = try await session.bindCapabilities(identity: "child", version: "1",
            backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "queue.process", id: "B"))],
            tools: [.init(id: "write", version: "1", tool: try QueueProcessWrite(file: file))])
        return .init(model: try AgentModelBinding(profileID: "child", profileRevision: "1",
            model: .init(provider: "queue-process", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope)
    }
}

private struct QueueProcessWrite: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "queue_process_write"
    static let description = "Write a disposable fixture file and wait for process termination"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let policy: ToolPolicy
    init(file: URL) throws {
        self.file = file
        policy = try .mutation(timeout: .seconds(60), authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "queue.process", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "queue.process", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        FileHandle.standardOutput.write(Data("EFFECT-WRITTEN\n".utf8))
        while true { try await Task.sleep(for: .seconds(30)) }
    }
}

private struct AuditProcessProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "queue-process", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "audit-child", model: request.model)
            try emit(.responseStarted(info))
            if request.messages.last?.role == .tool {
                try emit(.textDelta("done")); try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
                return
            }
            let call = ToolCall(id: .init(rawValue: "audit-child-write"), name: AuditProcessWrite.name,
                argumentsJSON: #"{"id":"A"}"#, completeness: .complete)
            try emit(.toolCallStarted(call.id, name: call.name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}

private struct AuditProcessAuthorizer: AgentAuthorizer {
    let deny: Bool
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        .init(request: request, outcome: deny ? .deny : .allow,
            subject: .init(issuer: "child-host", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "process-policy", version: "1"), validFor: .seconds(120), reasonCode: "fixture")
    }
}

private struct AuditProcessWrite: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "audit_process_write"
    static let description = "Write a disposable fixture file through the real AgentLoop"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let file: URL; let hold: Bool
    let policy = try! ToolPolicy.mutation(timeout: .seconds(120), authorization: .notRequired, evidence: .none)
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "audit.process", id: input.id))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "audit.process", id: input.id)], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        try Data("effect\n".utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
        if hold {
            FileHandle.standardOutput.write(Data("AUDIT-EFFECT-WRITTEN\n".utf8))
            while true { try await Task.sleep(for: .seconds(60)) }
        }
        return .init(output: "effect", receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "audit.process", id: input.id)], revision: "1"))
    }
}

private struct NoEffectProcessProvider: ModelProvider {
    let large: Bool
    let descriptor = ModelProviderDescriptor(id: "no-effect-process", capabilities: [.streaming, .multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            if request.messages.last?.role == .tool {
                // The next dispatch is the barrier proving complete publication; SIGKILL is not power loss.
                FileHandle.standardOutput.write(Data("NO-EFFECT-COMMITTED\n".utf8))
                while true { try await Task.sleep(for: .seconds(60)) }
            }
            let info = ResponseInfo(id: "no-effect", model: request.model)
            let call = ToolCall(id: .init(rawValue: "no-effect"), name: "no_effect_process", argumentsJSON: large ? "{\"content\":\"" + String(repeating: "x", count: 250_000) + "\"}" : "{}", completeness: .complete)
            try emit(.responseStarted(info)); try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON)); try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}
private struct NoEffectProcessTool: RuntimeAgentTool {
    let runtimeDefinition = ModelToolDefinition(name: "no_effect_process", description: "Synthetic confirmed conflict",
        inputSchema: ToolSchema.object(properties: ["content": .string]).json, outputSchema: ToolSchema.string.json)
    let policy = try! ToolPolicy.mutation(authorization: .notRequired, evidence: .none, recoverableErrors: .confirmedNoEffect)
    let hold: Bool
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "fixture", id: "file")]) }
    func authorizationBinding(for input: JSONValue) throws -> ToolAuthorizationBinding {
        .init(implementationVersion: "1", backend: .init(instanceID: "local", version: "1", accountID: "fixture", credentialGeneration: "1"))
    }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        let error = try context.confirmNoEffect(receipt: .init(operationID: context.idempotencyKey!, status: .failed, confirmedTargets: [], failure: .conflict),
            error: .init(code: "conflict", message: "Synthetic conflict"), wholeOperationHadNoEffect: true, noOutstandingEffects: true,
            basis: "whole operation rejected before effect")
        FileHandle.standardOutput.write(Data("NO-EFFECT-PREPARED session=\(context.sessionID) run=\(context.runID)\n".utf8))
        if hold { while true { try await Task.sleep(for: .seconds(60)) } }
        throw error
    }
}
