@testable import AgentCore
@testable import AgentJournalSQLiteStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// SQLite commit/rollback poisoning, synchronized closed/poisoned state transitions,
/// and unified `AgentSession` commit-unknown locking across durable write paths.
@Suite struct SQLiteCommitFaultTests {
    private let backend = SQLiteBackendHarness()

    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-commit-fault-\(label)-\(UUID())")
    }

    private static var fullCapabilities: JournalContractCapabilities {
        .init(
            supportsConfirmedNoEffect: true,
            supportsPerCallFollowUps: true,
            supportsRunRecords: true,
            supportsNativeContext: true,
            supportsContextHandoff: true,
            supportsIncompleteContextHandoff: true
        )
    }

    // MARK: - SQLite store commit, rollback, maintenance, and concurrency faults

    @Test func writeDuringCommitPoisonsStoreUntilReopened() async throws {
        let directory = tempDir("write-during-commit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-write-commit-fault",
            fault: { try fault.check($0) }
        )

        let session = UUID()
        let priorHistory: [ModelMessage] = [.user([.text("prior committed")])]
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: priorHistory, steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )

        let attemptedHistory = priorHistory + [.user([.text("uncertain write")])]
        fault.arm(.duringCommit)
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: attemptedHistory, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
        }
        #expect(fault.firedCount(.duringCommit) == 1)

        try await assertStorePoisoned(journal, sessionID: session)
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let restoredHistory = try #require(try await reopened.latestCheckpoint(sessionID: session)?.history)
        #expect(restoredHistory == priorHistory || restoredHistory == attemptedHistory)
        #expect(Array(restoredHistory.prefix(priorHistory.count)) == priorHistory)
        #expect(try await reopened.readMessages(sessionID: session, after: 0, limit: 50).map(\.message) == restoredHistory)
        #expect(try await reopened.storeStatus() != nil)

        let continued = restoredHistory + [.user([.text("after reopen")])]
        _ = try await reopened.appendCheckpoint(
            [.checkpoint(history: continued, steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == continued)
        try await reopened.close()
    }

    @Test func writeRollbackFailurePoisonsStoreUntilReopened() async throws {
        let directory = tempDir("write-rollback-failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-write-rollback-fault",
            fault: { try fault.check($0) }
        )

        let session = UUID()
        let priorHistory: [ModelMessage] = [.user([.text("prior committed")])]
        _ = try await journal.appendCheckpoint(
            [.checkpoint(history: priorHistory, steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )

        let abortedHistory = priorHistory + [.user([.text("aborted write")])]
        fault.arm(.beforeCommit)
        fault.arm(.duringRollback)
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: abortedHistory, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
        }
        #expect(fault.firedCount(.beforeCommit) == 1)
        #expect(fault.firedCount(.duringRollback) == 1)

        try await assertStorePoisoned(journal, sessionID: session)
        try await journal.close()

        let reopened = try backend.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == priorHistory)
        #expect(try await reopened.readMessages(sessionID: session, after: 0, limit: 50).map(\.message) == priorHistory)
        #expect(try await reopened.storeStatus() != nil)

        let continued = priorHistory + [.user([.text("after rollback reopen")])]
        _ = try await reopened.appendCheckpoint(
            [.checkpoint(history: continued, steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == continued)
        try await reopened.close()
    }

    @Test func maintainDuringCommitPoisonsStoreUntilReopened() async throws {
        let directory = tempDir("maintain-during-commit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-maintain-commit-fault",
            fault: { try fault.check($0) }
        )

        let session = UUID()
        var history: [ModelMessage] = []
        for index in 0..<4 {
            history.append(.user([.text("checkpoint-\(index)")]))
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: history, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
        }

        fault.arm(.duringCommit)
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.requestMaintenance()
        }
        #expect(fault.firedCount(.duringCommit) == 1)

        try await assertStorePoisoned(journal, sessionID: session)
        try await journal.close()

        let reopened = try backend.open(at: directory)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == history)
        #expect(try await reopened.readMessages(sessionID: session, after: 0, limit: 50).map(\.message) == history)
        _ = try await reopened.requestMaintenance()
        let continued = history + [.user([.text("after maintenance reopen")])]
        _ = try await reopened.appendCheckpoint(
            [.checkpoint(history: continued, steeringIDs: [])],
            sessionID: session,
            runID: UUID(),
            durability: .durable
        )
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == continued)
        try await reopened.close()
    }

    @Test func publishIncompleteContextHandoffDuringCommitPoisonsStoreAndLocksSession() async throws {
        let directory = tempDir("incomplete-handoff-during-commit")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-incomplete-handoff-fault",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )
        let provider = SQLiteFixtureProvider { request, _ in
            Self.textResponse(request, "truncated", stop: .maxOutputTokens)
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)

        let incompleteRun = try await session.run("start incomplete")
        #expect(try await incompleteRun.wait().outcome == .incomplete(.maxOutputTokens))
        try await incompleteRun.waitForDrain()
        let beforeMessages = try await journal.readMessages(sessionID: session.id, after: 0, limit: 50).map(\.message)

        fault.arm(.duringCommit)
        let handoff = try await session.handoffToOrdinary(
            using: binding,
            discardingRetiredProviderContinuations: true,
            allowingIncompleteTurn: true
        )
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await handoff.wait() }
        try await handoff.waitForDrain()
        #expect(fault.firedCount(.duringCommit) == 1)

        try await assertStorePoisoned(journal, sessionID: session.id)
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await session.conversationSnapshot() }
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await session.run("after handoff fault") }
        try await journal.close()

        let reopened = try backend.open(at: directory)
        #expect(try await reopened.readMessages(sessionID: session.id, after: 0, limit: 50).map(\.message) == beforeMessages)
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await fresh.conversationSnapshot().messages == beforeMessages)
        try await reopened.close()
    }

    @Test(.timeLimit(.minutes(1))) func concurrentReadersRaceWithDuringCommitFailureAndClose() async throws {
        for iteration in 0..<8 {
            let directory = tempDir("concurrent-poison-close-\(iteration)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let commitFaultEntered = SQLiteSignal()
            let fault = SQLiteFaultController(onFire: { stage in
                if stage == .duringCommit {
                    commitFaultEntered.signal()
                }
            })
            let journal = try backend.create(
                at: directory,
                operationDomain: "sqlite-concurrent-poison-close",
                fault: { try fault.check($0) }
            )

            let session = UUID()
            let seedHistory: [ModelMessage] = [
                .user([.text("seed-\(iteration)")]),
                .assistant(content: [.text("reply-\(iteration)")], toolCalls: []),
            ]
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: seedHistory, steeringIDs: [])],
                sessionID: session,
                runID: UUID(),
                durability: .durable
            )
            let attemptedHistory = seedHistory + [.user([.text("raced-write-\(iteration)")])]

            let readerCount = 6
            let readersActive = SQLiteCountdown(target: readerCount)

            await withTaskGroup(of: Void.self) { group in
                for readerIndex in 0..<readerCount {
                    group.addTask {
                        for step in 0..<24 {
                            if step == 0 {
                                await readersActive.arrive()
                            }
                            if (step + readerIndex).isMultiple(of: 2) {
                                do {
                                    let messages = try await journal.readMessages(
                                        sessionID: session,
                                        after: 0,
                                        limit: 50
                                    ).map(\.message)
                                    let isValid = messages == seedHistory || messages == attemptedHistory
                                    #expect(isValid, "reader observed inconsistent history: \(messages)")
                                } catch let error as AgentJournalError {
                                    let allowed = error == .commitUnknown || error == .storeClosed
                                    #expect(allowed, "unexpected reader journal error: \(error)")
                                } catch {
                                    Issue.record("unexpected reader error: \(error)")
                                }
                            } else {
                                do {
                                    let status = try await journal.storeStatus()
                                    #expect(status != nil)
                                } catch let error as AgentJournalError {
                                    let allowed = error == .commitUnknown || error == .storeClosed
                                    #expect(allowed, "unexpected status journal error: \(error)")
                                } catch {
                                    Issue.record("unexpected status error: \(error)")
                                }
                            }
                        }
                    }
                }

                group.addTask {
                    await readersActive.wait()
                    fault.arm(.duringCommit)
                    do {
                        _ = try await journal.appendCheckpoint(
                            [.checkpoint(history: attemptedHistory, steeringIDs: [])],
                            sessionID: session,
                            runID: UUID(),
                            durability: .durable
                        )
                        Issue.record("writer hitting duringCommit must throw commitUnknown")
                    } catch let error as AgentJournalError {
                        #expect(error == .commitUnknown)
                    } catch {
                        Issue.record("unexpected writer error: \(error)")
                    }
                }

                group.addTask {
                    await commitFaultEntered.wait()
                    do {
                        try await journal.close()
                    } catch {
                        Issue.record("close after duringCommit failed: \(error)")
                    }
                }
            }

            #expect(fault.firedCount(.duringCommit) == 1)

            // Reopening after concurrent poison + close must recover valid durable state cleanly.
            let reopened = try backend.open(at: directory)
            let restored = try #require(try await reopened.latestCheckpoint(sessionID: session)?.history)
            #expect(restored == seedHistory || restored == attemptedHistory)
            #expect(try await reopened.readMessages(sessionID: session, after: 0, limit: 50).map(\.message) == restored)
            try await reopened.close()
        }
    }

    // MARK: - AgentSession unified commitUnknown locking with SQLite

    @Test func sqliteStartupRunCommitUnknownPreservesInMemoryHistoryAndLocksSession() async throws {
        let directory = tempDir("session-startup-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-session-startup-run",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let toolProbe = SQLiteToolProbe()
        let readTool = try SQLiteReadTool(probe: toolProbe)
        let provider = SQLiteFixtureProvider { request, turn in
            if turn == 1 {
                return Self.textResponse(request, "first reply")
            }
            return Self.textResponse(request, "reopened reply")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding, tools: [readTool])
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindReadCapability(session: session, tool: readTool)

        let first = try await session.run("first input")
        _ = try await first.wait()
        try await first.waitForDrain()
        let priorHistory = await session.history
        #expect(priorHistory == [
            .user([.text("first input")]),
            .assistant(content: [.text("first reply")], toolCalls: []),
        ])
        #expect(await provider.requestCount == 1)

        fault.arm(.duringCommit)
        let uncertain = try await session.run("uncertain input")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await uncertain.wait() }
        try await uncertain.waitForDrain()

        #expect(fault.firedCount(.duringCommit) == 1)
        #expect(await provider.requestCount == 1, "provider must not be called when startup commit is unknown")
        #expect(await session.history == priorHistory, "unconfirmed startup input must not mutate session.history")
        #expect(!String(describing: await session.history).contains("uncertain input"))

        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            hostToolName: SQLiteReadTool.name,
            hostToolArguments: #"{"value":"blocked"}"#,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let diskHistory = try #require(try await reopened.latestCheckpoint(sessionID: session.id)?.history)
        let attemptedHistory = priorHistory + [.user([.text("uncertain input")])]
        #expect(diskHistory == priorHistory || diskHistory == attemptedHistory)

        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await fresh.conversationSnapshot().messages == diskHistory)
        let continued = try await fresh.run("after reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == diskHistory + [.user([.text("after reopen")])])
        try await reopened.close()
    }

    @Test func sqliteStartupHostInvocationCommitUnknownPreservesInMemoryHistoryAndLocksSession() async throws {
        let directory = tempDir("session-startup-host")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-session-startup-host",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let toolProbe = SQLiteToolProbe()
        let readTool = try SQLiteReadTool(probe: toolProbe)
        let provider = SQLiteFixtureProvider { request, turn in
            Self.textResponse(request, turn == 1 ? "seed reply" : "reopened reply")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindReadCapability(session: session, tool: readTool)

        let seed = try await session.run("seed input")
        _ = try await seed.wait()
        try await seed.waitForDrain()
        let priorHistory = await session.history

        fault.arm(.duringCommit)
        let invocation = try await session.invokeHostTool(
            AgentHostToolCall(
                name: SQLiteReadTool.name,
                argumentsJSON: #"{"value":"unconfirmed-host"}"#,
                note: "unconfirmed host call request"
            ),
            capabilities: capabilities,
            operationID: "host-startup-fault"
        )
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await invocation.wait() }
        try await invocation.waitForDrain()

        #expect(fault.firedCount(.duringCommit) == 1)
        #expect(await toolProbe.executions == 0, "tool executor must not run when startup commit is unknown")
        #expect(await session.history == priorHistory, "unconfirmed host request must not mutate session.history")
        #expect(!String(describing: await session.history).contains("unconfirmed host call request"))

        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            hostToolName: SQLiteReadTool.name,
            hostToolArguments: #"{"value":"blocked"}"#,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let diskHistory = try #require(try await reopened.latestCheckpoint(sessionID: session.id)?.history)
        #expect(Array(diskHistory.prefix(priorHistory.count)) == priorHistory)

        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        #expect(try await fresh.conversationSnapshot().messages == diskHistory)
        let continued = try await fresh.run("after host reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == diskHistory + [.user([.text("after host reopen")])])
        try await reopened.close()
    }

    @Test func sqliteMidRunCheckpointCommitUnknownLocksSessionUntilReopened() async throws {
        let directory = tempDir("session-midrun-checkpoint")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-session-midrun-checkpoint",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let readTool = try SQLiteReadTool(probe: SQLiteToolProbe())
        let provider = SQLiteFixtureProvider { request, turn in
            if turn == 1 {
                // Startup checkpoint already succeeded before provider execution.
                fault.arm(.duringCommit)
                return Self.textResponse(request, "uncertain final answer")
            }
            return Self.textResponse(request, "continued after reopen")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindReadCapability(session: session, tool: readTool)

        let run = try await session.run("question")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await run.waitForDrain()

        #expect(fault.firedCount(.duringCommit) == 1)
        #expect(await provider.requestCount == 1)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            hostToolName: SQLiteReadTool.name,
            hostToolArguments: #"{"value":"blocked"}"#,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let diskHistory = try #require(try await reopened.latestCheckpoint(sessionID: session.id)?.history)
        let startupOnly: [ModelMessage] = [.user([.text("question")])]
        let withAnswer: [ModelMessage] = startupOnly + [.assistant(content: [.text("uncertain final answer")], toolCalls: [])]
        #expect(diskHistory == startupOnly || diskHistory == withAnswer)

        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let next = try await fresh.run("after reopen")
        _ = try await next.wait()
        try await next.waitForDrain()
        #expect(await provider.lastRequest?.messages == diskHistory + [.user([.text("after reopen")])])
        try await reopened.close()
    }

    @Test func sqliteMidRunMutationSettlementCommitUnknownLocksSessionUntilReopened() async throws {
        let directory = tempDir("session-midrun-mutation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-session-midrun-mutation",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let mutationProbe = SQLiteToolProbe()
        let mutationTool = try SQLiteMutationTool(probe: mutationProbe) {
            // Startup and mutation intent admission have already committed; arm settlement commit fault.
            fault.arm(.duringCommit)
        }
        let readTool = try SQLiteReadTool(probe: SQLiteToolProbe())
        let call = ToolCall(
            id: .init(rawValue: "mutate-1"),
            name: SQLiteMutationTool.name,
            argumentsJSON: #"{"id":"item-1"}"#,
            completeness: .complete
        )
        let provider = SQLiteFixtureProvider { request, turn in
            if turn == 1 {
                return Self.toolResponse(request, [call])
            }
            return Self.textResponse(request, "reopened ok")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding, tools: [mutationTool])
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindReadCapability(session: session, tool: readTool)

        let run = try await session.run("perform mutation", operationID: "sqlite-mutate-op")
        do {
            _ = try await run.wait()
            Issue.record("expected commitUnknown or AgentMutationPersistenceError on settlement commit fault")
        } catch let error as AgentJournalError {
            #expect(error == .commitUnknown)
        } catch let error as AgentMutationPersistenceError {
            #expect(error.settlement == .journal(.commitUnknown))
        } catch {
            Issue.record("unexpected mutation settlement error: \(error)")
        }
        try await run.waitForDrain()

        #expect(fault.firedCount(.duringCommit) == 1)
        #expect(await mutationProbe.executions == 1)
        #expect(await provider.requestCount == 1, "model turn 2 must not run after uncertain mutation settlement")
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            hostToolName: SQLiteReadTool.name,
            hostToolArguments: #"{"value":"blocked"}"#,
            excerptCallID: call.id
        )
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let pending = try await reopened.recoverPendingMutations(sessionID: session.id)
        if let unresolved = pending.first {
            try await reopened.reconcileMutation(
                unresolved,
                receipt: ToolReceipt(
                    operationID: unresolved.intent.idempotencyKey,
                    status: .succeeded,
                    confirmedTargets: [.init(namespace: "commit.fault", id: "item-1")],
                    revision: "rev-1"
                ),
                output: .object(["updated": .bool(true)])
            )
        }
        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let diskHistory = try await fresh.conversationSnapshot().messages
        let continued = try await fresh.run("after mutation reopen")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == diskHistory + [.user([.text("after mutation reopen")])])
        try await reopened.close()
    }

    @Test func sqliteMidRunTerminalRecordCommitUnknownLocksSessionUntilReopened() async throws {
        let directory = tempDir("session-midrun-terminal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = SQLiteFaultController()
        let journal = try backend.create(
            at: directory,
            operationDomain: "sqlite-session-midrun-terminal",
            capabilities: Self.fullCapabilities,
            fault: { try fault.check($0) }
        )

        let readTool = try SQLiteReadTool(probe: SQLiteToolProbe())
        let provider = SQLiteFixtureProvider { request, turn in
            if turn == 1 {
                // Skip the final-answer checkpoint commit and fault the subsequent run-terminal commit.
                fault.arm(.duringCommit, afterSkipping: 1)
                return Self.textResponse(request, "completed text")
            }
            return Self.textResponse(request, "after terminal reopen")
        }
        let binding = try Self.makeBinding(provider: provider)
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await Self.bindReadCapability(session: session, tool: readTool)

        let run = try await session.run("terminal check")
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await run.waitForDrain()

        #expect(fault.firedCount(.duringCommit) == 1)
        try await assertSessionLockedInCommitUnknown(
            session,
            binding: binding,
            capabilities: capabilities,
            hostToolName: SQLiteReadTool.name,
            hostToolArguments: #"{"value":"blocked"}"#,
            excerptCallID: ToolCallID(rawValue: "unused-call")
        )
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let expectedHistory: [ModelMessage] = [
            .user([.text("terminal check")]),
            .assistant(content: [.text("completed text")], toolCalls: []),
        ]
        #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.history == expectedHistory)

        let fresh = try agent.makeSession(id: session.id, journal: reopened)
        let continued = try await fresh.run("next after terminal")
        _ = try await continued.wait()
        try await continued.waitForDrain()
        #expect(await provider.lastRequest?.messages == expectedHistory + [.user([.text("next after terminal")])])
        try await reopened.close()
    }

    // MARK: - Assertions & Fixtures

    private func assertStorePoisoned(_ journal: AgentJournal, sessionID: UUID) async throws {
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.latestCheckpoint(sessionID: sessionID)
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.readMessages(sessionID: sessionID, after: 0, limit: 50)
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.storeStatus()
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.appendCheckpoint(
                [.checkpoint(history: [.user([.text("blocked write")])], steeringIDs: [])],
                sessionID: sessionID,
                runID: UUID(),
                durability: .durable
            )
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await journal.requestMaintenance()
        }
    }

    private func assertSessionLockedInCommitUnknown(
        _ session: AgentSession,
        binding: AgentModelBinding,
        capabilities: AgentCapabilityBinding,
        hostToolName: String,
        hostToolArguments: String,
        excerptCallID: ToolCallID
    ) async throws {
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.conversationSnapshot()
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.run("blocked after commitUnknown")
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.invokeHostTool(
                AgentHostToolCall(name: hostToolName, argumentsJSON: hostToolArguments),
                capabilities: capabilities,
                operationID: "blocked-host"
            )
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.contextHistorySpan(start: 0, count: 1)
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.contextToolExcerpt(callID: excerptCallID, text: "blocked excerpt")
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.compactionBoundaries()
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.handoffToOrdinary(
                using: binding,
                discardingRetiredProviderContinuations: true
            )
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.compact(mode: .openAIStandalone)
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.enqueueFollowUp(.init(
                inputID: "blocked-follow-up",
                text: "blocked",
                operationID: "op-blocked-follow-up",
                configurationRef: "cfg-1"
            ))
        }
        await #expect(throws: AgentJournalError.commitUnknown) {
            _ = try await session.withdrawFollowUp(inputID: "blocked-follow-up")
        }
    }

    private static func makeBinding(provider: SQLiteFixtureProvider) throws -> AgentModelBinding {
        try AgentModelBinding(
            profileID: "sqlite-commit-fault",
            profileRevision: "1",
            model: ModelID(provider: "sqlite-fixture", name: "test"),
            provider: provider,
            deployment: .init(
                serviceInstanceID: "sqlite-commit-fault-deployment",
                endpointScope: "fixture://sqlite-commit-fault",
                apiDialect: "sqlite-fixture"
            )
        )
    }

    private static func bindReadCapability(
        session: AgentSession,
        tool: SQLiteReadTool
    ) async throws -> AgentCapabilityBinding {
        try await session.bindCapabilities(
            identity: "sqlite-commit-fault-host",
            version: "1",
            backendInstanceID: "fixture",
            backendVersion: "1",
            allowedResources: [.global],
            tools: [AgentCapabilityTool(id: "sqlite_read", version: "1", tool: tool)]
        )
    }

    private static func textResponse(
        _ request: ModelRequest,
        _ text: String,
        stop: StopReason = .endTurn
    ) -> [ModelEvent] {
        let info = ResponseInfo(id: "resp-\(UUID().uuidString)", model: request.model)
        return [
            .responseStarted(info),
            .textDelta(text),
            .responseCompleted(.init(info: info, content: [.text(text)], stopReason: stop)),
        ]
    }

    private static func toolResponse(_ request: ModelRequest, _ calls: [ToolCall]) -> [ModelEvent] {
        let info = ResponseInfo(id: "resp-\(UUID().uuidString)", model: request.model)
        var events: [ModelEvent] = [.responseStarted(info)]
        for call in calls {
            events.append(.toolCallStarted(call.id, name: call.name))
            events.append(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
            if call.completeness == .complete {
                events.append(.toolCallCompleted(call))
            }
        }
        events.append(.responseCompleted(.init(info: info, toolCalls: calls, stopReason: .toolCalls)))
        return events
    }
}

