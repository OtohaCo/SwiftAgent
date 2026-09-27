@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentCapabilityScopeTests {
    @Test func duplicateAndInvalidBindingsFailBeforeAUserInput() async throws {
        let agent = try Agent(model: fixtureModel,
                              provider: ScriptedProvider { request, _ in textResponse(request, "unused") })
        let session = try agent.makeSession()
        let tool = try ScopeReadTool(log: EffectLog())
        await #expect(throws: AgentCapabilityError.duplicateToolIdentity) {
            try await session.bindCapabilities(identity: "x", version: "1", backendInstanceID: "b",
                backendVersion: "1", allowedResources: [.global],
                tools: [.init(id: "same", version: "1", tool: tool),
                        .init(id: "same", version: "2", tool: tool)])
        }
        await #expect(throws: AgentCapabilityError.invalidResourceScope) {
            try await session.bindCapabilities(identity: "x", version: "1", backendInstanceID: "b",
                backendVersion: "1", allowedResources: [.global, .global],
                tools: [.init(id: "read", version: "1", tool: tool)])
        }
        #expect(await session.history == [])
    }

    @Test func outOfScopeResourceAndGuessedToolNeverEnterExecutors() async throws {
        let log = EffectLog()
        let provider = ScriptedProvider { request, _ in
            toolResponse(request, [.init(id: .init(rawValue: "read"), name: ScopeReadTool.name,
                                         argumentsJSON: #"{"id":"B"}"#, completeness: .complete)])
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession()
        let binding = try await session.bindCapabilities(identity: "A", version: "1",
            backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "fixture.scope", id: "A"))],
            tools: [.init(id: "read", version: "1", tool: try ScopeReadTool(log: log))])
        let run = try await session.run("read B", capabilities: binding)
        await #expect(throws: AgentCapabilityError.resourceOutsideScope) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await log.names.isEmpty)
        #expect(await binding.status().finalAdmissions == 0)

        let guessed = ScriptedProvider { request, _ in
            toolResponse(request, [.init(id: .init(rawValue: "guess"), name: "unpublished",
                                         argumentsJSON: "{}", completeness: .complete)])
        }
        let guessedAgent = try Agent(model: fixtureModel, provider: guessed)
        let separate = try guessedAgent.makeSession()
        let limited = try await separate.bindCapabilities(identity: "limited", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let attempt = try await separate.run("guess", capabilities: limited)
        await #expect(throws: ToolRegistryError.unknownTool("unpublished")) { _ = try await attempt.wait() }
        try await attempt.waitForDrain()
        #expect(await limited.status().finalAdmissions == 0)
    }

    @Test func lateAuthorizationCannotEnterAfterRevocation() async throws {
        let gate = ScopeGate()
        let counts = ScopeCounts()
        let provider = ScriptedProvider { request, _ in
            toolResponse(request, [.init(id: .init(rawValue: "auth"), name: ScopeAuthorizedTool.name,
                                         argumentsJSON: "{}", completeness: .complete)])
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession()
        let binding = try await session.bindCapabilities(identity: "auth", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global],
            tools: [.init(id: "auth", version: "1", tool: try ScopeAuthorizedTool(gate: gate, counts: counts))])
        let run = try await session.run("authorize", capabilities: binding)
        await gate.waitUntilEntered()
        await binding.revoke()
        await gate.open()
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await binding.status().finalAdmissions == 0)
        #expect(await counts.executorEntries == 0)
    }

    @Test func revocationDuringSharedResourceWaitDoesNotGrantExecutionOrReleaseTheOtherScope() async throws {
        let scheduler = ToolScheduler()
        let holderGate = ScopeGate()
        let otherGate = ScopeGate()
        await otherGate.open()
        let holderCount = ScopeCounts(), otherCount = ScopeCounts()
        let provider = ScriptedProvider { request, _ in
            request.messages.last?.role == .tool ? textResponse(request, "done") :
                toolResponse(request, [.init(id: .init(rawValue: "resource-\(UUID())"),
                                             name: ScopeExclusiveReadTool.name,
                                             argumentsJSON: #"{"id":"shared"}"#, completeness: .complete)])
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              configuration: .init(scheduler: scheduler))
        let a = try agent.makeSession(), b = try agent.makeSession()
        let resource = ToolResource.named(.init(namespace: "fixture.scope", id: "shared"))
        let aScope = try await a.bindCapabilities(identity: "A", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [resource],
            tools: [.init(id: "read", version: "1",
                          tool: try ScopeExclusiveReadTool(gate: holderGate, counts: holderCount))])
        let bScope = try await b.bindCapabilities(identity: "B", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [resource],
            tools: [.init(id: "read", version: "1",
                          tool: try ScopeExclusiveReadTool(gate: otherGate, counts: otherCount))])
        let first = try await a.run("read", capabilities: aScope)
        await holderGate.waitUntilEntered()
        let second = try await b.run("read", capabilities: bScope)
        await scheduler.waitUntilPendingWaiterCountEquals(1)
        await bScope.revoke()
        await #expect(throws: (any Error).self) { _ = try await second.wait() }
        try await second.waitForDrain()
        #expect(await otherCount.executorEntries == 0)
        #expect(await bScope.status().finalAdmissions == 0)
        #expect(await first.isDrainComplete() == false)
        await holderGate.open()
        #expect(try await first.wait().outcome == .completed)
        try await first.waitForDrain()
        #expect(await holderCount.executorEntries == 1)
    }

    @Test func finalAdmissionBeforeRevokeRemainsInFlightUntilTheExecutorAndDrainExit() async throws {
        let gate = ScopeGate()
        let counts = ScopeCounts()
        let provider = ScriptedProvider { request, _ in
            toolResponse(request, [.init(id: .init(rawValue: "entered"), name: ScopeExclusiveReadTool.name,
                                         argumentsJSON: #"{"id":"shared"}"#, completeness: .complete)])
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession()
        let binding = try await session.bindCapabilities(identity: "run", version: "1",
            backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "fixture.scope", id: "shared"))],
            tools: [.init(id: "read", version: "1", tool: try ScopeExclusiveReadTool(gate: gate, counts: counts))])
        let run = try await session.run("read", capabilities: binding)
        await gate.waitUntilEntered()
        #expect(await binding.status().finalAdmissions == 1)
        #expect(await counts.executorEntries == 1)
        await binding.revoke()
        #expect(await binding.status().activeAdmissions == 1)
        let abandonedObserver = Task { try await binding.waitForDrain() }
        await binding.scope.waitUntilWaiterCount(1)
        abandonedObserver.cancel()
        await #expect(throws: CancellationError.self) { try await abandonedObserver.value }
        #expect(await run.isDrainComplete() == false)
        await gate.open()
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()
        try await binding.waitForDrain()
        #expect(await binding.status().activeAdmissions == 0)
        #expect(await binding.status().activeRuns == 0)
        #expect(await provider.log.requests.count == 1)
    }

    @Test func laterBindingVersionCannotHotSwapAnActiveRunOrItsEstimatorToolList() async throws {
        let gate = ScopeGate()
        let versions = ScopeVersionLog()
        let estimates = ScopeEstimateLog()
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("v1")]) { await gate.wait() }
            if request.messages.last?.role == .user {
                return toolResponse(request, [.init(id: .init(rawValue: "version-\(UUID())"),
                                                    name: "versioned", argumentsJSON: "{}", completeness: .complete)])
            }
            return textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession()
        let modelBinding = try AgentModelBinding(profileID: "fixture", profileRevision: "1",
            model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            tokenBudget: .init(maximumContextTokens: 1_000, reservedOutputTokens: 50, estimator: estimates))
        let v1 = try await session.bindCapabilities(identity: "versioned", version: "v1",
            scopeID: "stable-label", backendInstanceID: "local", backendVersion: "v1",
            allowedResources: [.global],
            tools: [.init(id: "versioned", version: "v1", tool: try ScopeVersionOne(log: versions))])
        let first = try await session.run("v1", capabilities: v1, using: modelBinding)
        await gate.waitUntilEntered()
        let v2 = try await session.bindCapabilities(identity: "versioned", version: "v2",
            scopeID: "stable-label", backendInstanceID: "local", backendVersion: "v2",
            allowedResources: [.global],
            tools: [.init(id: "versioned", version: "v2", tool: try ScopeVersionTwo(log: versions))])
        #expect(v1.info.scopeInstanceID != v2.info.scopeInstanceID)
        await #expect(throws: AgentSessionError.runInProgress) {
            try await session.run("v2", capabilities: v2, using: modelBinding)
        }
        await gate.open()
        #expect(try await first.wait().outcome == .completed)
        try await first.waitForDrain()
        let second = try await session.run("v2", capabilities: v2, using: modelBinding)
        #expect(try await second.wait().outcome == .completed)
        try await second.waitForDrain()
        #expect(second.capabilities?.runID == second.id)
        #expect(await versions.values == ["v1", "v2"])
        let requests = await provider.log.requests
        let v1Request = try #require(requests.first(where: { $0.messages.last == .user([.text("v1")]) }))
        let v2Request = try #require(requests.first(where: { $0.messages.last == .user([.text("v2")]) }))
        #expect(v1Request.tools.map(\.description) == ["version one"])
        #expect(v2Request.tools.map(\.description) == ["version two"])
        let estimated = await estimates.toolDescriptions
        #expect(estimated.contains(["version one"]))
        #expect(estimated.contains(["version two"]))
    }

    @Test func revokeAfterFileEffectKeepsTheIntentAndDrainOwnerAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-mutation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effect = directory.appendingPathComponent("effect.txt")
        try Data().write(to: effect)
        let journal = try AgentIncrementalJournal.create(at: directory.appendingPathComponent("journal"),
                                                          operationDomain: "shared-scope-ledger")
        let gate = ScopeGate()
        let counts = ScopeCounts()
        let call = ToolCall(id: .init(rawValue: "file-write"), name: ScopeFileMutationTool.name,
                            argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in
            request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(journal: journal)
        let binding = try await session.bindCapabilities(identity: "B", version: "1", scopeID: "B-first",
            backendInstanceID: "local-file", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "fixture.scope", id: "B"))],
            tools: [.init(id: "write", version: "1",
                          tool: try ScopeFileMutationTool(file: effect, gate: gate, counts: counts))])
        let run = try await session.run("write", capabilities: binding, operationID: "stable-write")
        await gate.waitUntilEntered()
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")
        #expect(await counts.executorEntries == 1)
        #expect(await binding.status().finalAdmissions == 1)
        await binding.revoke()
        #expect(await binding.status().revoked)
        #expect(await binding.status().activeRuns == 1)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.open()
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await run.waitForDrain()
        try await binding.waitForDrain()
        #expect(await binding.status().activeAdmissions == 0)
        #expect(try await journal.pendingMutations(sessionID: session.id).map(\.state) == [.needsReconciliation])
        try await journal.close()

        let reopened = try AgentIncrementalJournal.open(at: directory.appendingPathComponent("journal"))
        let retrySession = try agent.makeSession(journal: reopened)
        let newer = try await retrySession.bindCapabilities(identity: "B", version: "2", scopeID: "B-new",
            backendInstanceID: "local-file", backendVersion: "2",
            allowedResources: [.named(.init(namespace: "fixture.scope", id: "B"))],
            tools: [.init(id: "write", version: "2",
                          tool: try ScopeFileMutationTool(file: effect, gate: ScopeGate(), counts: counts))])
        let retry = try await retrySession.run("retry", capabilities: newer, operationID: "stable-write")
        await #expect(throws: (any Error).self) { _ = try await retry.wait() }
        try await retry.waitForDrain()
        #expect(await counts.executorEntries == 1)
        #expect(try String(contentsOf: effect, encoding: .utf8) == "effect\n")
        #expect(try await reopened.mutationStatus(identity: #"stable-write/scope_write/{"id":"B"}"#)?.state == .needsReconciliation)
        try await reopened.close()
    }
    @Test func capturedToolSetAndRevokedGenerationStayBoundToOneSession() async throws {
        let log = EffectLog()
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [addition("scoped-add")]) : textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession()
        let binding = try await session.bindCapabilities(
            identity: "math", version: "v1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global],
            tools: [.init(id: "add", version: "v1", tool: try AddTool(log: log))])
        let run = try await session.run("calculate", capabilities: binding)
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(run.capabilities?.identity == "math")
        let requests = await provider.log.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.tools.map(\.name) == ["add"] })
        #expect(await log.names == ["add"])

        await binding.revoke()
        await binding.revoke()
        #expect(await binding.status().generation == 1)
        #expect(await binding.status().finalAdmissions == 1)
        await #expect(throws: AgentCapabilityError.revoked) {
            try await session.run("cannot reuse", capabilities: binding)
        }
        #expect(!(await session.history).contains(.user([.text("cannot reuse")])))
        let other = try agent.makeSession()
        await #expect(throws: AgentCapabilityError.sessionMismatch) {
            try await other.run("not its scope", capabilities: binding)
        }
    }

    @Test func mutationIntroducedByRunBindingStillRequiresDurableJournal() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "must not run") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(
            identity: "write", version: "v1", backendInstanceID: "fixture",
            backendVersion: "1", allowedResources: [.global],
            tools: [.init(id: "write", version: "v1", tool: try ScopeMutationTool())])
        await #expect(throws: AgentSessionError.durableJournalRequired) {
            try await session.run("must not commit", capabilities: binding)
        }
        #expect(await session.history == [])
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func revocationDuringStartupProjectionCannotCommitCandidateInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-startup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "scope-startup")
        let gate = ScopeGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "never run") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let scope = try await session.bindCapabilities(identity: "preflight", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let model = try AgentModelBinding(profileID: "preflight", profileRevision: "1",
            model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: ScopeBlockingProjector(gate: gate))
        let starting = Task { try await session.run("candidate", capabilities: scope, using: model) }
        await gate.waitUntilEntered()
        #expect(await scope.status().activeRuns == 1)
        await scope.revoke()
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.open()
        await #expect(throws: AgentCapabilityError.revoked) { _ = try await starting.value }
        try await scope.waitForDrain()
        #expect(await session.history == [])
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }
}

