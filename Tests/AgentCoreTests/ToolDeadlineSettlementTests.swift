@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// A tool invocation whose executor finishes before the tool deadline keeps its result even if
/// lease release or cleanup crosses that deadline. Genuine timeouts still fail and quarantine
/// unsettled mutations, and uncertain journal commits survive deadline and cancellation races.
@Suite(.manualClock) struct ToolDeadlineSettlementTests {
    // MARK: - Just-in-time tool completion vs. lease release crossing deadline

    @Test func mutationReturningBeforeToolDeadlineSurvivesLeaseReleaseCrossingDeadline() async throws {
        let journalURL = temporaryURL("jit-journal")
        let effectURL = temporaryURL("jit-effect")
        defer {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: effectURL)
        }
        try Data().write(to: effectURL)

        let clock = ManualAgentClock.current
        let toolTimeout = Duration.milliseconds(300)
        let expectedToolDeadline = clock.after(toolTimeout)
        let leaseProbe = LeaseReleaseProbe()
        let scheduler = ToolScheduler(beforeLeaseRelease: { sessionID, runID, callID in
            await clock.waitForSleeper(until: expectedToolDeadline)
            // Advance past the tool deadline while the resource lease is still being released.
            clock.advance(by: .milliseconds(100))
            await Task.yield()
            await leaseProbe.record(sessionID: sessionID, runID: runID, callID: callID, now: clock.now)
        })

