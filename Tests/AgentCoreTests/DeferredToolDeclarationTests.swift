import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// A Run's capability binding can hold deferred tools: bound and callable once declared, but not sent
/// to the model from the start. A tool result (a Host's "find tools" tool) declares some of them, and
/// the next model request of the same Run carries their definitions.
struct DeferredToolDeclarationTests {
    @Test func deferredToolsAreBoundButNotOfferedToTheModel() async throws {
        let fetches = DeclarationLog()
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: try webTools(fetches: fetches))

        #expect(binding.info.tools.map(\.name) == ["find_tools", "web_fetch"])
        #expect(binding.info.tools.map(\.exposure) == [.declared, .deferred])
        _ = try await session.run("go", capabilities: binding).wait()
        #expect(await provider.log.requests.map { $0.tools.map(\.name) } == [["find_tools"]])
    }

    @Test func aToolResultDeclaresDeferredToolsForTheNextRequest() async throws {
        let fetches = DeclarationLog()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: toolResponse(request, [declarationCall("find-1", "find_tools", #"{"query":"read a page"}"#)])
            case 2: toolResponse(request, [declarationCall("fetch-1", "web_fetch", #"{"url":"https://example.com"}"#)])
            default: textResponse(request, "done")
            }
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: try webTools(fetches: fetches))

        let result = try await session.run("Read example.com", capabilities: binding, budget: try testBudget()).wait()

        #expect(result.outcome == .completed)
        #expect(await provider.log.requests.map { $0.tools.map(\.name) } == [
            ["find_tools"], ["find_tools", "web_fetch"], ["find_tools", "web_fetch"],
        ])
        #expect(await fetches.entries == ["https://example.com"])
    }

    /// Not declared is not callable: such a call ends the Run exactly as a call naming no bound tool.
    @Test func aCallToADeferredToolBeforeItIsDeclaredFailsAsAnUnknownToolDoes() async throws {
        let call = declarationCall("fetch-early", "web_fetch", #"{"url":"https://example.com"}"#)
        var terminals: [AgentEvent?] = []
        for registered in [true, false] {
            let fetches = DeclarationLog()
            let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
            let session = try Agent(model: fixtureModel, provider: provider).makeSession()
            let tools = try webTools(fetches: fetches)
            let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
                backendVersion: "1", allowedResources: [.global], tools: registered ? tools : [tools[0]])
            let run = try await session.run("go", capabilities: binding, budget: try testBudget())
            let events = await collectEvents(run.events)
            await #expect(throws: ToolRegistryError.unknownTool("web_fetch")) { _ = try await run.wait() }
            #expect(!events.contains { if case .toolStarted = $0 { true } else { false } })
            #expect(await fetches.entries.isEmpty)
            #expect(await provider.log.requests.count == 1)
            terminals.append(events.last)
        }
        #expect(terminals[0] == .runFinished(.failed(.toolRegistry(.unknownTool("web_fetch")))))
        #expect(terminals[0] == terminals[1])
    }

    @Test func declaringAToolTheRunDoesNotHaveFailsTheCall() async throws {
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [declarationCall("find-1", "find_tools", #"{"query":"x"}"#)])
                : textResponse(request, "unexpected")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: [
                AgentCapabilityTool(id: "find_tools", version: "1", tool: try FindToolsTool(declares: ["web_fetch", "not_bound"])),
                AgentCapabilityTool(id: "web_fetch", version: "1", tool: try WebFetchTool(log: DeclarationLog()), exposure: .deferred),
            ])
        let run = try await session.run("go", capabilities: binding, budget: try testBudget())
        await #expect(throws: ToolRegistryError.unknownTool("not_bound")) { _ = try await run.wait() }
        #expect(await provider.log.requests.count == 1)
    }

    @Test func theTokenEstimatorSeesOnlyDeclaredTools() async throws {
        let estimator = RecordingToolEstimator()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: toolResponse(request, [declarationCall("find-1", "find_tools", #"{"query":"read a page"}"#)])
            default: textResponse(request, "done")
            }
        }
        let model = try AgentModelBinding(profileID: "small", profileRevision: "1", model: fixtureModel, provider: provider,
            deployment: try .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            tokenBudget: try AgentContextTokenBudget(maximumContextTokens: 10_000, reservedOutputTokens: 100, estimator: estimator))
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: try webTools(fetches: DeclarationLog()))

        _ = try await session.run("go", capabilities: binding, using: model, budget: try testBudget()).wait()

        #expect(await estimator.toolNames == [["find_tools"], ["find_tools", "web_fetch"]])
    }

    /// A mutation tool declared mid-run keeps durable intent, its Receipt, and settled replay; the next
    /// Run starts again from its own binding's declarations.
    @Test func aMutationToolDeclaredMidRunKeepsIntentReceiptAndReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-mutation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "deferred-tools")
        let updates = DeclarationLog()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1, 4: toolResponse(request, [declarationCall("find-\(turn)", "find_tools", #"{"query":"rename"}"#)])
            case 2, 5: toolResponse(request, [declarationCall("rename-\(turn)", "rename_note", #"{"id":"note-1"}"#)])
            default: textResponse(request, "done")
            }
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        func bind() async throws -> AgentCapabilityBinding {
            try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
                backendVersion: "1", allowedResources: [.global, .named(.init(namespace: "notes", id: "note-1"))], tools: [
                    AgentCapabilityTool(id: "find_tools", version: "1", tool: try FindToolsTool(declares: ["rename_note"])),
                    AgentCapabilityTool(id: "rename_note", version: "1", tool: try RenameNoteTool(log: updates), exposure: .deferred),
                ])
        }

        let first = try await session.run("Rename", capabilities: try await bind(), budget: try testBudget(),
                                          operationID: "rename-note-1")
        let firstResult = try await first.wait()
        try await first.waitForDrain()
        let receipt = try #require(firstResult.receipts.first)
        #expect(receipt.effect == .mutation)
        let status = try await journal.mutationStatus(sessionID: session.id, runID: first.id, callID: .init(rawValue: "rename-2"))
        #expect(status?.state == .settled)
        #expect(status?.receipt == receipt.receipt)
        #expect(try await journal.pendingMutations().isEmpty)

        let retry = try await session.run("Rename again", capabilities: try await bind(), budget: try testBudget(),
                                          operationID: "rename-note-1")
        let retryResult = try await retry.wait()
        try await retry.waitForDrain()
        #expect(retryResult.receipts.first?.receipt == receipt.receipt, "settled replay returns the original Receipt")
        #expect(await updates.entries == ["note-1"], "the executor ran once")
        let requests = await provider.log.requests.map { $0.tools.map(\.name) }
        #expect(requests == [
            ["find_tools"], ["find_tools", "rename_note"], ["find_tools", "rename_note"],
            ["find_tools"], ["find_tools", "rename_note"], ["find_tools", "rename_note"],
        ])
        try await journal.close()
    }

    /// Declarations are not journaled: a conversation restored after a restart continues with a new
    /// binding, whose first request again carries only the tools it declares.
    @Test func aRestoredConversationStartsFromTheNewBindingsDeclarations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deferred-restart-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let fetch = declarationCall("fetch-1", "web_fetch", #"{"url":"https://example.com"}"#)
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: toolResponse(request, [declarationCall("find-1", "find_tools", #"{"query":"read a page"}"#)])
            case 2: toolResponse(request, [fetch])
            default: textResponse(request, "done")
            }
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "deferred-tools")
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let first = try await session.run("Read", capabilities: try await session.bindCapabilities(identity: "project",
            version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global],
            tools: try webTools(fetches: DeclarationLog())), budget: try testBudget())
        _ = try await first.wait()
        try await first.waitForDrain()
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let restored = try agent.makeSession(id: sessionID, journal: reopened)
        let second = try await restored.run("Again", capabilities: try await restored.bindCapabilities(identity: "project",
            version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global],
            tools: try webTools(fetches: DeclarationLog())), budget: try testBudget())
        _ = try await second.wait()
        try await second.waitForDrain()

        let last = try #require(await provider.log.requests.last)
        #expect(last.tools.map(\.name) == ["find_tools"])
        #expect(last.messages.contains { if case .assistant(_, let calls) = $0 { calls.contains(fetch) } else { false } },
                "the earlier call stays in the conversation")
        try await reopened.close()
    }

    /// Under required audit an undeclared call is recorded and rejected as an unknown tool is: the
    /// proposal stays, nothing is authorized, nothing runs.
    @Test func requiredAuditRejectsAnUndeclaredCallAsAnUnknownTool() async throws {
        var reasons: [[String?]] = []
        for name in [AuditExecutionTool.name, "does_not_exist"] {
            let directory = auditTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "deferred-audit",
                                                             supportsAuthorizationAudit: true)
            let authorizer = AuditTestAuthorizer(), probe = AuditExecutionProbe()
            let call = declarationCall("write-early", name, #"{"id":"A"}"#)
            let session = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in toolResponse(request, [call]) },
                configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
            let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
                backendVersion: "1", allowedResources: [.named(.init(namespace: "audit.fixture", id: "A"))], tools: [
                    AgentCapabilityTool(id: "find_tools", version: "1", tool: try FindToolsTool(declares: [AuditExecutionTool.name])),
                    AgentCapabilityTool(id: "audit_write", version: "1", tool: try AuditExecutionTool(probe: probe), exposure: .deferred),
                ])
            let run = try await session.run("write", capabilities: binding)
            await #expect(throws: ToolRegistryError.unknownTool(name)) { _ = try await run.wait() }
            try await run.waitForDrain()
            let records = try await journal.auditRecords(matching: .init(runID: run.id), includeRestrictedPayload: true).records
            #expect(records.contains { if case .proposal(let p) = $0.fact { p.rawArgumentsJSON == call.argumentsJSON } else { false } })
            reasons.append(records.compactMap { if case .disposition(let d) = $0.fact { d.reasonCode } else { nil } })
            #expect(await authorizer.requests.isEmpty)
            #expect(await probe.executorEntered == 0)
            try await journal.close()
        }
        #expect(reasons[0] == ["preparation_rejected"])
        #expect(reasons[0] == reasons[1])
    }

    /// Once declared, an audited mutation is authorized, admitted and settled as a declared one is.
    @Test func requiredAuditAuthorizesAMutationDeclaredMidRun() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "deferred-audit",
                                                         supportsAuthorizationAudit: true)
        let authorizer = AuditTestAuthorizer(), probe = AuditExecutionProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: toolResponse(request, [declarationCall("find-1", "find_tools", #"{"query":"write"}"#)])
            case 2: toolResponse(request, [declarationCall("write-1", AuditExecutionTool.name, #"{"id":"A"}"#)])
            default: textResponse(request, "done")
            }
        }
        let session = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(authorization: auditTestConfiguration(authorizer: authorizer))).makeSession(journal: journal)
        let binding = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global, .named(.init(namespace: "audit.fixture", id: "A"))], tools: [
                AgentCapabilityTool(id: "find_tools", version: "1", tool: try FindToolsTool(declares: [AuditExecutionTool.name])),
                AgentCapabilityTool(id: "audit_write", version: "1", tool: try AuditExecutionTool(probe: probe), exposure: .deferred),
            ])
        let run = try await session.run("write", capabilities: binding, budget: try testBudget())
        let result = try await run.wait()
        try await run.waitForDrain()

        #expect(result.receipts.map(\.effect) == [.mutation])
        #expect(await probe.executorEntered == 1)
        #expect(await probe.domainChecks == 1)
        #expect(await authorizer.requests.map(\.toolDefinition.name) == ["find_tools", AuditExecutionTool.name])
        let records = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(records.contains { if case .result(let r) = $0.fact { r.kind == .settlement } else { false } })
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func capabilityInfoKeepsItsEncodingWhenNoToolIsDeferred() async throws {
        let session = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "done") })
            .makeSession()
        let declaredOnly = try await session.bindCapabilities(identity: "project", version: "1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: [
                AgentCapabilityTool(id: "find_tools", version: "1", tool: try FindToolsTool(declares: [])),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plain = String(decoding: try encoder.encode(declaredOnly.info), as: UTF8.self)
        #expect(!plain.contains("exposure"))
        #expect(try JSONDecoder().decode(AgentCapabilityInfo.self, from: Data(plain.utf8)) == declaredOnly.info)

        let withDeferred = try await session.bindCapabilities(identity: "project", version: "2", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global], tools: try webTools(fetches: DeclarationLog()))
        let encoded = try encoder.encode(withDeferred.info)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""exposure":"deferred""#))
        #expect(try JSONDecoder().decode(AgentCapabilityInfo.self, from: encoded) == withDeferred.info)
    }
}

