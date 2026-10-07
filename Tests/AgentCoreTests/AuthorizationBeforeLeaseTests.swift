import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

/// A tool's own authorization (often a person's answer) runs before the call waits for its scheduler
/// lease, so one unanswered mutation does not hold every other mutation back. The executor still runs
/// under the lease and is never entered without an `allowed` answer.
struct AuthorizationBeforeLeaseTests {
    @Test func aMutationWaitingForItsAnswerDoesNotHoldTheLeaseFromAnother() async throws {
        let fixture = try LeaseFixture(timeout: .seconds(5))
        defer { fixture.cleanup() }
        let a = try await fixture.session().run("A", operationID: "A")
        await fixture.probe.waitFor("authorize:A")

        let b = try await fixture.session().run("B", operationID: "B")
        #expect(try await b.wait().outcome == .completed)
        #expect(await fixture.probe.events == ["authorize:A", "authorize:B", "execute:B"])

        await fixture.answers.open()
        #expect(try await a.wait().outcome == .completed)
        #expect(await fixture.probe.events == ["authorize:A", "authorize:B", "execute:B", "execute:A"])
        try await a.waitForDrain()
        try await b.waitForDrain()
        try await fixture.close()
    }

    @Test func anAnsweredMutationWaitsForTheLeaseWithoutBeingAskedAgain() async throws {
        let fixture = try LeaseFixture(timeout: .seconds(5), gatedAnswers: [], gatedExecutors: ["B"])
        defer { fixture.cleanup() }
        let b = try await fixture.session().run("B", operationID: "B")
        await fixture.probe.waitFor("execute:B")

        let a = try await fixture.session().run("A", operationID: "A")
        await fixture.probe.waitFor("authorize:A")
        await fixture.scheduler.waitUntilPendingWaiterCountEquals(1)
        #expect(await fixture.probe.events == ["authorize:B", "execute:B", "authorize:A"])

        await fixture.executors.open()
        #expect(try await b.wait().outcome == .completed)
        #expect(try await a.wait().outcome == .completed)
        #expect(await fixture.probe.events == ["authorize:B", "execute:B", "authorize:A", "execute:A"])
        try await a.waitForDrain()
        try await b.waitForDrain()
        try await fixture.close()
    }

    @Test func anAnswerArrivingAfterTheToolTimeoutNeverExecutes() async throws {
        let fixture = try LeaseFixture(timeout: .milliseconds(150))
        defer { fixture.cleanup() }
        let a = try await fixture.session().run("A", operationID: "A")
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "A"))) { try await a.wait() }
        await fixture.answers.open()
        try await a.waitForDrain()

        let b = try await fixture.session().run("B", operationID: "B")
        #expect(try await b.wait().outcome == .completed)
        try await b.waitForDrain()
        #expect(await fixture.probe.events == ["authorize:A", "authorize:B", "execute:B"])
        #expect(await fixture.scheduler.pendingWaiterCount() == 0)
        try await fixture.close()
    }

    @Test func anAnswerGivenWhileTheLeaseIsBusyStillEndsAtTheToolTimeout() async throws {
        let fixture = try LeaseFixture(timeout: .milliseconds(300), gatedAnswers: [], gatedExecutors: ["B"])
        defer { fixture.cleanup() }
        let b = try await fixture.session().run("B", operationID: "B")
        await fixture.probe.waitFor("execute:B")

        let a = try await fixture.session().run("A", operationID: "A")
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "A"))) { try await a.wait() }
        await fixture.executors.open()
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "B"))) { try await b.wait() }
        try await b.waitForDrain()
        try await a.waitForDrain()
        #expect(await fixture.probe.events == ["authorize:B", "execute:B", "authorize:A"])
        #expect(await fixture.scheduler.pendingWaiterCount() == 0)
        try await fixture.close()
    }

    @Test func cancellingWhileWaitingForTheAnswerNeverTakesTheLease() async throws {
        let fixture = try LeaseFixture(timeout: .seconds(5))
        defer { fixture.cleanup() }
        let a = try await fixture.session().run("A", operationID: "A")
        await fixture.probe.waitFor("authorize:A")
        await a.cancel()
        await #expect(throws: CancellationError.self) { try await a.wait() }

        let b = try await fixture.session().run("B", operationID: "B")
        #expect(try await b.wait().outcome == .completed)
        try await b.waitForDrain()
        await fixture.answers.open()
        try await a.waitForDrain()
        #expect(await fixture.probe.events == ["authorize:A", "authorize:B", "execute:B"])
        #expect(await fixture.scheduler.pendingWaiterCount() == 0)
        try await fixture.close()
    }

    @Test func aDeniedMutationNeverWaitsForTheLease() async throws {
        let fixture = try LeaseFixture(timeout: .seconds(5), gatedAnswers: [], gatedExecutors: ["B"], denied: ["A"])
        defer { fixture.cleanup() }
        let b = try await fixture.session().run("B", operationID: "B")
        await fixture.probe.waitFor("execute:B")

        let a = try await fixture.session().run("A", operationID: "A")
        await #expect(throws: (any Error).self) { try await a.wait() }
        #expect(await fixture.scheduler.pendingWaiterCount() == 0)
        await fixture.executors.open()
        #expect(try await b.wait().outcome == .completed)
        #expect(await fixture.probe.events == ["authorize:B", "execute:B", "authorize:A"])
        try await a.waitForDrain()
        try await b.waitForDrain()
        try await fixture.close()
    }

    @Test func aSchedulerThatAuthorizesUnderTheLeaseKeepsOtherMutationsWaiting() async throws {
        let fixture = try LeaseFixture(timeout: .milliseconds(300), authorization: .whileHoldingResourceLease)
        defer { fixture.cleanup() }
        let a = try await fixture.session().run("A", operationID: "A")
        await fixture.probe.waitFor("authorize:A")

        let b = try await fixture.session().run("B", operationID: "B")
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "B"))) { try await b.wait() }
        await #expect(throws: AgentLoopError.toolTimedOut(.init(rawValue: "A"))) { try await a.wait() }
        await fixture.answers.open()
        try await a.waitForDrain()
        try await b.waitForDrain()
        #expect(await fixture.probe.events == ["authorize:A"])
        try await fixture.close()
    }
}