        let executorProbe = ToolInvocationProbe()
        let tool = try TimedMutationTool(
            timeout: toolTimeout,
            file: effectURL,
            probe: executorProbe,
            onExecute: {
                await clock.waitForSleeper(until: expectedToolDeadline)
                // Succeed just before the tool deadline passes.
                clock.advance(by: .milliseconds(250))
            }
        )
        let call = ToolCall(
            id: .init(rawValue: "write-jit"),
            name: TimedMutationTool.name,
            argumentsJSON: #"{"id":"record-1"}"#,
            completeness: .complete
        )
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "settled cleanly")
        }

        let journal = try makeTestJournal(at: journalURL)
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(runTimeout: .seconds(30), scheduler: scheduler)
        )
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Apply change", operationID: "jit-mutation")

        let observedEvents = Task {
            var events: [AgentEvent] = []
            for await event in run.events { events.append(event) }
            return events
        }

        let result = try await run.wait()
        try await run.waitForDrain()
        let events = await observedEvents.value

        #expect(result.outcome == .completed)
        #expect(result.toolCalls == 1)
        #expect(result.receipts.count == 1)
        #expect(result.response.content == [.text("settled cleanly")])
        #expect(await executorProbe.count == 1)
        #expect(try String(contentsOf: effectURL, encoding: .utf8) == "effect\n")

        let releaseEntries = await leaseProbe.entries
        #expect(releaseEntries.count == 1)
        #expect(releaseEntries.first?.sessionID == sessionID)
        #expect(releaseEntries.first?.runID == run.id)
        #expect(releaseEntries.first?.callID == call.id)
        #expect((releaseEntries.first?.now ?? expectedToolDeadline) >= expectedToolDeadline)

        // Verify event lifecycle and next model request context.
        let startedCount = events.filter { if case .runStarted = $0 { true } else { false } }.count
        let finishedCount = events.filter { if case .runFinished = $0 { true } else { false } }.count
        let completedTool = events.contains {
            if case .toolCompleted(let message) = $0 { message.callID == call.id && !message.isError } else { false }
        }
        let failedTool = events.contains { if case .toolFailed = $0 { true } else { false } }
        #expect(startedCount == 1)
        #expect(finishedCount == 1)
        #expect(completedTool)
        #expect(!failedTool)

        let requests = await provider.log.requests
        #expect(requests.count == 2)
        let secondRequestMessages = try #require(requests.last?.messages)
        #expect(secondRequestMessages.contains {
            if case .tool(let message) = $0 { message.callID == call.id && !message.isError } else { false }
        })

        // Mutation must be durably settled, never quarantined for reconciliation.
        #expect(try await journal.pendingMutations(sessionID: sessionID).isEmpty)
        let operationKey = try #require(result.receipts.first?.receipt.operationID)
        let settledStatus = try #require(try await journal.mutationStatus(identity: operationKey))
        #expect(settledStatus.state == .settled)
        #expect(settledStatus.receipt == result.receipts.first?.receipt)
        #expect(settledStatus.replayOutput == .object(["updated": .bool(true)]))

        let expectedMessages = try await journal.readMessages(sessionID: sessionID, limit: 100).map(\.message)
        #expect(expectedMessages == result.history)
        try await journal.close()

        // Reopen the durable journal and confirm settled receipt, replay output, and formal history survive intact.
        let reopened = try openTestJournal(at: journalURL)
        #expect(try await reopened.pendingMutations(sessionID: sessionID).isEmpty)
        #expect(try await reopened.mutationStatus(identity: operationKey) == settledStatus)
        #expect(try await reopened.latestCheckpoint(sessionID: sessionID)?.history == result.history)
        #expect(try await reopened.readMessages(sessionID: sessionID, limit: 100).map(\.message) == expectedMessages)
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func schedulerCallReturningBeforeDeadlineSurvivesLeaseReleaseCrossingDeadline(atRunDeadline: Bool) async throws {
        let clock = ManualAgentClock.current
        let toolTimeout: Duration = atRunDeadline ? .seconds(10) : .milliseconds(300)
        let runDeadline = clock.after(atRunDeadline ? .milliseconds(300) : .seconds(10))
        let expectedToolDeadline = clock.after(.milliseconds(300))
        let leaseProbe = LeaseReleaseProbe()
        let completedFlag = ClockTestFlag()

        let scheduler = ToolScheduler(beforeLeaseRelease: { sessionID, runID, callID in
            await clock.waitForSleeper(until: expectedToolDeadline)
            clock.advance(by: .milliseconds(100))
            await Task.yield()
            await leaseProbe.record(sessionID: sessionID, runID: runID, callID: callID, now: clock.now)
        })
        let tool = try DirectReadTool(timeout: toolTimeout) {
            await clock.waitForSleeper(until: expectedToolDeadline)
            clock.advance(by: .milliseconds(250))
            return "in-time"
        }
        let call = ToolCall(
            id: .init(rawValue: "jit-direct-call"),
            name: DirectReadTool.name,
            argumentsJSON: #"{"id":"item-jit"}"#,
            completeness: .complete
        )
        let sessionID = UUID()
        let runID = UUID()
        let prepared = try ToolRegistry(tools: [AnyAgentTool(tool)]).prepare(
            call,
            context: ToolContext(sessionID: sessionID, runID: runID, callID: call.id, deadline: runDeadline)
        )

        let outputProbe = DirectOutputProbe()
        try await scheduler.execute(
            [prepared],
            deadline: runDeadline,
            onStarted: { _ in },
            onCompleted: { _, _, result in
                completedFlag.set()
                await outputProbe.record(result.output)
            },
            onFailed: { _, error in
                Issue.record("In-time execution must not fail: \(error)")
            }
        )
        await scheduler.waitForRunToDrain(sessionID: sessionID, runID: runID)

        #expect(completedFlag.isSet)
        #expect(await outputProbe.output == .string("in-time"))
        let releases = await leaseProbe.entries
        #expect(releases.count == 1)
        #expect((releases.first?.now ?? expectedToolDeadline) >= expectedToolDeadline)
    }

    // MARK: - Genuine timeouts still fail

    @Test(arguments: [false, true])
    func blockedExecutorPastDeadlineThrowsExpectedSchedulerTimeout(atRunDeadline: Bool) async throws {
        let clock = ManualAgentClock.current
        let entered = ClockTestSignal()
        let unblock = ManualGate()
        let completedFlag = ClockTestFlag()
        let failedProbe = SchedulerFailureProbe()

        let toolTimeout: Duration = atRunDeadline ? .seconds(10) : .milliseconds(300)
        let runDeadline = clock.after(atRunDeadline ? .milliseconds(300) : .seconds(10))
        let tool = try DirectReadTool(timeout: toolTimeout) {
            await entered.signal()
            await unblock.wait()
            return "late"
        }

        let call = ToolCall(
            id: .init(rawValue: "blocked-call"),
            name: DirectReadTool.name,
            argumentsJSON: #"{"id":"item-1"}"#,
            completeness: .complete
        )
        let sessionID = UUID()
        let runID = UUID()
        let prepared = try ToolRegistry(tools: [AnyAgentTool(tool)]).prepare(
            call,
            context: ToolContext(sessionID: sessionID, runID: runID, callID: call.id, deadline: runDeadline)
        )
        let scheduler = ToolScheduler()

        let execution = Task {
            try await scheduler.execute(
                [prepared],
                deadline: runDeadline,
                onStarted: { _ in },
                onCompleted: { _, _, _ in completedFlag.set() },
                onFailed: { _, error in await failedProbe.record(error) }
            )
        }
        defer { Task { await unblock.open() } }

        await entered.wait()
        await clock.advanceWhenArmed(by: .milliseconds(300))

        let expected: ToolSchedulerError = atRunDeadline ? .deadlineExceeded : .toolTimedOut(call.id)
        await #expect(throws: expected) { try await execution.value }
        #expect(!completedFlag.isSet)
        #expect(await failedProbe.lastError as? ToolSchedulerError == expected)

        await unblock.open()
        await scheduler.waitForRunToDrain(sessionID: sessionID, runID: runID)
    }

    @Test(arguments: [false, true])
    func blockedMutationPastDeadlineFailsRunAndQuarantinesInJournal(atRunDeadline: Bool) async throws {
        let journalURL = temporaryURL("blocked-mutation-journal")
        let effectURL = temporaryURL("blocked-mutation-effect")
        defer {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: effectURL)
        }
        try Data().write(to: effectURL)

        let clock = ManualAgentClock.current
        let entered = ClockTestSignal()
        let unblock = ManualGate()
        let executorProbe = ToolInvocationProbe()
        let toolTimeout: Duration = atRunDeadline ? .seconds(10) : .milliseconds(300)
        let runTimeout: Duration = atRunDeadline ? .milliseconds(300) : .seconds(10)

        let tool = try TimedMutationTool(
            timeout: toolTimeout,
            file: effectURL,
            probe: executorProbe,
            onExecute: {
                await entered.signal()
                await unblock.wait()
            }
        )
        let call = ToolCall(
            id: .init(rawValue: "blocked-mutation"),
            name: TimedMutationTool.name,
            argumentsJSON: #"{"id":"record-blocked"}"#,
            completeness: .complete
        )
        let provider = ScriptedProvider { request, _ in toolResponse(request, [call]) }
        let journal = try makeTestJournal(at: journalURL)
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(runTimeout: runTimeout)
        )
        let sessionID = UUID()
        let run = try await agent.makeSession(id: sessionID, journal: journal)
            .run("Mutate slowly", operationID: "blocked-op-\(atRunDeadline)")
        defer { Task { await unblock.open() } }

        await entered.wait()
        await clock.advanceWhenArmed(by: .milliseconds(300))

        let expected: AgentLoopError = atRunDeadline ? .deadlineExceeded : .toolTimedOut(call.id)
        await #expect(throws: expected) { _ = try await run.wait() }
        #expect(try await journal.pendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])

        await unblock.open()
        try await run.waitForDrain()
        try await journal.close()

        let reopened = try openTestJournal(at: journalURL)
        #expect(try await reopened.recoverPendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        #expect(try String(contentsOf: effectURL, encoding: .utf8) == "effect\n")
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func executorReturningAtToolDeadlineIsRejectedByScheduler(atRunDeadline: Bool) async throws {
        let clock = ManualAgentClock.current
        let completedFlag = ClockTestFlag()
        let toolTimeout: Duration = atRunDeadline ? .seconds(10) : .milliseconds(300)
        let runDeadline = clock.after(atRunDeadline ? .milliseconds(300) : .seconds(10))

        let tool = try DirectReadTool(timeout: toolTimeout) {
            // Reach the exact tool deadline inside the executor right before returning a value.
            clock.advance(by: .milliseconds(300))
            return "too-late"
        }
        let call = ToolCall(
            id: .init(rawValue: "at-deadline-call"),
            name: DirectReadTool.name,
            argumentsJSON: #"{"id":"item-2"}"#,
            completeness: .complete
        )
        let sessionID = UUID()
        let runID = UUID()
        let prepared = try ToolRegistry(tools: [AnyAgentTool(tool)]).prepare(
            call,
            context: ToolContext(sessionID: sessionID, runID: runID, callID: call.id, deadline: runDeadline)
        )
        let scheduler = ToolScheduler()

        let expected: ToolSchedulerError = atRunDeadline ? .deadlineExceeded : .toolTimedOut(call.id)
        await #expect(throws: expected) {
            try await scheduler.execute(
                [prepared],
                deadline: runDeadline,
                onStarted: { _ in },
                onCompleted: { _, _, _ in completedFlag.set() },
                onFailed: { _, _ in }
            )
        }
        #expect(!completedFlag.isSet)
        await scheduler.waitForRunToDrain(sessionID: sessionID, runID: runID)
    }

    @Test(arguments: [false, true])
    func executorReturningPastDeadlineBeforeTimerFiresIsRejectedByDeadlineGate(atRunDeadline: Bool) async throws {
        let clock = SplitAdvanceClock()
        try await AgentClock.$source.withValue(clock) {
            let completedFlag = ClockTestFlag()
            let toolTimeout: Duration = atRunDeadline ? .seconds(10) : .milliseconds(300)
            let runDeadline = clock.after(atRunDeadline ? .milliseconds(300) : .seconds(10))
            let expectedToolDeadline = clock.after(.milliseconds(300))

            let tool = try DirectReadTool(timeout: toolTimeout) {
                // Ensure the timer is parked before advancing monotonic `now` without waking it.
                await clock.waitForSleeper(until: expectedToolDeadline)
                clock.advanceNowWithoutWakingSleepers(by: .milliseconds(300))
                return "too-late-before-timer"
            }
            let call = ToolCall(
                id: .init(rawValue: "past-deadline-no-timer"),
                name: DirectReadTool.name,
                argumentsJSON: #"{"id":"item-3"}"#,
                completeness: .complete
            )
            let sessionID = UUID()
            let runID = UUID()
            let prepared = try ToolRegistry(tools: [AnyAgentTool(tool)]).prepare(
                call,
                context: ToolContext(sessionID: sessionID, runID: runID, callID: call.id, deadline: runDeadline)
            )
            let scheduler = ToolScheduler()

            let expected: ToolSchedulerError = atRunDeadline ? .deadlineExceeded : .toolTimedOut(call.id)
            await #expect(throws: expected) {
                try await scheduler.execute(
                    [prepared],
                    deadline: runDeadline,
                    onStarted: { _ in },
                    onCompleted: { _, _, _ in completedFlag.set() },
                    onFailed: { _, _ in }
                )
            }
            #expect(!completedFlag.isSet)
            await scheduler.waitForRunToDrain(sessionID: sessionID, runID: runID)
        }
    }

    @Test func mutationExecutorReturningAtToolDeadlineFailsRunAndQuarantinesInJournal() async throws {
        let journalURL = temporaryURL("late-return-journal")
        let effectURL = temporaryURL("late-return-effect")
        defer {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: effectURL)
        }
        try Data().write(to: effectURL)

        let clock = ManualAgentClock.current
        let executorProbe = ToolInvocationProbe()
        let toolTimeout = Duration.milliseconds(300)
        let tool = try TimedMutationTool(
            timeout: toolTimeout,
            file: effectURL,
            probe: executorProbe,
            onExecute: {
                // Advance the clock right to the tool deadline before returning a receipt.
                clock.advance(by: toolTimeout)
            }
        )
        let call = ToolCall(
            id: .init(rawValue: "late-mutation"),
            name: TimedMutationTool.name,
            argumentsJSON: #"{"id":"record-late"}"#,
            completeness: .complete
        )
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [call]) : textResponse(request, "should not run")
        }
        let journal = try makeTestJournal(at: journalURL)
        let agent = try Agent(
            model: fixtureModel,
            provider: provider,
            tools: [tool],
            configuration: AgentConfiguration(runTimeout: .seconds(10))
        )
        let sessionID = UUID()
        let run = try await agent.makeSession(id: sessionID, journal: journal)
            .run("Mutate at boundary", operationID: "late-return-op")

        await #expect(throws: AgentLoopError.toolTimedOut(call.id)) { _ = try await run.wait() }
        try await run.waitForDrain()
        #expect(await provider.log.requests.count == 1)
        #expect(try await journal.pendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        try await journal.close()

        let reopened = try openTestJournal(at: journalURL)
        #expect(try await reopened.recoverPendingMutations(sessionID: sessionID).map(\.state) == [.needsReconciliation])
        try await reopened.close()
    }

    // MARK: - AgentJournalError.commitUnknown preservation through deadline helpers

    @Test func onlyCommitUnknownPreservesOverDeadlineAndCancellation() {
        #expect(AgentJournalError.commitUnknown.preservesOverDeadlineAndCancellation)
        #expect(!AgentJournalError.persistenceUnavailable("disk full").preservesOverDeadlineAndCancellation)
        #expect(!AgentJournalError.deadlineExceeded.preservesOverDeadlineAndCancellation)
        #expect(!AgentJournalError.storeClosed.preservesOverDeadlineAndCancellation)
        #expect(!AgentJournalError.concurrentWriter.preservesOverDeadlineAndCancellation)
    }

    @Test func commitUnknownPreservedWhenThrownPastDeadline() async throws {
        let clock = SplitAdvanceClock()
        await AgentClock.$source.withValue(clock) {
            let firstDeadline = clock.after(.milliseconds(300))
            await #expect(throws: AgentJournalError.commitUnknown) {
                _ = try await withAgentDeadline(firstDeadline) { () async throws -> Int in
                    await clock.waitForSleeper(until: firstDeadline)
                    clock.advanceNowWithoutWakingSleepers(by: .milliseconds(300))
                    throw AgentJournalError.commitUnknown
                }
            }

            let secondDeadline = clock.after(.milliseconds(300))
            await #expect(throws: AgentJournalError.commitUnknown) {
                _ = try await withOperationDeadline(secondDeadline, timeoutError: AgentLoopError.deadlineExceeded) { () async throws -> Int in
                    await clock.waitForSleeper(until: secondDeadline)
                    clock.advanceNowWithoutWakingSleepers(by: .milliseconds(300))
                    throw AgentJournalError.commitUnknown
                }
            }

            let thirdDeadline = clock.after(.milliseconds(300))
            await #expect(throws: AgentLoopError.deadlineExceeded) {
                _ = try await withAgentDeadline(thirdDeadline) { () async throws -> Int in
                    await clock.waitForSleeper(until: thirdDeadline)
                    clock.advanceNowWithoutWakingSleepers(by: .milliseconds(300))
                    throw AgentJournalError.persistenceUnavailable("disk unavailable")
                }
            }
        }
    }

    @Test func commitUnknownPreservedWhenDeadlineExpiresDuringOnOperationFinished() async throws {
        let clock = ManualAgentClock.current
        let deadline = clock.after(.milliseconds(300))
        let enteredFinished = ClockTestSignal()
        let releaseFinished = ClockTestSignal()
        let workerCancelled = ClockTestSignal()

        let task = Task<Int, Error> {
            try await withAgentDeadline(
                deadline,
                operation: { throw AgentJournalError.commitUnknown },
                onOperationFinished: {
                    await withTaskCancellationHandler {
                        await enteredFinished.signal()
                        await releaseFinished.wait()
                    } onCancel: {
                        Task { await workerCancelled.signal() }
                    }
                }
            )
        }

        await enteredFinished.wait()
        await clock.waitForSleeper(until: deadline)
        clock.advance(by: .milliseconds(300))
        await workerCancelled.wait()
        await Task.yield()
        await releaseFinished.signal()

        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await task.value }
    }

    @Test func commitUnknownPreservedWhenEnclosingTaskIsCancelled() async throws {
        let clock = ManualAgentClock.current
        let deadline = clock.after(.seconds(10))
        let enteredFinished = ClockTestSignal()
        let releaseFinished = ClockTestSignal()
        let workerCancelled = ClockTestSignal()

        let task = Task<Int, Error> {
            try await withAgentDeadline(
                deadline,
                operation: { throw AgentJournalError.commitUnknown },
                onOperationFinished: {
                    await withTaskCancellationHandler {
                        await enteredFinished.signal()
                        await releaseFinished.wait()
                    } onCancel: {
                        Task { await workerCancelled.signal() }
                    }
                }
            )
        }

        await enteredFinished.wait()
        task.cancel()
        await workerCancelled.wait()
        await Task.yield()
        await releaseFinished.signal()

        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await task.value }
    }

    @Test func persistenceUnavailableStillReplacedByDeadlineAndCancellation() async throws {
        let clock = ManualAgentClock.current

        // Deadline expiring during onOperationFinished replaces persistenceUnavailable with deadlineExceeded.
        do {
            let deadline = clock.after(.milliseconds(300))
            let enteredFinished = ClockTestSignal()
            let releaseFinished = ClockTestSignal()

            let task = Task<Int, Error> {
                try await withAgentDeadline(
                    deadline,
                    operation: { throw AgentJournalError.persistenceUnavailable("io error") },
                    onOperationFinished: {
                        await enteredFinished.signal()
                        await releaseFinished.wait()
                    }
                )
            }
            defer { Task { await releaseFinished.signal() } }

            await enteredFinished.wait()
            await clock.waitForSleeper(until: deadline)
            clock.advance(by: .milliseconds(300))

            await #expect(throws: AgentLoopError.deadlineExceeded) { _ = try await task.value }
        }

        // Task cancellation during onOperationFinished replaces persistenceUnavailable with CancellationError.
        do {
            let deadline = clock.after(.seconds(10))
            let enteredFinished = ClockTestSignal()
            let releaseFinished = ClockTestSignal()

            let task = Task<Int, Error> {
                try await withAgentDeadline(
                    deadline,
                    operation: { throw AgentJournalError.persistenceUnavailable("io error") },
                    onOperationFinished: {
                        await enteredFinished.signal()
                        await releaseFinished.wait()
                    }
                )
            }
            defer { Task { await releaseFinished.signal() } }

            await enteredFinished.wait()
            task.cancel()

            await #expect(throws: CancellationError.self) { _ = try await task.value }
        }
    }

    private func temporaryURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    }
}