private func webTools(fetches: DeclarationLog) throws -> [AgentCapabilityTool] {
    [
        AgentCapabilityTool(id: "find_tools", version: "1", tool: try FindToolsTool(declares: ["web_fetch"])),
        AgentCapabilityTool(id: "web_fetch", version: "1", tool: try WebFetchTool(log: fetches), exposure: .deferred),
    ]
}

private func declarationCall(_ id: String, _ name: String, _ arguments: String) -> ToolCall {
    ToolCall(id: .init(rawValue: id), name: name, argumentsJSON: arguments, completeness: .complete)
}

private actor DeclarationLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
}

private actor RecordingToolEstimator: AgentContextTokenEstimator {
    private(set) var toolNames: [[String]] = []
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        toolNames.append(input.tools.map(\.name))
        return .init(inputTokens: 10, accuracy: .estimated)
    }
}

/// The Host's "find tools" tool: names the tools that fit and declares them for the next request.
private struct FindToolsTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let tools: [String] }
    static let name = "find_tools"
    static let description = "Find tools for a task"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(properties: ["tools": .array(items: .string)], required: ["tools"])
    let declares: [String]
    let policy: ToolPolicy

    init(declares: [String]) throws {
        self.declares = declares
        policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(tools: declares), declaredTools: declares)
    }
}

private struct WebFetchTool: AgentTool {
    struct Input: Codable, Sendable { let url: String }
    struct Output: Codable, Sendable { let text: String }
    static let name = "web_fetch"
    static let description = "Read a web page"
    static let inputSchema = ToolSchema.object(properties: ["url": .string], required: ["url"])
    static let outputSchema = ToolSchema.object(properties: ["text": .string], required: ["text"])
    let log: DeclarationLog
    let policy: ToolPolicy

    init(log: DeclarationLog) throws {
        self.log = log
        policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.add(input.url)
        return ToolResult(output: Output(text: "page"))
    }
}

private struct RenameNoteTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let renamed: Bool }
    static let name = "rename_note"
    static let description = "Rename a note"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["renamed": .boolean], required: ["renamed"])
    let log: DeclarationLog
    let policy: ToolPolicy

    init(log: DeclarationLog) throws {
        self.log = log
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(2), authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "notes", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "notes", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.add(input.id)
        let receipt = ToolReceipt(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
                                  confirmedTargets: [.init(namespace: "notes", id: input.id)], revision: "revision-1")
        return ToolResult(output: Output(renamed: true), receipt: receipt)
    }
}
