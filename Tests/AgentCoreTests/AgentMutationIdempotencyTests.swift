import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

struct AgentMutationIdempotencyTests {
    @Test func settledRetryReturnsExistingReceiptWithoutExecutingAgain() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let firstCall = mutationCall(id: "call-first", arguments: #"{"id":"listing-1"}"#)
        let retryCall = mutationCall(id: "call-retry", arguments: #"{"id":"listing-1"}"#)
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [firstCall])
            case 2: return textResponse(request, "first complete")
            case 3: return toolResponse(request, [retryCall])
            default:
                #expect(request.messages.contains(.tool(.init(
                    callID: retryCall.id,
                    content: [.json(.object(["updated": .bool(true)]))],
                    isError: false
                ))))
                return textResponse(request, "retry complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try IdempotencyMutationTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await session.run("Update", operationID: "logical-operation")
        let first = try await firstRun.wait()
        try await firstRun.waitForDrain()
        let retried = try await session.run("Retry", operationID: "logical-operation").wait()

        #expect(await probe.executorCount == 1)
        let originalReceipt = try #require(first.receipts.first?.receipt)
        let replayed = try #require(retried.receipts.first)
        #expect(replayed.callID == retryCall.id)
        #expect(replayed.receipt == originalReceipt)
        #expect(await probe.externalUpdates == ["listing-1"])
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func settledRetryAcrossSessionsUsesTheJournalDomainWithoutExecutingAgain() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let firstCall = mutationCall(id: "session-a-call", arguments: #"{"id":"listing-1"}"#)
        let retryCall = mutationCall(id: "session-b-call", arguments: #"{"id":"listing-1"}"#)
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [firstCall])
            case 2: return textResponse(request, "first complete")
            case 3: return toolResponse(request, [retryCall])
            default: return textResponse(request, "retry complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let agent = try Agent(model: fixtureModel, provider: provider,
                              tools: [try IdempotencyMutationTool(probe: probe)])
        let first = try agent.makeSession(id: UUID(), journal: journal)
        let second = try agent.makeSession(id: UUID(), journal: journal)

        let firstResult = try await first.run("Update", operationID: "cross-session-operation").wait()
        let retryResult = try await second.run("Retry", operationID: "cross-session-operation").wait()

        #expect(await probe.executorCount == 1)
        #expect(retryResult.receipts.first?.receipt == firstResult.receipts.first?.receipt)
        #expect(retryResult.receipts.first?.callID == retryCall.id)
        #expect(await probe.externalUpdates == ["listing-1"])
    }

    @Test func intentRetryReturnsTypedPendingWithoutCreatingAnotherIntent() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let first = try admissionRequest(key: "pending-operation", callID: "pending-first")
        let retry = try admissionRequest(key: "pending-operation", callID: "pending-retry")
        _ = try await journal.admit(first)

        await #expect(throws: AgentJournalError.mutationPending) {
            _ = try await journal.admit(retry)
        }
        let pending = await journal.pendingMutations()
        #expect(pending.count == 1)
        #expect(pending.first?.state == .intent)
        #expect(pending.first?.intent.call.id == first.callID)
    }

    @Test func needsReconciliationRetryFailsClosed() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let first = try admissionRequest(key: "uncertain-operation", callID: "uncertain-first")
        let retry = try admissionRequest(key: "uncertain-operation", callID: "uncertain-retry")
        _ = try await journal.admit(first)
        _ = try await journal.recoverPendingMutations()

        await #expect(throws: AgentJournalError.mutationRequiresReconciliation) {
            _ = try await journal.admit(retry)
        }
        let pending = await journal.pendingMutations()
        #expect(pending.count == 1)
        #expect(pending.first?.state == .needsReconciliation)
    }

    @Test func confirmedAbortedMutationCanCreateANewDurableIntent() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let first = try admissionRequest(key: "aborted-operation", callID: "aborted-first")
        let retry = try admissionRequest(key: "aborted-operation", callID: "aborted-retry")
        _ = try await journal.admit(first)
        let recovered = try await journal.recoverPendingMutations()
        try await journal.abortMutation(try #require(recovered.first))

        let result = try await journal.admit(retry)

        guard case .admitted = result else {
            Issue.record("A confirmed-not-executed abort must allow a new durable intent")
            return
        }
        let pending = await journal.pendingMutations()
        #expect(pending.count == 1)
        #expect(pending.first?.state == .intent)
        #expect(pending.first?.intent.call.id == retry.callID)
    }

    @Test func canonicalJSONArgumentOrderProducesTheSameIdentity() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let calls = [
            mutationCall(id: "ordered", arguments: #"{"id":"listing-1","enabled":true}"#),
            mutationCall(id: "reordered", arguments: #"{"enabled":true,"id":"listing-1"}"#),
        ]
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [calls[0]])
            case 2: return textResponse(request, "first complete")
            case 3: return toolResponse(request, [calls[1]])
            default: return textResponse(request, "retry complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try IdempotencyMutationTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await session.run("Update", operationID: "canonical-operation")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        _ = try await session.run("Retry", operationID: "canonical-operation").wait()

        #expect(await probe.executorCount == 1)
        #expect(await probe.externalUpdates == ["listing-1"])
    }

    @Test func equivalentNumberAndEscapeSpellingsProduceTheSameIdentity() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1:
                return toolResponse(request, [mutationCall(
                    id: "plain-json",
                    arguments: #"{"id":"listing-1","version":1}"#
                )])
            case 2: return textResponse(request, "first complete")
            case 3:
                return toolResponse(request, [mutationCall(
                    id: "equivalent-json",
                    arguments: #"{"version":1.0,"id":"\u006cisting-1"}"#
                )])
            default: return textResponse(request, "retry complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try IdempotencyMutationTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await session.run("Update", operationID: "semantic-json-operation")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        _ = try await session.run("Retry", operationID: "semantic-json-operation").wait()

        #expect(await probe.executorCount == 1)
        #expect(await probe.externalUpdates == ["listing-1"])
    }

    @Test func sameOperationIDDifferentArgumentsAreDifferentMutations() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [mutationCall(id: "listing-a", arguments: #"{"id":"A"}"#)])
            case 2: return textResponse(request, "A complete")
            case 3: return toolResponse(request, [mutationCall(id: "listing-b", arguments: #"{"id":"B"}"#)])
            default: return textResponse(request, "B complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try IdempotencyMutationTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await session.run("Update A", operationID: "order-123")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        _ = try await session.run("Update B", operationID: "order-123").wait()

        #expect(await probe.executorCount == 2)
        #expect(await probe.externalUpdates == ["A", "B"])
    }

    @Test func nilOperationIDDoesNotDeduplicateAcrossRuns() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [mutationCall(id: "first-call", arguments: #"{"id":"listing-1"}"#)])
            case 2: return textResponse(request, "first complete")
            case 3: return toolResponse(request, [mutationCall(id: "second-call", arguments: #"{"id":"listing-1"}"#)])
            default: return textResponse(request, "second complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try IdempotencyMutationTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await session.run("Update")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        _ = try await session.run("Update again").wait()

        #expect(await probe.executorCount == 2)
        #expect(await probe.externalUpdates == ["listing-1", "listing-1"])
    }

    @Test func sameMutationTwiceInOneRunExecutesOnce() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let firstCall = mutationCall(id: "first-call", arguments: #"{"id":"listing-1"}"#)
        let replayCall = mutationCall(id: "same-run-replay", arguments: #"{"id":"listing-1"}"#)
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [firstCall])
            case 2: return toolResponse(request, [replayCall])
            default: return textResponse(request, "complete")
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try IdempotencyMutationTool(probe: probe)]).makeSession(journal: journal)

        let result = try await session.run("Update", operationID: "same-run-operation").wait()

        #expect(await probe.executorCount == 1)
        #expect(result.receipts.map(\.callID) == [firstCall.id, replayCall.id])
        #expect(result.receipts[0].receipt == result.receipts[1].receipt)
    }

    @Test func settledRetryWorksAfterSessionRestart() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [mutationCall(id: "before-restart", arguments: #"{"id":"listing-1"}"#)])
            case 2: return textResponse(request, "first complete")
            case 3: return toolResponse(request, [mutationCall(id: "after-restart", arguments: #"{"id":"listing-1"}"#)])
            default: return textResponse(request, "retry complete")
            }
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              tools: [try IdempotencyMutationTool(probe: probe)])
        let firstJournal = try AgentJournal(persistenceURL: url)
        let firstSession = try agent.makeSession(journal: firstJournal)
        let first = try await firstSession.run("Update", operationID: "restart-operation")
        let firstResult = try await first.wait()
        try await first.waitForDrain()

        let reloaded = try AgentJournal.load(from: url)
        let restartedSession = try agent.makeSession(journal: reloaded)
        let retryResult = try await restartedSession.run("Retry", operationID: "restart-operation").wait()

        #expect(await probe.executorCount == 1)
        #expect(retryResult.receipts.first?.receipt == firstResult.receipts.first?.receipt)
        #expect(retryResult.receipts.first?.callID.rawValue == "after-restart")
    }

    @Test func journalCompactionPreservesSettledReplayIdentity() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = IdempotencyMutationProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [mutationCall(id: "before-compact", arguments: #"{"id":"listing-1"}"#)])
            case 2: return textResponse(request, "first complete")
            case 3: return toolResponse(request, [mutationCall(id: "after-compact", arguments: #"{"id":"listing-1"}"#)])
            default: return textResponse(request, "retry complete")
            }
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
                              tools: [try IdempotencyMutationTool(probe: probe)])
        let journal = try AgentJournal(persistenceURL: url)
        let session = try agent.makeSession(journal: journal)
        let first = try await session.run("Update", operationID: "compact-operation")
        let firstResult = try await first.wait()
        try await first.waitForDrain()
        #expect(try await journal.compactIfNeeded(maxJournalBytes: 1))

        let reloaded = try AgentJournal.load(from: url)
        let retrySession = try agent.makeSession(journal: reloaded)
        let retryResult = try await retrySession.run("Retry", operationID: "compact-operation").wait()

        #expect(await probe.executorCount == 1)
        #expect(retryResult.receipts.first?.receipt == firstResult.receipts.first?.receipt)
        #expect(retryResult.receipts.first?.callID.rawValue == "after-compact")
    }

    @Test func reconciledSuccessBecomesSettledReplay() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let first = try admissionRequest(key: "reconciled-operation", callID: "original-call")
        _ = try await journal.admit(first)
        let pending = try #require(try await journal.recoverPendingMutations().first)
        let receipt = ToolReceipt(
            operationID: first.idempotencyKey,
            status: .succeeded,
            confirmedTargets: [.init(namespace: "property.listing", id: "listing-1")],
            revision: "reconciled-revision"
        )
        try await journal.reconcileMutation(
            pending,
            receipt: receipt,
            output: .object(["updated": .bool(true)])
        )

        let replay = try await journal.admit(
            admissionRequest(key: first.idempotencyKey, callID: "retry-call")
        )

        guard case .settled(let replayedReceipt, let replayedOutput) = replay else {
            Issue.record("A reconciled success must become a settled replay")
            return
        }
        #expect(replayedReceipt == receipt)
        #expect(replayedOutput == .object(["updated": .bool(true)]))
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func legacySettlementWithoutDurableOutputFailsClosed() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let journal = try AgentJournal(persistenceURL: url)
        let first = try admissionRequest(key: "legacy-settled-operation", callID: "legacy-call")
        _ = try await journal.admit(first)
        let pending = try #require(try await journal.recoverPendingMutations().first)
        let receipt = ToolReceipt(
            operationID: first.idempotencyKey,
            status: .succeeded,
            confirmedTargets: [.init(namespace: "property.listing", id: "listing-1")],
            revision: "legacy-revision"
        )
        try await journal.reconcileMutation(pending, receipt: receipt)

        await #expect(throws: AgentJournalError.mutationReplayUnavailable) {
            _ = try await journal.admit(
                admissionRequest(key: first.idempotencyKey, callID: "legacy-retry")
            )
        }
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func concurrentDuplicateAdmissionExecutesOnce() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let entered = IdempotencyGate()
        let release = IdempotencyGate()
        let probe = BlockingIdempotencyProbe(entered: entered, release: release)
        let firstProvider = ScriptedProvider { request, turn in
            turn == 1
                ? toolResponse(request, [mutationCall(id: "first-call", arguments: #"{"id":"listing-1"}"#)])
                : textResponse(request, "first complete")
        }
        let duplicateProvider = ScriptedProvider { request, _ in
            toolResponse(request, [mutationCall(id: "duplicate-call", arguments: #"{"id":"listing-1"}"#)])
        }
        let journal = try AgentJournal(persistenceURL: url)
        let firstSession = try Agent(model: fixtureModel, provider: firstProvider,
                                     tools: [try BlockingIdempotencyTool(probe: probe)]).makeSession(journal: journal)
        let duplicateSession = try Agent(model: fixtureModel, provider: duplicateProvider,
                                         tools: [try BlockingIdempotencyTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await firstSession.run("Update", operationID: "concurrent-operation")
        await entered.wait()
        await #expect(throws: AgentJournalError.mutationPending) {
            _ = try await duplicateSession.run("Retry", operationID: "concurrent-operation").wait()
        }
        #expect(await probe.executorCount == 1)
        await release.open()
        _ = try await firstRun.wait()

        #expect(await probe.executorCount == 1)
        #expect(await probe.externalUpdates == ["listing-1"])
        #expect(await journal.pendingMutations().isEmpty)
    }

    @Test func settledReplayStillRequiresCurrentAuthorization() async throws {
        let url = temporaryJournalURL()
        defer { cleanupJournal(url) }
        let probe = ReplayAuthorizationProbe()
        let provider = ScriptedProvider { request, turn in
            switch turn {
            case 1: return toolResponse(request, [authorizedMutationCall(id: "authorized-first")])
            case 2: return textResponse(request, "first complete")
            default: return toolResponse(request, [authorizedMutationCall(id: "denied-retry")])
            }
        }
        let journal = try AgentJournal(persistenceURL: url)
        let session = try Agent(model: fixtureModel, provider: provider,
                                tools: [try AuthorizedIdempotencyTool(probe: probe)]).makeSession(journal: journal)

        let firstRun = try await session.run("Update", operationID: "authorized-operation")
        _ = try await firstRun.wait()
        try await firstRun.waitForDrain()
        await #expect(throws: ToolInvocationError.authorizationDenied) {
            _ = try await session.run("Retry", operationID: "authorized-operation").wait()
        }

        #expect(await probe.authorizationCount == 2)
        #expect(await probe.executorCount == 1)
        #expect(await journal.pendingMutations().isEmpty)
    }
}

private actor IdempotencyMutationProbe {
    private(set) var executorCount = 0
    private(set) var externalUpdates: [String] = []
    private(set) var receipts: [ToolReceipt] = []

    func execute(id: String, operationID: String) -> ToolReceipt {
        executorCount += 1
        externalUpdates.append(id)
        let receipt = ToolReceipt(
            operationID: operationID,
            status: .succeeded,
            confirmedTargets: [.init(namespace: "property.listing", id: id)],
            revision: "revision-1"
        )
        receipts.append(receipt)
        return receipt
    }
}

private struct IdempotencyMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String; let enabled: Bool?; let version: Decimal? }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "idempotent_update_listing"
    static let description = "Update a listing exactly once"
    static let inputSchema = ToolSchema.object(
        properties: ["id": .string, "enabled": .boolean, "version": .number],
        required: ["id"]
    )
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])

    let probe: IdempotencyMutationProbe
    let policy: ToolPolicy

    init(probe: IdempotencyMutationProbe) throws {
        self.probe = probe
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(2), authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let receipt = await probe.execute(id: input.id, operationID: context.idempotencyKey ?? "missing")
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}

private actor IdempotencyGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor BlockingIdempotencyProbe {
    private let entered: IdempotencyGate
    private let release: IdempotencyGate
    private(set) var executorCount = 0
    private(set) var externalUpdates: [String] = []

    init(entered: IdempotencyGate, release: IdempotencyGate) {
        self.entered = entered
        self.release = release
    }

    func execute(id: String, operationID: String) async -> ToolReceipt {
        executorCount += 1
        await entered.open()
        await release.wait()
        externalUpdates.append(id)
        return ToolReceipt(
            operationID: operationID,
            status: .succeeded,
            confirmedTargets: [.init(namespace: "property.listing", id: id)],
            revision: "revision-1"
        )
    }
}

private struct BlockingIdempotencyTool: AgentTool {
    typealias Input = IdempotencyMutationTool.Input
    typealias Output = IdempotencyMutationTool.Output

    static let name = IdempotencyMutationTool.name
    static let description = IdempotencyMutationTool.description
    static let inputSchema = IdempotencyMutationTool.inputSchema
    static let outputSchema = IdempotencyMutationTool.outputSchema

    let probe: BlockingIdempotencyProbe
    let policy: ToolPolicy

    init(probe: BlockingIdempotencyProbe) throws {
        self.probe = probe
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(2), authorization: .notRequired)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let receipt = await probe.execute(id: input.id, operationID: context.idempotencyKey ?? "missing")
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}

private actor ReplayAuthorizationProbe {
    private(set) var authorizationCount = 0
    private(set) var executorCount = 0

    func authorize() -> ToolAuthorization {
        authorizationCount += 1
        return authorizationCount == 1 ? .allowed : .denied
    }

    func execute(operationID: String) -> ToolReceipt {
        executorCount += 1
        return ToolReceipt(
            operationID: operationID,
            status: .succeeded,
            confirmedTargets: [.init(namespace: "property.listing", id: "listing-1")],
            revision: "revision-1"
        )
    }
}

private struct AuthorizedIdempotencyTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "authorized_idempotent_update"
    static let description = "Update a listing with current authorization"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])

    let probe: ReplayAuthorizationProbe
    let policy: ToolPolicy

    init(probe: ReplayAuthorizationProbe) throws {
        self.probe = probe
        policy = try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                                timeout: .seconds(2), authorization: .required, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "property.listing", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "property.listing", id: input.id)], revision: .present)
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        await probe.authorize()
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let receipt = await probe.execute(operationID: context.idempotencyKey ?? "missing")
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}

private func mutationCall(id: String, arguments: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: IdempotencyMutationTool.name,
          argumentsJSON: arguments, completeness: .complete)
}

private func authorizedMutationCall(id: String) -> ToolCall {
    .init(id: .init(rawValue: id), name: AuthorizedIdempotencyTool.name,
          argumentsJSON: #"{"id":"listing-1"}"#, completeness: .complete)
}

private func admissionRequest(key: String, callID: String) throws -> ToolMutationAdmissionRequest {
    let target = EvidenceReference(namespace: "property.listing", id: "listing-1")
    return ToolMutationAdmissionRequest(
        sessionID: UUID(),
        runID: UUID(),
        callID: .init(rawValue: callID),
        name: IdempotencyMutationTool.name,
        argumentsJSON: #"{"id":"listing-1"}"#,
        resources: [.named(target)],
        idempotencyKey: key,
        receiptExpectation: try .init(targets: [target], revision: .present)
    )
}

private func temporaryJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-agent-idempotency-\(UUID().uuidString).log")
}

private func cleanupJournal(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.removeItem(atPath: url.path + ".lock")
}