private final class SQLiteFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private var armedSkips: [JournalContractFaultStage: Int] = [:]
    private var firedCounts: [JournalContractFaultStage: Int] = [:]
    private let onFire: (@Sendable (JournalContractFaultStage) -> Void)?

    init(onFire: (@Sendable (JournalContractFaultStage) -> Void)? = nil) {
        self.onFire = onFire
    }

    func arm(_ stage: JournalContractFaultStage, afterSkipping skips: Int = 0) {
        lock.withLock {
            armedSkips[stage] = skips
        }
    }

    func firedCount(_ stage: JournalContractFaultStage) -> Int {
        lock.withLock { firedCounts[stage, default: 0] }
    }

    func check(_ stage: JournalContractFaultStage) throws {
        let shouldThrow = lock.withLock { () -> Bool in
            guard let remainingSkips = armedSkips[stage] else { return false }
            if remainingSkips > 0 {
                armedSkips[stage] = remainingSkips - 1
                return false
            }
            armedSkips.removeValue(forKey: stage)
            firedCounts[stage, default: 0] += 1
            return true
        }
        if shouldThrow {
            onFire?(stage)
            throw AgentJournalError.persistenceUnavailable("injected \(stage.rawValue)")
        }
    }
}

private final class SQLiteSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        let toResume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !signaled else { return [] }
            signaled = true
            let current = waiters
            waiters.removeAll()
            return current
        }
        for waiter in toResume { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = lock.withLock { () -> Bool in
                if signaled { return true }
                waiters.append(continuation)
                return false
            }
            if immediate { continuation.resume() }
        }
    }
}

