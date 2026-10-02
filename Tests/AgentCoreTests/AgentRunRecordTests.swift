@testable import AgentCore
@testable import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentRunRecordTests {
    @Test func admissionAndTerminalAreQueryableWithoutAWaiter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("run-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "records", supportsRunRecords: true)
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let key = try AgentRunCorrelation(key: "attempt/1", payloadDigest: "host-config-v1")
        #expect(try await session.runRecord(correlationKey: key.key) == .notAdmitted)
        let run = try await session.run("exact text", correlation: key)
        // Drain is observed, but no caller of wait() is needed to publish the terminal.
        try await run.waitForDrain()
        guard case .terminal(let record, .completed) = try await session.runRecord(correlationKey: key.key) else {
            Issue.record("missing completed fact"); return
        }
        #expect(record.runID == run.id && record.sessionID == session.id)
        #expect(try await journal.runRecord(sessionID: session.id, runID: run.id) == .terminal(record, .completed))
        await #expect(throws: AgentRunAdmissionError.alreadyAdmitted(record)) { try await session.run("exact text", correlation: key) }
        await #expect(throws: AgentRunAdmissionError.conflict(record)) { try await session.run("different text", correlation: key) }
        await #expect(throws: AgentRunAdmissionError.conflict(record)) { try await session.run("exact text", correlation: .init(key: key.key, payloadDigest: "other-config")) }
        await #expect(throws: AgentRunAdmissionError.conflict(record)) { try await session.run("exact text", operationID: "logical-operation", correlation: key) }
        #expect(await provider.log.requests.count == 1)
        _ = try await journal.requestMaintenance()
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.runRecord(sessionID: session.id, correlationKey: key.key) == .terminal(record, .completed))
        try await reopened.close()
    }

    @Test func preparedButNotAdmittedAndConcurrentStartupStayDistinct() async throws {
        let h = try Harness()
        defer { h.remove() }
        let gate = RecordGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(journal: h.journal, startupCommitWillBegin: { _ in await gate.hold() })
        let correlation = try AgentRunCorrelation(key: "attempt/1", payloadDigest: "same")
        let first = Task { try await session.run("same", correlation: correlation) }
        #expect(await gate.waitUntilEntered())
        #expect(try await session.runRecord(correlationKey: correlation.key) == .notAdmitted)
        await #expect(throws: AgentRunAdmissionError.admissionInProgress) { try await session.run("same", correlation: correlation) }
        let replacement = try agent.makeSession(id: session.id, journal: h.journal)
        await #expect(throws: AgentRunAdmissionError.admissionInProgress) { try await replacement.run("same", correlation: correlation) }
        #expect(await provider.log.requests.isEmpty)
        await gate.release()
        let run = try await first.value
        try await run.waitForDrain()
        guard case .terminal(let record, .completed) = try await session.runRecord(runID: run.id) else { Issue.record("missing record"); return }
        await #expect(throws: AgentRunAdmissionError.alreadyAdmitted(record)) { try await replacement.run("same", correlation: correlation) }
        #expect(await provider.log.requests.count == 1)
        try await h.journal.close()
    }

    @Test func admittedRunAndCancelledWaiterDoNotInventCancellation() async throws {
        let h = try Harness(); defer { h.remove() }
        let gate = RecordGate()
        let provider = ScriptedProvider { request, _ in await gate.hold(); return textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: h.journal)
        let correlation = try AgentRunCorrelation(key: "attempt/1", payloadDigest: "same")
        let run = try await session.run("same", correlation: correlation)
        #expect(await gate.waitUntilEntered())
        guard case .admitted(let record) = try await session.runRecord(correlationKey: correlation.key) else { Issue.record("not admitted"); return }
        let waiter = Task { try await run.wait() }; waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try await session.runRecord(runID: run.id) == .admitted(record))
        await #expect(throws: AgentRunAdmissionError.conflict(record)) { try await session.run("other actual text", correlation: correlation) }
        await gate.release(); try await run.waitForDrain()
        #expect(try await session.runRecord(runID: run.id) == .terminal(record, .completed))
        #expect(await provider.log.requests.count == 1)
        try await h.journal.close()
    }

    @Test(arguments: [StopReason.endTurn, .refusal, .maxOutputTokens])
    func terminalOutcomesPreserveDistinctions(_ reason: StopReason) async throws {
        let h = try Harness(); defer { h.remove() }
        let provider = ScriptedProvider { request, _ in
            var events = textResponse(request, "result")
            // Use the exact accumulated fixture response identity.
            if case .responseCompleted(let response)? = events.last {
                events[events.count - 1] = .responseCompleted(.init(info: response.info, content: response.content, usage: response.usage, stopReason: reason))
            }
            return events
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: h.journal)
        let run = try await session.run("go")
        try await run.waitForDrain()
        guard case .terminal(_, let terminal) = try await session.runRecord(runID: run.id) else { Issue.record("missing terminal"); return }
        #expect(terminal == (reason == .endTurn ? .completed : reason == .refusal ? .refused : .incomplete(.maxOutputTokens)))
        try await h.journal.close()
    }

    @Test func providerErrorIsSanitizedAndAdmissionFailureLeavesNoRecord() async throws {
        let h = try Harness(); defer { h.remove() }
        let provider = ScriptedProvider { _, _ in throw ModelProviderError(kind: .contextWindowExceeded, message: "credential-secret-raw-provider-body") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: h.journal)
        let key = try AgentRunCorrelation(key: "failure", payloadDigest: "same")
        await #expect(throws: AgentSessionError.emptyInput) { try await session.run("", correlation: key) }
        #expect(try await session.runRecord(correlationKey: key.key) == .notAdmitted)
        let run = try await session.run("go", correlation: key)
        await #expect(throws: ModelProviderError.self) { try await run.wait() }
        try await run.waitForDrain()
        guard case .terminal(_, .failed(.provider)) = try await session.runRecord(runID: run.id) else { Issue.record("missing sanitized failure"); return }
        let enumerator = FileManager.default.enumerator(at: h.directory, includingPropertiesForKeys: [.isRegularFileKey])!
        for file in enumerator.allObjects.compactMap({ $0 as? URL }) {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                #expect(!(try Data(contentsOf: file)).contains(Data("credential-secret-raw-provider-body".utf8)))
            }
        }
        try await h.journal.close()
    }

    @Test func budgetFailureAndRunCancellationHaveSeparateFacts() async throws {
        let h = try Harness(); defer { h.remove() }
        let looping = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "unique-\(UUID())"), name: "add", argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)]) }
        let limited = try Agent(model: fixtureModel, provider: looping, tools: [try AddTool(log: EffectLog())]).makeSession(journal: h.journal)
        let run = try await limited.run("go", budget: try .init(maxModelTurns: 1, maxToolCalls: 4, deadline: .now.advanced(by: .seconds(10))))
        await #expect(throws: AgentLoopError.modelTurnLimitReached) { try await run.wait() }; try await run.waitForDrain()
        guard case .terminal(_, .incomplete(.modelTurnLimit)) = try await limited.runRecord(runID: run.id) else { Issue.record("missing budget fact"); return }
        let gate = RecordGate()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "slow"), name: RecordSlowTool.name, argumentsJSON: "{}", completeness: .complete)]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try RecordSlowTool(gate: gate)]).makeSession(journal: h.journal)
        let cancelled = try await session.run("go")
        #expect(await gate.waitUntilEntered()); await cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.wait() }
        guard case .terminal(_, .cancelled) = try await session.runRecord(runID: cancelled.id) else { Issue.record("missing cancelled fact"); return }
        // Logical terminal is readable while the physical Provider worker is still held.
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await h.journal.close() }
        await gate.release(); try await cancelled.waitForDrain(); try await h.journal.close()
    }

    @Test func deadlineIsLogicalIncompleteBeforePhysicalDrain() async throws {
        let h = try Harness(); defer { h.remove() }
        let gate = RecordGate()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "slow"), name: RecordSlowTool.name, argumentsJSON: "{}", completeness: .complete)]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try RecordSlowTool(gate: gate)]).makeSession(journal: h.journal)
        let run = try await session.run("go", budget: .init(maxModelTurns: 2, maxToolCalls: 1, deadline: .now.advanced(by: .seconds(2))))
        #expect(await gate.waitUntilEntered())
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await run.wait() }
        guard case .terminal(_, .incomplete(.deadline)) = try await session.runRecord(runID: run.id) else { Issue.record("missing deadline fact"); await gate.release(); return }
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await h.journal.close() }
        await gate.release(); try await run.waitForDrain(); try await h.journal.close()
    }

    @Test(arguments: [false, true])
    func retainedSteeringFailureResolvesBeforeTerminal(_ unknown: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retained-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = RecordArmedFault(unknown: unknown)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "retained", supportsRunRecords: true, fault: { try fault.check($0) })
        let gate = RecordGate()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "slow"), name: RecordSlowTool.name, argumentsJSON: "{}", completeness: .complete)]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try RecordSlowTool(gate: gate)]).makeSession(journal: journal)
        let run = try await session.run("original")
        #expect(await gate.waitUntilEntered())
        let correction = try await run.steer("retained correction")
        fault.arm(); await run.cancel()
        await #expect(throws: unknown ? AgentJournalError.commitUnknown : .persistenceUnavailable("retained fixture")) { try await run.wait() }
        if unknown {
            await #expect(throws: AgentJournalError.commitUnknown) { try await session.runRecord(runID: run.id) }
        } else {
            guard case .terminal(_, .failed(.journal)) = try await session.runRecord(runID: run.id) else { Issue.record("premature terminal"); await gate.release(); return }
        }
        await gate.release(); try await run.waitForDrain(); try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        if unknown {
            guard case .admitted = try await reopened.runRecord(sessionID: session.id, runID: run.id) else { Issue.record("unknown retention invented terminal"); return }
            #expect(try await reopened.latestCheckpoint(sessionID: session.id)?.steeringIDs == [correction])
        }
        try await reopened.close()
    }

    @Test(arguments: [false, true])
    func terminalPublicationFailureIsVisibleAndDoesNotForgeCompletion(_ unknown: Bool) async throws {
        let fault = RecordTerminalFault(unknown: unknown)
        let h = try Harness(fault: fault); defer { h.remove() }
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: h.journal)
        let key = try AgentRunCorrelation(key: "failure", payloadDigest: "same")
        let run = try await session.run("go", correlation: key)
        await #expect(throws: unknown ? AgentJournalError.commitUnknown : .persistenceUnavailable("terminal fixture")) { try await run.wait() }
        try await run.waitForDrain()
        if unknown {
            await #expect(throws: AgentJournalError.commitUnknown) { try await session.runRecord(correlationKey: key.key) }
        } else {
            guard case .admitted = try await session.runRecord(correlationKey: key.key) else { Issue.record("false terminal"); return }
        }
        try await h.journal.close()
        let reopened = try AgentIncrementalJournal.open(at: h.directory)
        let lookup = try await reopened.runRecord(sessionID: session.id, correlationKey: key.key)
        if unknown { guard case .terminal(_, .completed) = lookup else { Issue.record("committed terminal lost"); return } }
        else { guard case .admitted = lookup else { Issue.record("uncommitted terminal forged"); return } }
        #expect(await provider.log.requests.count == 1)
        try await reopened.close()
    }

    @Test func uncertainAdmissionPreservesOwnerAndQueriesThrowUntilReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("startup-record-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = RecordArmedFault(unknown: true)
        let journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "startup", supportsRunRecords: true, fault: { try fault.check($0) })
        let provider = ScriptedProvider { request, _ in textResponse(request, "never") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let key = try AgentRunCorrelation(key: "startup", payloadDigest: "same")
        fault.arm()
        let run = try await session.run("go", correlation: key)
        await #expect(throws: AgentJournalError.commitUnknown) { try await run.wait() }
        await #expect(throws: AgentJournalError.commitUnknown) { try await session.runRecord(correlationKey: key.key) }
        #expect(await provider.log.requests.isEmpty)
        try await run.waitForDrain(); try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        guard case .admitted(let record) = try await reopened.runRecord(sessionID: session.id, correlationKey: key.key) else { Issue.record("uncertain startup fabricated terminal"); return }
        #expect(record.runID == run.id)
        let replacement = try Agent(model: fixtureModel, provider: provider).makeSession(id: session.id, journal: reopened)
        await #expect(throws: AgentRunAdmissionError.alreadyAdmitted(record)) { try await replacement.run("go", correlation: key) }
        #expect(await provider.log.requests.isEmpty)
        try await reopened.close()
    }

    @Test func unavailableAndOldStoresNeverAnswerNotAdmitted() async throws {
        let memory = AgentJournal()
        await #expect(throws: AgentJournalError.unsupportedFormat) { try await memory.runRecord(sessionID: UUID(), runID: UUID()) }
        let h = try Harness(); defer { h.remove() }; try await h.journal.close()
        await #expect(throws: AgentJournalError.storeClosed) { try await h.journal.runRecord(sessionID: UUID(), correlationKey: "absent") }
        let oldDirectory = h.directory.appendingPathExtension("old")
        defer { try? FileManager.default.removeItem(at: oldDirectory) }
        let old = try AgentIncrementalJournal.create(at: oldDirectory, operationDomain: "old")
        let session = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "done") }).makeSession(journal: old)
        let run = try await session.run("old run"); try await run.waitForDrain()
        await #expect(throws: AgentJournalError.unsupportedFormat) { try await session.runRecord(runID: run.id) }
        await #expect(throws: AgentJournalError.unsupportedFormat) { try await session.run("new", correlation: .init(key: "key", payloadDigest: "same")) }
        try await old.close()
    }

    @Test(arguments: ["run-correlations", "run-admissions", "run-terminals", "messages"])
    func lostPublishedIndexCannotBecomeNotAdmitted(_ index: String) async throws {
        let h = try Harness(); defer { h.remove() }
        let session = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "done") }).makeSession(journal: h.journal)
        let key = try AgentRunCorrelation(key: "key", payloadDigest: "same")
        let run = try await session.run("go", correlation: key); try await run.waitForDrain(); try await h.journal.close()
        let indexDirectory = h.directory.appendingPathComponent(index)
        let files = FileManager.default.enumerator(at: indexDirectory, includingPropertiesForKeys: [.isRegularFileKey])!
        for file in files.allObjects.compactMap({ $0 as? URL }) {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try FileManager.default.removeItem(at: file) }
        }
        let reopened = try AgentIncrementalJournal.open(at: h.directory)
        await #expect(throws: AgentJournalError.invalidRecord) { try await reopened.runRecord(sessionID: session.id, correlationKey: key.key) }
        await #expect(throws: AgentJournalError.invalidRecord) { try await reopened.runRecord(sessionID: session.id, runID: run.id) }
        try await reopened.close()
    }


    @Test(arguments: [false, true])
    func settledMutationCannotBeRepeatedBecauseTerminalWriteFailed(_ operation: Bool) async throws {
        let fault = RecordTerminalFault(unknown: false)
        let h = try Harness(fault: fault); defer { h.remove() }
        let file = h.directory.appendingPathComponent("external-effect")
        let calls = RecordCalls()
        let provider = ScriptedProvider { request, _ in
            if request.messages.last?.role == .user { return toolResponse(request, [.init(id: .init(rawValue: "write"), name: RecordWriteTool.name, argumentsJSON: "{}", completeness: .complete)]) }
            return textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [try RecordWriteTool(file: file, calls: calls)])
        let id = UUID(), session = try agent.makeSession(id: id, journal: h.journal)
        let key = try AgentRunCorrelation(key: "attempt/1", payloadDigest: "same")
        let run = try await session.run("write", operationID: operation ? "stable" : nil, correlation: key)
        await #expect(throws: AgentJournalError.persistenceUnavailable("terminal fixture")) { try await run.wait() }; try await run.waitForDrain()
        #expect(await calls.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect")
        #expect(try await h.journal.pendingMutations().isEmpty)
        guard case .admitted(let record) = try await session.runRecord(runID: run.id) else { Issue.record("admission lost"); return }
        try await h.journal.close()
        let reopened = try AgentIncrementalJournal.open(at: h.directory)
        let restored = try agent.makeSession(id: id, journal: reopened)
        await #expect(throws: AgentRunAdmissionError.alreadyAdmitted(record)) { try await restored.run("write", operationID: operation ? "stable" : nil, correlation: key) }
        #expect(await calls.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect")
        #expect(try await reopened.pendingMutations().isEmpty)
        try await reopened.close()
    }

    @Test func trustedSettlementAfterLogicalTerminationKeepsTheOriginalTerminal() async throws {
        let h = try Harness(); defer { h.remove() }
        let file = h.directory.appendingPathComponent("late-effect")
        let gate = RecordGate(), calls = RecordCalls()
        let provider = ScriptedProvider { request, _ in toolResponse(request, [.init(id: .init(rawValue: "write"), name: RecordWriteTool.name, argumentsJSON: "{}", completeness: .complete)]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try RecordWriteTool(file: file, calls: calls, gate: gate)]).makeSession(journal: h.journal)
        let run = try await session.run("write")
        #expect(await gate.waitUntilEntered()); await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        let original = try await session.runRecord(runID: run.id)
        guard case .terminal(_, .cancelled) = original else { Issue.record("missing logical cancellation"); await gate.release(); return }
        #expect(try await h.journal.pendingMutations().map(\.state) == [.needsReconciliation])
        await gate.release(); try await run.waitForDrain()
        #expect(await calls.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "effect")
        let pending = try #require(try await h.journal.recoverPendingMutations().first)
        // Host observed the actual file and supplies a trusted settlement; lookup itself never does this.
        try await h.journal.reconcileMutation(pending, receipt: .init(operationID: pending.intent.idempotencyKey, status: .succeeded, confirmedTargets: [.init(namespace: "record", id: "file")], revision: "1"), output: .string("written"))
        #expect(try await h.journal.pendingMutations().isEmpty)
        #expect(try await session.runRecord(runID: run.id) == original)
        _ = try await h.journal.requestMaintenance(); try await h.journal.close()
        let reopened = try AgentIncrementalJournal.open(at: h.directory)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: run.id) == original)
        #expect(try await reopened.pendingMutations().isEmpty)
        #expect(await calls.count == 1)
        try await reopened.close()
    }

    @Test func queryingAndCancellingOneSessionDoesNotAffectAnother() async throws {
        let h = try Harness(); defer { h.remove() }
        let gate = RecordGate()
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("slow")]) {
                return toolResponse(request, [.init(id: .init(rawValue: "slow"), name: RecordSlowTool.name, argumentsJSON: "{}", completeness: .complete)])
            }
            return textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [try RecordSlowTool(gate: gate)])
        let a = try agent.makeSession(journal: h.journal), b = try agent.makeSession(journal: h.journal)
        let key = try AgentRunCorrelation(key: "same-key", payloadDigest: "same")
        let first = try await a.run("slow", correlation: key); #expect(await gate.waitUntilEntered())
        let second = try await b.run("fast", correlation: key); try await second.waitForDrain()
        let original = try await b.runRecord(correlationKey: key.key)
        guard case .terminal(_, .completed) = original else { Issue.record("second blocked"); return }
        await first.cancel(); await #expect(throws: CancellationError.self) { try await first.wait() }
        #expect(try await b.runRecord(runID: second.id) == original)
        #expect(try await b.runRecord(runID: first.id) == .notAdmitted)
        await gate.release(); try await first.waitForDrain(); try await h.journal.close()
    }

    @Test(arguments: [AgentOperationIdentity.perCall, .operation("legacy")])
    func followUpRunLookupDoesNotStartDispatchOrReleaseTheBarrier(_ identity: AgentOperationIdentity) async throws {
        let h = try Harness(); defer { h.remove() }
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: h.journal)
        _ = try await session.enqueueFollowUp(.init(inputID: "one", text: "go", identity: identity, configurationRef: "v1"))
        #expect(try await session.runRecord(runID: UUID()) == .notAdmitted)
        #expect(await provider.log.requests.isEmpty)
        let finished = XCTestExpectation(description: "queued run logically finished")
        let dispatch = try await session.startFollowUpDispatch(policy: .init(), resolver: RecordQueueResolver(session: session, provider: provider), onRun: { _, run in
            _ = try? await run.wait(); finished.fulfill()
        })
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed)
        await dispatch.stop(); try await dispatch.waitForDrain()
        let queued = try #require(try await session.followUp(inputID: "one"))
        #expect(queued.identity == identity)
        guard case .admitted(let runID, _) = queued.state,
              case .terminal(let record, .completed) = try await session.runRecord(runID: runID) else { Issue.record("no queued terminal"); return }
        #expect(record.followUpInputID == "one" && record.correlation == nil)
        try await h.journal.close()
        let reopened = try AgentIncrementalJournal.open(at: h.directory)
        #expect(try await reopened.runRecord(sessionID: session.id, runID: runID) == .terminal(record, .completed))
        #expect(await provider.log.requests.count == 1)
        try await reopened.close()
    }

    @Test(arguments: ["", "space key", "control\n", String(repeating: "a", count: 129), "非ASCII"])
    func invalidCorrelationKeysFailBeforeStorage(_ key: String) {
        #expect(throws: AgentRunAdmissionError.invalidCorrelation) { try AgentRunCorrelation(key: key, payloadDigest: "valid") }
    }

    private struct Harness {
        let directory: URL
        let journal: AgentJournal
        init(fault: RecordTerminalFault? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("run-record-\(UUID())")
            if let fault {
                journal = try AgentIncrementalJournal.createForTesting(at: directory, operationDomain: "records", supportsRunRecords: true, fault: { try fault.check($0) })
            } else {
                journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "records", policy: .init(segmentBytes: 1024, maxWorkBytes: 16384, maxUnreclaimedBytes: 65536, maxSegmentBatches: 2), supportsRunRecords: true)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}

private actor RecordGate {
    private let entered = XCTestExpectation(description: "owned operation entered")
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered.fulfill()
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async -> Bool { await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed }
    func release() { open = true; let current = waiters; waiters.removeAll(); current.forEach { $0.resume() } }
}

private final class RecordTerminalFault: @unchecked Sendable {
    private let lock = NSLock()
    private let unknown: Bool
    private var armed = false
    private var fired = false
    init(unknown: Bool) { self.unknown = unknown }
    func check(_ stage: JournalFileFaultStage) throws {
        let fail = lock.withLock { () -> Bool in
            if stage == .beforeRunTerminalPublish { armed = true }
            if armed && !fired && stage == (unknown ? .afterCurrentReplace : .beforeAppend) { fired = true; return true }
            return false
        }
        if fail { throw AgentJournalError.persistenceUnavailable("terminal fixture") }
    }
}

private struct RecordSlowTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "slow_read"
    static let description = "Controlled noncooperative read"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let gate: RecordGate
    let policy: ToolPolicy
    init(gate: RecordGate) throws { self.gate = gate; policy = try .readOnly(timeout: .seconds(60), authorization: .notRequired) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> { await gate.hold(); return .init(output: "late") }
}

private actor RecordCalls { var count = 0; func entered() { count += 1 } }
private struct RecordWriteTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "record_write"
    static let description = "One real temporary file effect"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let file: URL
    let calls: RecordCalls
    let gate: RecordGate?
    let policy: ToolPolicy
    init(file: URL, calls: RecordCalls, gate: RecordGate? = nil) throws { self.file = file; self.calls = calls; self.gate = gate; policy = try .mutation(authorization: .notRequired, evidence: .none) }
    func resourceRequirements(for input: Input) throws -> [ToolResource] { [.named(.init(namespace: "record", id: "file"))] }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? { try .init(targets: [.init(namespace: "record", id: "file")], revision: .present) }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        await calls.entered(); await gate?.hold(); try Data("effect".utf8).write(to: file)
        return .init(output: "written", receipt: .init(operationID: context.idempotencyKey!, status: .succeeded, confirmedTargets: [.init(namespace: "record", id: "file")], revision: "1"))
    }
}
private struct RecordQueueResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: ScriptedProvider
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        let capabilities = try await session.bindCapabilities(identity: "empty", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        return .init(model: try .init(profileID: "fixture", profileRevision: "1", model: fixtureModel, provider: provider, deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")), capabilities: capabilities, expectedConversationRevision: nil)
    }
}

private final class RecordArmedFault: @unchecked Sendable {
    let unknown: Bool
    private let lock = NSLock()
    private var armed = false
    init(unknown: Bool) { self.unknown = unknown }
    func arm() { lock.withLock { armed = true } }
    func check(_ stage: JournalFileFaultStage) throws {
        guard stage == (unknown ? .afterCurrentReplace : .beforeAppend) else { return }
        if lock.withLock({ let fail = armed; armed = false; return fail }) { throw AgentJournalError.persistenceUnavailable("retained fixture") }
    }
}