// MARK: - Local deterministic fixtures

private actor LeaseReleaseProbe {
    struct Entry: Sendable {
        let sessionID: UUID
        let runID: UUID
        let callID: ToolCallID
        let now: ContinuousClock.Instant
    }

    private(set) var entries: [Entry] = []

    func record(sessionID: UUID, runID: UUID, callID: ToolCallID, now: ContinuousClock.Instant) {
        entries.append(Entry(sessionID: sessionID, runID: runID, callID: callID, now: now))
    }
}

private actor ToolInvocationProbe {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor SchedulerFailureProbe {
    private(set) var lastError: (any Error)?
    func record(_ error: any Error) { lastError = error }
}

private actor DirectOutputProbe {
    private(set) var output: JSONValue?
    func record(_ value: JSONValue) { output = value }
}

private struct TimedMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "timed_mutation"
    static let description = "Apply a durable mutation with deterministic timing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])

    let policy: ToolPolicy
    let file: URL
    let probe: ToolInvocationProbe
    let onExecute: @Sendable () async throws -> Void

    init(
        timeout: Duration,
        file: URL,
        probe: ToolInvocationProbe,
        onExecute: @escaping @Sendable () async throws -> Void
    ) throws {
        self.file = file
        self.probe = probe
        self.onExecute = onExecute
        policy = try .mutation(timeout: timeout, authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "fixture.record", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "fixture.record", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.increment()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("effect\n".utf8))
        try handle.synchronize()
        try handle.close()
        try await onExecute()
        return ToolResult(
            output: Output(updated: true),
            receipt: ToolReceipt(
                operationID: context.idempotencyKey ?? "",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "fixture.record", id: input.id)],
                revision: "v1"
            )
        )
    }
}

