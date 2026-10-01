import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main struct JournalReaderCompatibility {
    static func main() async {
        guard CommandLine.arguments.count == 4,
              let sessionID = UUID(uuidString: CommandLine.arguments[3]) else { exit(64) }
        let mode = CommandLine.arguments[1]
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let journal: AgentJournal
            switch mode {
            #if NO_EFFECT_RUNTIME
            case "create-no-effect-empty", "create-no-effect":
                journal = try AgentIncrementalJournal.create(at: directory,
                    operationDomain: "reader-matrix", supportsConfirmedNoEffect: true)
            #endif
            case "create-default":
                journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "reader-matrix")
            #if NEW_RUNTIME
            case "create-capable-without-rejection":
                journal = try AgentIncrementalJournal.create(at: directory,
                    operationDomain: "reader-matrix", supportsAdmissionRejections: true)
            case "create-rejection":
                journal = try AgentIncrementalJournal.create(at: directory,
                    operationDomain: "reader-matrix", supportsAdmissionRejections: true)
            #endif
            #if AUDIT_RUNTIME
            case "create-audit-empty", "create-audit-denial":
                journal = try AgentIncrementalJournal.create(at: directory,
                    operationDomain: "reader-matrix", supportsAuthorizationAudit: true)
            #endif
            default:
                journal = try AgentIncrementalJournal.open(at: directory)
            }
            switch mode {
            case "create-default", "append", "create-capable-without-rejection":
                let agent = try Agent(model: .init(provider: "reader-matrix", name: "script"),
                                      provider: MatrixProvider())
                let run = try await agent.makeSession(id: sessionID, journal: journal)
                    .run("ordinary \(mode)")
                _ = try await run.wait()
                try await run.waitForDrain()
            #if NEW_RUNTIME
            case "create-rejection":
                let agent = try Agent(model: .init(provider: "reader-matrix", name: "script"),
                    provider: MatrixProvider(), tools: [try MatrixSearch(), try MatrixCommit()],
                    configuration: .init(preAdmissionReplanning:
                        .evidenceRejection(toolNames: [MatrixCommit.name])))
                let run = try await agent.makeSession(id: sessionID, journal: journal)
                    .run("rejection", operationID: "matrix-operation")
                _ = try await run.wait()
                try await run.waitForDrain()
            #endif
            #if AUDIT_RUNTIME
            case "create-audit-empty": break
            #if NO_EFFECT_RUNTIME
            case "create-no-effect-empty": break
            case "create-no-effect":
                let agent = try Agent(model: .init(provider: "reader-matrix", name: "script"),
                    provider: MatrixNoEffectProvider(), tools: [MatrixNoEffectTool()])
                let run = try await agent.makeSession(id: sessionID, journal: journal).run("no effect", operationID: "matrix-op")
                _ = try await run.wait(); try await run.waitForDrain()
            #endif
            case "create-audit-denial":
                let agent = try Agent(model: .init(provider: "reader-matrix", name: "script"),
                    provider: MatrixAuditProvider(), tools: [try MatrixSearch()],
                    configuration: .init(authorization: .init(mode: .requiredAudit, authorizer: MatrixDenyAuthorizer(),
                        identity: .init(securityDomain: "matrix", subjectID: "user", actingSubjectID: "agent",
                            backend: .init(instanceID: "fixture", version: "1", accountID: "local", credentialGeneration: "1")))))
                let run = try await agent.makeSession(id: sessionID, journal: journal).run("denied")
                do { _ = try await run.wait(); throw AgentAuthorizationError.invalidDecision }
                catch AgentAuthorizationError.authorizationDenied { }
                try await run.waitForDrain()
            #endif
            #if COMPACT_NO_EFFECT_RUNTIME
            case "exercise-no-effect-small", "exercise-no-effect-large":
                let large = mode == "exercise-no-effect-large"
                let counter = MatrixExecutorCounter()
                let agent = try Agent(model: .init(provider: "reader-matrix", name: "script"),
                    provider: MatrixNoEffectProvider(large: large, callID: mode), tools: [MatrixNoEffectTool(counter: counter)])
                let run = try await agent.makeSession(id: sessionID, journal: journal).run("no effect", operationID: "matrix-op")
                if large {
                    do { _ = try await run.wait(); throw AgentJournalError.invalidRecord }
                    catch ToolNoEffectError.payloadTooLarge { }
                    try await run.waitForDrain()
                    guard await counter.executions == 0, try await journal.pendingMutations().isEmpty else { throw AgentJournalError.invalidRecord }
                    print("v1-large=refused-before-executor pending=0")
                } else { _ = try await run.wait(); try await run.waitForDrain() }
            #endif
            case "maintain":
                for _ in 0..<8 { _ = try await journal.requestMaintenance() }
            case "inspect": break
            default: exit(64)
            }
            #if NO_EFFECT_RUNTIME
            let noEffect = try await journal.mutationStatus(identity: "matrix-op/matrix_no_effect/{}")
            print("noEffectVersion=\(noEffect?.abortConfirmation?.executorProof?.version ?? 0)")
            #endif
            let checkpoint = try await journal.latestCheckpoint(sessionID: sessionID)
            let messages = try await journal.readMessages(sessionID: sessionID)
            let pending = try await journal.pendingMutations(sessionID: sessionID)
            let rejectedIdentity = #"matrix-operation/matrix_commit/{"id":"X"}"#
            let rejectedMutation = try await journal.mutationStatus(identity: rejectedIdentity)
            let maintenance = try await journal.maintenanceStatus()
            let storeID = await journal.storeIdentity()?.storeID.uuidString ?? "none"
            print("open=pass storeID=\(storeID) checkpoint=\(checkpoint?.history.count ?? 0) "
                + "messages=\(messages.count) pending=\(pending.count) "
                + "rejectedMutation=\(rejectedMutation?.state.rawValue ?? "none") "
                + "maintenance=\(maintenance == nil ? "none" : "readable") "
                + "paired=\(messages.contains { if case .tool(let result) = $0.message { return result.isError }; return false })")
            #if AUDIT_RUNTIME
            if journal.supportsAuthorizationAudit {
                let page = try await journal.auditRecords(includeRestrictedPayload: true)
                print("audit=\(page.records.count) deny=\(page.records.filter { if case .authorization(let a) = $0.fact { return a.decision?.outcome == .deny }; return false }.count)")
            }
            #endif
            try await journal.close()
        } catch {
            print("open/operation=fail \(String(reflecting: error))")
            exit(1)
        }
    }
}