private actor ScopeCounts {
    private(set) var executorEntries = 0
    func entered() { executorEntries += 1 }
}

private struct ScopeFileMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "scope_write"
    static let description = "Write a temporary fixture file"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let file: URL
    let gate: ScopeGate
    let counts: ScopeCounts
    let policy: ToolPolicy
    init(file: URL, gate: ScopeGate, counts: ScopeCounts) throws {
        self.file = file; self.gate = gate; self.counts = counts
        policy = try .mutation(timeout: .seconds(5), authorization: .notRequired, evidence: .none)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.scope", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture.scope", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        await counts.entered()
        await gate.wait()
        return .init(output: .init(updated: true), receipt: .init(
            operationID: context.idempotencyKey ?? "", status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture.scope", id: input.id)], revision: "v1"))
    }
}

private actor ScopeGate {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pending = observers
        observers.removeAll()
        pending.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func open() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private struct ScopeReadTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let id: String }
    static let name = "scope_read"
    static let description = "Read one named resource"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    let log: EffectLog
    let policy: ToolPolicy
    init(log: EffectLog) throws { self.log = log; policy = try .readOnly(authorization: .notRequired) }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.scope", id: input.id))]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record(Self.name, context)
        return .init(output: .init(id: input.id))
    }
}

private struct ScopeAuthorizedTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let allowed: Bool }
    static let name = "scope_authorized"
    static let description = "Authorization barrier fixture"
    static let inputSchema = ToolSchema.object(properties: [:], required: [])
    static let outputSchema = ToolSchema.object(properties: ["allowed": .boolean], required: ["allowed"])
    let gate: ScopeGate
    let counts: ScopeCounts
    let policy: ToolPolicy
    init(gate: ScopeGate, counts: ScopeCounts) throws {
        self.gate = gate; self.counts = counts
        policy = try .readOnly(authorization: .required)
    }
    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        await gate.wait()
        return .allowed
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await counts.entered()
        return .init(output: .init(allowed: true))
    }
}