private actor SQLiteCountdown {
    private let target: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(target: Int) { self.target = target }

    func arrive() {
        arrived += 1
        guard arrived >= target else { return }
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        if arrived >= target { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor SQLiteFixtureProvider: ModelProviderCompaction {
    nonisolated let descriptor = ModelProviderDescriptor(
        id: "sqlite-fixture",
        capabilities: [.streaming, .multiTurn, .tools]
    )
    nonisolated let compactionModes: Set<ModelCompactionMode> = [.openAIStandalone]
    nonisolated let automaticCompaction: ModelAutomaticCompaction? = nil
    private let respond: @Sendable (ModelRequest, Int) async throws -> [ModelEvent]
    private var recordedRequests: [ModelRequest] = []

    init(respond: @escaping @Sendable (ModelRequest, Int) async throws -> [ModelEvent]) {
        self.respond = respond
    }

    var requestCount: Int { recordedRequests.count }
    var lastRequest: ModelRequest? { recordedRequests.last }

    private func record(_ request: ModelRequest) -> Int {
        recordedRequests.append(request)
        return recordedRequests.count
    }

    nonisolated func validateCompaction(request: ModelCompactionRequest) throws {}

    nonisolated func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let info = ResponseInfo(id: "compact", model: request.request.model)
                let transition = ModelNativeContextTransition(
                    mode: request.mode,
                    source: request.request.nativeContextSource!,
                    replayPosition: 0,
                    invocationID: request.invocationID,
                    responseID: info.id
                )
                let state = ModelProviderContinuation(
                    model: info.model,
                    format: "sqlite-fixture-native",
                    payload: Data("opaque".utf8),
                    contextTransition: transition
                )
                continuation.yield(.completed(.init(info: info, continuation: state, usage: .init(inputTokens: 4, outputTokens: 1))))
                continuation.finish()
            }
        }
    }

    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let turn = await self.record(request)
            for event in try await self.respond(request, turn) {
                try emit(event)
            }
        }
    }
}