private struct MatrixProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "reader-matrix", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "matrix", model: request.model)
            try emit(.responseStarted(info))
            #if NEW_RUNTIME
            let call: ToolCall?
            if request.messages.last == .user([.text("rejection")]) {
                call = .init(id: .init(rawValue: "search"), name: MatrixSearch.name,
                             argumentsJSON: "{}", completeness: .complete)
            } else if case .tool(let result)? = request.messages.last, result.callID.rawValue == "search" {
                call = .init(id: .init(rawValue: "invalid-X"), name: MatrixCommit.name,
                             argumentsJSON: #"{"id":"X"}"#, completeness: .complete)
            } else { call = nil }
            if let call {
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
                return
            }
            #endif
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}

#if NEW_RUNTIME
private struct MatrixSearch: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "matrix_search"
    static let description = "Find fixture candidate"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        .init(output: "A", evidence: [.init(namespace: "matrix", id: "A", issuedAt: Date())])
    }
}

private struct MatrixCommit: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "matrix_commit"
    static let description = "Do not execute X"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.mutation(authorization: .notRequired)
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "matrix", id: input.id))]
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "matrix", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "matrix", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        throw AgentJournalError.invalidRecord
    }
}
#endif

#if AUDIT_RUNTIME
private struct MatrixAuditProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "reader-matrix", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "audit-matrix", model: request.model)
            let call = ToolCall(id: .init(rawValue: "denied-read"), name: MatrixSearch.name, argumentsJSON: "{}", completeness: .complete)
            try emit(.responseStarted(info)); try emit(.toolCallStarted(call.id, name: call.name))
            try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON)); try emit(.toolCallCompleted(call))
            try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
        }
    }
}
private struct MatrixDenyAuthorizer: AgentAuthorizer {
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        .init(request: request, outcome: .deny, subject: .init(issuer: "matrix", subjectID: "rule", type: .automatedPolicy),
            policy: .init(id: "matrix", version: "1"), validFor: .seconds(30), reasonCode: "fixture")
    }
}
#endif

#if NO_EFFECT_RUNTIME
private struct MatrixNoEffectProvider: ModelProvider {
    var large = false
    var callID = "A"
    let descriptor = ModelProviderDescriptor(id: "reader-matrix", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "no-effect", model: request.model)
            try emit(.responseStarted(info))
            if case .user? = request.messages.last {
                let call = ToolCall(id: .init(rawValue: callID), name: "matrix_no_effect", argumentsJSON: large ? "{\"content\":\"" + String(repeating: "x", count: 143_000) + "\"}" : "{}", completeness: .complete)
                try emit(.toolCallStarted(call.id, name: call.name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("done")); try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
            }
        }
    }
}
private actor MatrixExecutorCounter {
    var executions = 0
    func entered() { executions += 1 }
}
private struct MatrixNoEffectTool: RuntimeAgentTool {
    var counter = MatrixExecutorCounter()
    let runtimeDefinition = ModelToolDefinition(name: "matrix_no_effect", description: "Reject before writing", inputSchema: ToolSchema.object(properties: ["content": .string]).json, outputSchema: ToolSchema.string.json)
    let policy = try! ToolPolicy.mutation(evidence: .none, recoverableErrors: .confirmedNoEffect)
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "matrix", id: "file")]) }
    func authorizationBinding(for input: JSONValue) throws -> ToolAuthorizationBinding {
        .init(implementationVersion: "1", backend: .init(instanceID: "fixture", version: "1", accountID: "local", credentialGeneration: "1"))
    }
    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization { .allowed }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        await counter.entered()
        throw try context.confirmNoEffect(receipt: .init(operationID: context.idempotencyKey!, status: .failed, confirmedTargets: [], failure: .rejected),
            error: .init(code: "refused", message: "No write"), wholeOperationHadNoEffect: true, noOutstandingEffects: true, basis: "checked before writing")
    }
}
#endif