private struct DirectReadTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String

    static let name = "direct_read"
    static let description = "Read a fixture value under deterministic clock control"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string

    let policy: ToolPolicy
    let run: @Sendable () async throws -> String

    init(timeout: Duration, run: @escaping @Sendable () async throws -> String) throws {
        self.run = run
        policy = try ToolPolicy(
            effect: .readOnly,
            execution: .exclusive,
            idempotency: .safe,
            timeout: timeout,
            authorization: .notRequired
        )
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        ToolResult(output: try await run())
    }
}

private final class SplitAdvanceClock: AgentClockSource, @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset = Duration.zero
    private var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []
    private var instantWaiters: [(instant: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Never>)] = []

    var now: ContinuousClock.Instant { lock.withLock { origin.advanced(by: offset) } }

    func after(_ duration: Duration) -> ContinuousClock.Instant { now.advanced(by: duration) }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var ready: [CheckedContinuation<Void, Never>] = []
                let outcome: Result<Void, Error>?
                lock.lock()
                if cancelled.remove(id) != nil || Task.isCancelled {
                    outcome = .failure(CancellationError())
                } else if deadline <= origin.advanced(by: offset) {
                    outcome = .success(())
                } else {
                    outcome = nil
                    sleepers[id] = (deadline, continuation)
                    ready = instantWaiters.filter { $0.instant == deadline }.map(\.continuation)
                    instantWaiters.removeAll { $0.instant == deadline }
                }
                lock.unlock()
                if let outcome { continuation.resume(with: outcome) }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper.continuation }
                cancelled.insert(id)
                return nil
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }

    func waitForSleeper(until instant: ContinuousClock.Instant) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if sleepers.values.contains(where: { $0.deadline == instant }) { return true }
                instantWaiters.append((instant, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Moves monotonic `now` forward without waking pending timer sleepers.
    func advanceNowWithoutWakingSleepers(by duration: Duration) {
        lock.withLock { offset += duration }
    }
}