private actor SQLiteToolProbe {
    private(set) var executions = 0
    func recordExecution() { executions += 1 }
}

private struct SQLiteReadTool: AgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let echoed: String }
    static let name = "sqlite_read"
    static let description = "Read-only fixture tool"
    static let inputSchema = ToolSchema.object(properties: ["value": .string], required: ["value"])
    static let outputSchema = ToolSchema.object(properties: ["echoed": .string], required: ["echoed"])
    let probe: SQLiteToolProbe
    let policy: ToolPolicy

    init(probe: SQLiteToolProbe) throws {
        self.probe = probe
        self.policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.recordExecution()
        return ToolResult(output: Output(echoed: input.value))
    }
}

private struct SQLiteMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }
    static let name = "sqlite_mutate"
    static let description = "Mutation fixture tool"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let probe: SQLiteToolProbe
    let beforeReturn: @Sendable () -> Void
    let policy: ToolPolicy

    init(probe: SQLiteToolProbe, beforeReturn: @escaping @Sendable () -> Void) throws {
        self.probe = probe
        self.beforeReturn = beforeReturn
        self.policy = try .mutation(authorization: .notRequired, evidence: .none)
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "commit.fault", id: input.id))]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "commit.fault", id: input.id)], revision: .present)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.recordExecution()
        beforeReturn()
        return ToolResult(
            output: Output(updated: true),
            receipt: ToolReceipt(
                operationID: context.idempotencyKey ?? "",
                status: .succeeded,
                confirmedTargets: [.init(namespace: "commit.fault", id: input.id)],
                revision: "rev-1"
            )
        )
    }
}