private struct LeaseFixture {
    let probe = LeaseEventProbe()
    let answers = ManualGate()
    let executors = ManualGate()
    let scheduler: ToolScheduler
    let journal: AgentJournal
    let agent: Agent
    private let url: URL

    init(timeout: Duration, gatedAnswers: Set<String> = ["A"], gatedExecutors: Set<String> = [],
         denied: Set<String> = [], authorization: ToolAuthorizationTiming = .beforeResourceLease) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-agent-authorization-lease-\(UUID().uuidString).log")
        scheduler = ToolScheduler(authorization: authorization)
        journal = try makeTestJournal(at: url)
        let tool = try ApprovedWriteTool(probe: probe, answers: answers, executors: executors, timeout: timeout,
                                         gatedAnswers: gatedAnswers, gatedExecutors: gatedExecutors, denied: denied)
        let provider = ScriptedProvider { request, _ in
            if case .tool = request.messages.last { return textResponse(request, "done") }
            guard case .user(let content) = request.messages.last, case .text(let label) = content.last else {
                throw FixtureError.invalidOperation
            }
            return toolResponse(request, [.init(id: .init(rawValue: label), name: ApprovedWriteTool.name,
                                               argumentsJSON: #"{"label":"\#(label)","document":"shared"}"#,
                                               completeness: .complete)])
        }
        agent = try Agent(model: fixtureModel, provider: provider, tools: [tool],
                          configuration: AgentConfiguration(scheduler: scheduler))
    }

    func session() throws -> AgentSession { try agent.makeSession(journal: journal) }

    func close() async throws { try await journal.close() }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(atPath: url.path + ".lock")
    }
}

private actor LeaseEventProbe {
    private(set) var events: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: String) {
        events.append(event)
        waiters.removeValue(forKey: event)?.forEach { $0.resume() }
    }

    func waitFor(_ event: String) async {
        if events.contains(event) { return }
        await withCheckedContinuation { waiters[event, default: []].append($0) }
    }
}

/// Writes one shared document; every write asks first and conflicts with every other write.
private struct ApprovedWriteTool: AgentTool {
    struct Input: Codable, Sendable { let label: String; let document: String }
    typealias Output = String
    static let name = "approved_write"
    static let description = "Write a document after the user allows it"
    static let inputSchema = ToolSchema.object(properties: ["label": .string, "document": .string],
                                               required: ["label", "document"])
    static let outputSchema = ToolSchema.string

    let probe: LeaseEventProbe
    let answers: ManualGate
    let executors: ManualGate
    let gatedAnswers: Set<String>
    let gatedExecutors: Set<String>
    let denied: Set<String>
    let policy: ToolPolicy

    init(probe: LeaseEventProbe, answers: ManualGate, executors: ManualGate, timeout: Duration,
         gatedAnswers: Set<String>, gatedExecutors: Set<String>, denied: Set<String>) throws {
        self.probe = probe; self.answers = answers; self.executors = executors
        self.gatedAnswers = gatedAnswers; self.gatedExecutors = gatedExecutors; self.denied = denied
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: timeout, authorization: .required)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.document", id: input.document))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture.document", id: input.document)], revision: .present)
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        await probe.record("authorize:\(input.label)")
        if gatedAnswers.contains(input.label) { await answers.wait() }
        return denied.contains(input.label) ? .denied : .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await probe.record("execute:\(input.label)")
        if gatedExecutors.contains(input.label) { await executors.wait() }
        let receipt = ToolReceipt(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
                                  confirmedTargets: [.init(namespace: "fixture.document", id: input.document)],
                                  revision: input.label)
        return ToolResult(output: input.label, receipt: receipt)
    }
}