private struct ScopeExclusiveReadTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let id: String }
    static let name = "exclusive_read"
    static let description = "Read one shared resource with an exclusive lease"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    let gate: ScopeGate
    let counts: ScopeCounts
    let policy: ToolPolicy
    init(gate: ScopeGate, counts: ScopeCounts) throws {
        self.gate = gate; self.counts = counts
        policy = try .init(effect: .readOnly, execution: .exclusive, idempotency: .safe,
                           timeout: .seconds(5), authorization: .notRequired)
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.scope", id: input.id))]
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await counts.entered()
        await gate.wait()
        return .init(output: .init(id: input.id))
    }
}

private actor ScopeVersionLog {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}

private actor ScopeEstimateLog: AgentContextTokenEstimator {
    private(set) var toolDescriptions: [[String]] = []
    func estimate(_ input: AgentContextTokenEstimationInput) -> AgentContextTokenEstimate {
        toolDescriptions.append(input.tools.map(\.description))
        return .init(inputTokens: 1, accuracy: .estimated)
    }
}

private struct ScopeVersionOne: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let version: String }
    static let name = "versioned"
    static let description = "version one"
    static let inputSchema = ToolSchema.object(properties: [:], required: [])
    static let outputSchema = ToolSchema.object(properties: ["version": .string], required: ["version"])
    let log: ScopeVersionLog
    let policy: ToolPolicy
    init(log: ScopeVersionLog) throws { self.log = log; policy = try .readOnly(authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record("v1")
        return .init(output: .init(version: "v1"))
    }
}

private struct ScopeVersionTwo: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let version: String }
    static let name = "versioned"
    static let description = "version two"
    static let inputSchema = ScopeVersionOne.inputSchema
    static let outputSchema = ScopeVersionOne.outputSchema
    let log: ScopeVersionLog
    let policy: ToolPolicy
    init(log: ScopeVersionLog) throws { self.log = log; policy = try .readOnly(authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await log.record("v2")
        return .init(output: .init(version: "v2"))
    }
}

private struct ScopeBlockingProjector: AgentContextProjector {
    let gate: ScopeGate
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        await gate.wait()
        return try await AgentIdentityContextProjector().project(input)
    }
}

private struct ScopeMutationTool: AgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let written: Bool }
    static let name = "scope_write"
    static let description = "Mutation admission fixture"
    static let inputSchema = ToolSchema.object(properties: ["value": .string], required: ["value"])
    static let outputSchema = ToolSchema.object(properties: ["written": .boolean], required: ["written"])
    let policy: ToolPolicy
    init() throws { policy = try .mutation(authorization: .notRequired, evidence: .none) }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture", id: input.value)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        .init(output: .init(written: true))
    }
}
