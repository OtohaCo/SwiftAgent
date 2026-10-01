import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation

@main public struct ConfirmedNoEffectFixture {
    public static func main() async {
        do {
        let mode = CommandLine.arguments.dropFirst().first ?? "corrected"
        let bytes = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 143_000 : 143_000
        let stable = CommandLine.arguments.count <= 3 || CommandLine.arguments[3] != "default-id"
        let counts = try await runFixture(mode: mode, contentBytes: bytes, stableOperationID: stable)
        print(String(decoding: try JSONEncoder().encode(counts), as: UTF8.self))
        } catch {
            print("FAILED: \(String(reflecting: error))")
            exit(1)
        }
    }

    /// Public SDK consumer; never directly calls execute or constructs an internal ledger.
    public static func runFixture(mode: String = "corrected", contentBytes: Int = 143_000, stableOperationID: Bool = true) async throws -> [String: Int] {
        guard ["corrected", "default", "unknown", "large", "large-audit"].contains(mode) else { throw FixtureFailure.invalidMode }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftAgent-no-effect-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let large = mode.hasPrefix("large")
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "fixture-no-effect",
            policy: large ? try .init(segmentBytes: 1024, maxWorkBytes: 16 * 1024 * 1024, maxSegmentBatches: 2) : .default, supportsConfirmedNoEffect: true)
        let file = directory.appendingPathComponent("controlled.txt")
        let counter = Counter(); let authorizer = HostAuthorizer()
        let provider = FixtureProvider(counter: counter, journal: journal, content: large ? String(repeating: "x", count: contentBytes) : nil)
        let agent = try Agent(model: .init(provider: "fixture", name: "controlled"), provider: provider,
            tools: [ControlledWrite(file: file, counter: counter, mode: mode)],
            configuration: .init(authorization: .init(mode: mode == "large" ? .legacy : .requiredAudit, authorizer: authorizer,
                identity: .init(securityDomain: "fixture", subjectID: "synthetic-user", actingSubjectID: "fixture-agent",
                    backend: .init(instanceID: "temporary-file", version: "1", accountID: "fixture", credentialGeneration: "1")))))
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("Write the controlled file", operationID: stableOperationID ? "stable-business-operation" : nil)
        let result: AgentLoopResult?
        do { result = try await run.wait() }
        catch {
            print("fixture failure: \(String(reflecting: error))")
            guard mode != "corrected" && mode != "large" else {
                print("provider=\(await counter.values["providerRequests"]!) executor=\(await counter.values["executorEntered"]!) pending=\(try await journal.pendingMutations().map(\.state))")
                try await run.waitForDrain()
                try await journal.close()
                throw error
            }; result = nil
        }
        try await run.waitForDrain()
        let proof = try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A"))
        let pending = try await journal.pendingMutations().count
        let history = try await session.conversationSnapshot()
        let facts = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true)
        let aborted = facts.records.filter { if case .result(let r) = $0.fact { return r.kind == .noEffectConfirmation && r.settlementSource == .executor }; return false }.count
        let settled = facts.records.filter { if case .result(let r) = $0.fact { return r.kind == .settlement }; return false }.count
        if mode == "large-audit" && contentBytes > 65_536 {
            guard facts.records.contains(where: {
                if case .proposal(let p) = $0.fact { return p.stage == .received && p.payloadTruncated && !p.reconstructable && p.normalizedArguments == nil && p.originalUTF8Bytes == contentBytes + 14 && (p.rawArgumentsJSON?.utf8.count ?? Int.max) <= 4096 }
                return false
            }), facts.records.contains(where: {
                if case .disposition(let d) = $0.fact { return d.state == .notExecuted && d.reasonCode == "proposal_too_large" }
                return false
            }) else { throw FixtureFailure.badCounts }
        }
        var counts = await counter.values
        counts["enterpriseAuthorization"] = await authorizer.calls
        counts["abort"] = aborted; counts["settlement"] = settled; counts["Receipt"] = result?.receipts.count ?? 0
        var intents = 0
        for callID in ["A", "B"] {
            if try await journal.mutationStatus(sessionID: session.id, runID: run.id, callID: .init(rawValue: callID)) != nil { intents += 1 }
        }
        counts["intent"] = intents
        let a = try await journal.mutationStatus(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A"))
        let b = try await journal.mutationStatus(sessionID: session.id, runID: run.id, callID: .init(rawValue: "B"))
        counts["abort"] = a?.state == .aborted ? 1 : 0
        counts["settlement"] = b?.state == .settled ? 1 : 0
        counts["proofBytes"] = try proof?.executorProof.map { try JSONEncoder().encode($0).count } ?? 0
        counts["canonicalBytes"] = await counter.values["canonicalBytes"] ?? 0
        counts["operationKeyBytes"] = await counter.values["operationKeyBytes"] ?? 0
        counts["invocations"] = Set(facts.records.map { $0.links.invocationID }).count
        counts["authorizationApplied"] = facts.records.filter { if case .disposition(let d) = $0.fact { return d.state == .dispatchPrepared }; return false }.count
        counts["finalAdmission"] = facts.records.filter { if case .disposition(let d) = $0.fact { return d.state == .runtimeAdmitted }; return false }.count
        counts["pending"] = pending; counts["proof"] = proof == nil ? 0 : 1
        if mode == "corrected" || mode == "large" {
            guard counts["executorEntered"] == 2, counts["fileEffects"] == 1, counts["abort"] == 1, counts["settlement"] == 1,
                  try String(contentsOf: file, encoding: .utf8) == "written once" else { throw FixtureFailure.badCounts }
        } else if mode == "large-audit" && contentBytes > 65_536 {
            guard counts["executorEntered"] == 0, counts["providerRequests"] == 1, pending == 0, proof == nil else { throw FixtureFailure.badCounts }
        } else {
            guard counts["executorEntered"] == 1, counts["fileEffects"] == 0, pending == 1, proof == nil else { throw FixtureFailure.badCounts }
        }
        if large {
            for _ in 0..<32 { if try await journal.requestMaintenance()?.sealedSegments == 0 { break } }
            guard try await journal.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == proof else { throw FixtureFailure.badRecovery }
            counts["maintenanceGeneration"] = Int(try await journal.storeStatus()?.layoutGeneration ?? 0)
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard try await reopened.executorNoEffectConfirmation(sessionID: session.id, runID: run.id, callID: .init(rawValue: "A")) == proof,
              try await reopened.latestCheckpoint(sessionID: session.id)?.history == history.messages else { throw FixtureFailure.badRecovery }
        try await reopened.close()
        return counts
    }
}
private enum FixtureFailure: Error { case invalidMode, badCounts, badRecovery, uncertain }
private actor Counter {
    var invocation: ToolContext?
    func entered(_ context: ToolContext) { invocation = context }
    var values = ["providerRequests": 0, "toolAuthorization": 0, "executorEntered": 0, "noEffectConfirmation": 0, "fileEffects": 0]
    func set(_ key: String, _ value: Int) { values[key] = value }
    func count(_ key: String) -> Int { values[key, default: 0] += 1; return values[key]! }
}
private actor HostAuthorizer: AgentAuthorizer {
    var calls = 0
    func decide(_ request: AuthorizationRequest) async throws -> AuthorizationDecision {
        calls += 1
        return .init(request: request, outcome: .allow,
            subject: .init(issuer: "fixture-host", subjectID: "exact-action-rule", type: .automatedPolicy),
            policy: .init(id: "fixture-only", version: "1"), validFor: .seconds(30), reasonCode: "controlled")
    }
}
private struct FixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.multiTurn, .tools])
    let counter: Counter
    let journal: AgentJournal
    let content: String?
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await counter.count("providerRequests")
            let info = ResponseInfo(id: "fixture", model: request.model)
            try emit(.responseStarted(info))
            if turn < 3 {
                let call = ToolCall(id: .init(rawValue: turn == 1 ? "A" : "B"), name: "controlled_write", argumentsJSON: (turn == 2 && (content?.utf8.count ?? 0) > 256_000 ? "written once" : content).map { String(decoding: try! JSONEncoder().encode(JSONValue.object(["content": .string($0)])), as: UTF8.self) } ?? "{}", completeness: .complete)
                if turn == 2 {
                    guard case .tool(let result)? = request.messages.last, result.isError, result.callID.rawValue == "A",
                          let invocation = await counter.invocation,
                          try await journal.pendingMutations().isEmpty,
                          try await journal.executorNoEffectConfirmation(sessionID: invocation.sessionID, runID: invocation.runID, callID: invocation.callID) != nil,
                          try await journal.latestCheckpoint(sessionID: invocation.sessionID)?.history == request.messages,
                          await counter.values["fileEffects"] == 0 else { throw FixtureFailure.badRecovery }
                }
                try emit(.toolCallStarted(call.id, name: call.name)); try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call)); try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else { try emit(.textDelta("done")); try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn))) }
        }
    }
}
private struct ControlledWrite: RuntimeAgentTool {
    let runtimeDefinition = ModelToolDefinition(name: "controlled_write", description: "Controlled temporary file only",
        inputSchema: ToolSchema.object(properties: ["content": .string]).json, outputSchema: ToolSchema.string.json)
    var policy: ToolPolicy { try! .mutation(evidence: .none, recoverableErrors: mode == "default" ? .failClosed : .confirmedNoEffect) }
    let file: URL; let counter: Counter; let mode: String
    func receiptExpectation(for input: JSONValue) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "fixture", id: "controlled")]) }
    func authorizationBinding(for input: JSONValue) throws -> ToolAuthorizationBinding {
        .init(implementationVersion: "fixture-v1", backend: .init(instanceID: "temporary-file", version: "1", accountID: "fixture", credentialGeneration: "1"))
    }
    func authorize(_ input: JSONValue, context: ToolContext) async throws -> ToolAuthorization { _ = await counter.count("toolAuthorization"); return .allowed }
    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        let attempt = await counter.count("executorEntered")
        await counter.entered(context)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let canonical = try encoder.encode(input)
        if attempt == 1 {
            await counter.set("canonicalBytes", canonical.count)
            await counter.set("operationKeyBytes", context.idempotencyKey!.utf8.count)
        }
        if context.idempotencyKey!.hasPrefix("stable-business-operation/") {
            guard context.idempotencyKey!.hasSuffix(String(decoding: canonical, as: UTF8.self)) else { throw FixtureFailure.badCounts }
        }
        if attempt == 1 {
            if mode == "unknown" { throw FixtureFailure.uncertain }
            guard !FileManager.default.fileExists(atPath: file.path) else { throw FixtureFailure.badCounts }
            let oversize: Bool
            if case .object(let fields) = input, case .string(let content)? = fields["content"] { oversize = content.utf8.count > 256_000 } else { oversize = false }
            let confirmation = try context.confirmNoEffect(receipt: .init(operationID: context.idempotencyKey!, status: .failed,
                confirmedTargets: [], failure: oversize ? .rejected : .conflict), error: .init(code: oversize ? "content_too_large" : "conflict", message: oversize ? "Content exceeds the Host limit; submit a smaller file." : "Version condition refused before any write."),
                wholeOperationHadNoEffect: true, noOutstandingEffects: true, basis: "fixture whole operation: version check before any write")
            guard confirmation.receipt.operationID == context.idempotencyKey else { throw FixtureFailure.badCounts }
            _ = await counter.count("noEffectConfirmation")
            throw confirmation
        }
        try Data("written once".utf8).write(to: file); _ = await counter.count("fileEffects")
        return .init(output: .string("written"), receipt: .init(operationID: context.idempotencyKey!, status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture", id: "controlled")]))
    }
}
