@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentCapabilityScopeTests {
    @Test(arguments: [false, true])
    func revokeCancelsCooperativeStartupProjectionOrEstimator(estimator: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-startup-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "cancel-startup")
        let gate = ScopeCancellationGate(cooperative: true)
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession(journal: journal)
        let scope = try await session.bindCapabilities(identity: "startup", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let binding = try AgentModelBinding(profileID: "startup", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: try .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: estimator ? AgentIdentityContextProjector() : ScopeCancellationProjector(gate: gate),
            tokenBudget: estimator ? try AgentContextTokenBudget(maximumContextTokens: 100,
                reservedOutputTokens: 10, estimator: ScopeCancellationEstimator(gate: gate)) : nil)
        let startup = Task { try await session.run("candidate", capabilities: scope, using: binding) }
        await gate.waitUntilEntered()
        await scope.revoke()
        let observed = await gate.waitForCancellation(timeout: 2)
        if !observed { await gate.finishForCleanup() }
        #expect(observed, "Scope revoke must cancel the actual preflight worker")
        await #expect(throws: CancellationError.self) { _ = try await startup.value }
        try await scope.waitForDrain()
        #expect(await session.history.isEmpty)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }

    @Test func revokeSignalsNonCooperativePreflightButRetainsTheRealOwnerUntilExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-startup-noncoop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "noncoop")
        let gate = ScopeCancellationGate(cooperative: false)
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let scope = try await session.bindCapabilities(identity: "startup", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let binding = try AgentModelBinding(profileID: "startup", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: try .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"), projector: ScopeCancellationProjector(gate: gate))
        let startup = Task { try await session.run("candidate", capabilities: scope, using: binding) }
        await gate.waitUntilEntered()
        await scope.revoke()
        let observed = await gate.waitForCancellation(timeout: 2)
        #expect(observed)
        await #expect(throws: CancellationError.self) { _ = try await startup.value }
        #expect(await scope.status().activeRuns == 1)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        let replacement = try agent.makeSession(id: sessionID, journal: journal)
        await #expect(throws: AgentSessionError.runInProgress) { try await replacement.run("replacement") }
        await gate.finishForCleanup()
        try await scope.waitForDrain()
        #expect(await session.history.isEmpty)
        #expect(try await journal.readMessages(sessionID: sessionID).isEmpty)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }

    @Test func scopeDrainIncludesJournalLeaseAndRunDrainForTheLastUser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-drain-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "drain-order")
        let gate = ScopeGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal,
            scopeReleaseDidFinish: { _ in await gate.wait() })
        let scope = try await session.bindCapabilities(identity: "last", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let run = try await session.run("done", capabilities: scope)
        _ = try await run.wait()
        await gate.waitUntilEntered()
        try await scope.waitForDrain()
        #expect(await run.isDrainComplete(), "Scope drain must include Run physical drain completion")
        do {
            try await journal.close()
        } catch {
            Issue.record("Scope drain returned before Journal lease release: \(error)")
        }
        await gate.open()
        try await run.waitForDrain()
    }

    @Test func scopeDrainIncludesStartupFailureLeaseAndSessionIdentityRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-startup-drain-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "startup-drain")
        let cleanupGate = ScopeGate()
        let projectorGate = ScopeCancellationGate(cooperative: true)
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal,
            scopeReleaseDidFinish: { _ in await cleanupGate.wait() })
        let scope = try await session.bindCapabilities(identity: "failed", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let binding = try AgentModelBinding(profileID: "failed", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: try .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: ScopeCancellationProjector(gate: projectorGate))
        let starting = Task { try await session.run("candidate", capabilities: scope, using: binding) }
        await projectorGate.waitUntilEntered()
        await scope.revoke()
        await projectorGate.finishForCleanup()
        await cleanupGate.waitUntilEntered()
        try await scope.waitForDrain()
        let replacement = try agent.makeSession(id: sessionID, journal: journal)
        do {
            let newRun = try await replacement.run("new")
            _ = try await newRun.wait()
            try await newRun.waitForDrain()
        } catch {
            Issue.record("Scope drain returned before Session identity release: \(error)")
        }
        await cleanupGate.open()
        await #expect(throws: (any Error).self) { _ = try await starting.value }
        try await journal.close()
    }

    @Test func revokeAfterStartupPublicationBeforeWorkerInstallationRetainsOwnedRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-handoff-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "handoff")
        let gate = ScopeGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal,
            runWorkerWillStart: { _ in await gate.wait() })
        let scope = try await session.bindCapabilities(identity: "handoff", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let startup = Task { try await session.run("committed input", capabilities: scope) }
        await gate.waitUntilEntered()
        #expect(try await journal.latestCheckpoint(sessionID: sessionID)?.history == [.user([.text("committed input")])])
        await scope.revoke()
        #expect(await scope.status().activeRuns == 1)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.open()
        let run = try await startup.value
        await #expect(throws: CancellationError.self) { _ = try await run.wait() }
        try await scope.waitForDrain()
        #expect(await run.isDrainComplete())
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }

    @Test func revokeAfterPreflightBeforeStartupCommitLeavesNoCandidateInput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-precommit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "precommit")
        let gate = ScopeGate()
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(journal: journal,
            startupCommitWillBegin: { _ in await gate.wait() })
        let scope = try await session.bindCapabilities(identity: "precommit", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let starting = Task { try await session.run("candidate", capabilities: scope) }
        await gate.waitUntilEntered()
        await scope.revoke()
        await gate.open()
        await #expect(throws: AgentCapabilityError.revoked) { _ = try await starting.value }
        try await scope.waitForDrain()
        #expect(await session.history.isEmpty)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }

    @Test func revokeDuringPublishedStartupCommitStillReturnsAnOwnedCancelledRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-publishing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = ScopeIntentCommitGate()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "publishing", fault: { gate.check($0) })
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let session = try agent.makeSession(journal: journal)
        let scope = try await session.bindCapabilities(identity: "publishing", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        gate.arm()
        let starting = Task { try await session.run("committed", capabilities: scope) }
        #expect(await gate.waitUntilEntered())
        await scope.revoke()
        gate.release()
        let run = try await starting.value
        await #expect(throws: CancellationError.self) { _ = try await run.wait() }
        try await scope.waitForDrain()
        #expect(await run.isDrainComplete())
        #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history == [.user([.text("committed")])])
        #expect(await provider.log.requests.isEmpty)
        try await journal.close()
    }

    @Test func uncertainStartupPublicationWithScopeKeepsFailedRunUntilPhysicalDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-unknown-start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fault = ScopeStartupFault()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory,
            operationDomain: "unknown-start", fault: { try fault.check($0) })
        let provider = ScriptedProvider { request, _ in textResponse(request, "unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let sessionID = UUID()
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let scope = try await session.bindCapabilities(identity: "unknown", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        fault.arm()
        let run = try await session.run("maybe committed", capabilities: scope)
        await #expect(throws: AgentJournalError.commitUnknown) { _ = try await run.wait() }
        try await scope.waitForDrain()
        #expect(await run.isDrainComplete())
        #expect(await provider.log.requests.isEmpty)
        // The poisoned handle cannot be used again. OS ownership transfers
        // only after this handle and its owned Run have gone away.
        _ = session
        _ = journal
    }

    @Test func revokeWhileDurableIntentPublishesNeverEntersMutationExecutor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-intent-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let effect = directory.appendingPathComponent("effect.txt")
        try Data().write(to: effect)
        let gate = ScopeIntentCommitGate()
        let journal = try AgentIncrementalJournal.createForTesting(at: directory.appendingPathComponent("journal"),
            operationDomain: "intent-race", supportsAdmissionRejections: true,
            fault: { gate.check($0) })
        let counts = ScopeCounts()
        let call = ToolCall(id: .init(rawValue: "intent-race"), name: ScopeFileMutationTool.name,
                            argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in
            gate.arm()
            return toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(preAdmissionReplanning: .evidenceRejection(toolNames: [ScopeFileMutationTool.name])))
        let session = try agent.makeSession(journal: journal)
        let scope = try await session.bindCapabilities(identity: "write", version: "1",
            backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.named(.init(namespace: "fixture.scope", id: "B"))],
            tools: [.init(id: "write", version: "1", tool: try ScopeFileMutationTool(
                file: effect, gate: ScopeGate(), counts: counts))])
        let run = try await session.run("write", capabilities: scope, operationID: "intent-race")
        #expect(await gate.waitUntilEntered())
        await scope.revoke()
        gate.release()
        await #expect(throws: (any Error).self) { _ = try await run.wait() }
        try await scope.waitForDrain()
        #expect(await counts.executorEntries == 0)
        #expect(await scope.status().finalAdmissions == 0)
        #expect(try String(contentsOf: effect, encoding: .utf8).isEmpty)
        #expect(try await journal.pendingMutations(sessionID: session.id).map(\.state) == [.needsReconciliation])
        try await journal.close()
    }

    @Test func cancellingOneScopeDrainWaiterDoesNotReleaseTheOwnerOrOtherWaiters() async throws {
        let gate = ScopeGate()
        let provider = ScriptedProvider { request, _ in
            await gate.wait()
            return textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let scope = try await session.bindCapabilities(identity: "waiters", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        let run = try await session.run("work", capabilities: scope)
        await gate.waitUntilEntered()
        let abandoned = Task { try await scope.waitForDrain() }
        let retained = Task { try await scope.waitForDrain() }
        await scope.scope.waitUntilWaiterCount(2)
        abandoned.cancel()
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        await scope.scope.waitUntilWaiterCount(1)
        #expect(await scope.status().activeRuns == 1)
        await gate.open()
        #expect(try await run.wait().outcome == .completed)
        try await retained.value
        #expect(await run.isDrainComplete())
    }

    @Test func drainedScopeDoesNotUnlockSharedStoreWhileAnotherScopeRuns() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scope-shared-owner-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "shared-owner")
        let gate = ScopeGate()
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("B")]) { await gate.wait() }
            return textResponse(request, "done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let a = try agent.makeSession(journal: journal)
        let b = try agent.makeSession(journal: journal)
        let aScope = try await a.bindCapabilities(identity: "A", version: "1",
            backendInstanceID: "shared", backendVersion: "1", allowedResources: [], tools: [])
        let bScope = try await b.bindCapabilities(identity: "B", version: "1",
            backendInstanceID: "shared", backendVersion: "1", allowedResources: [], tools: [])
        let bRun = try await b.run("B", capabilities: bScope)
        await gate.waitUntilEntered()
        let aRun = try await a.run("A", capabilities: aScope)
        #expect(try await aRun.wait().outcome == .completed)
        await aScope.revoke()
        try await aScope.waitForDrain()
        #expect(await aRun.isDrainComplete())
        #expect(await bScope.status().activeRuns == 1)
        await #expect(throws: AgentJournalError.sessionLeaseUnavailable) { try await journal.close() }
        await gate.open()
        #expect(try await bRun.wait().outcome == .completed)
        try await bScope.waitForDrain()
        try await journal.close()
    }
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
                                                          operationDomain: "shared-scope-ledger",
                                                          supportsAdmissionRejections: true)
        let gate = ScopeGate()
        let counts = ScopeCounts()
        let call = ToolCall(id: .init(rawValue: "file-write"), name: ScopeFileMutationTool.name,
                            argumentsJSON: #"{"id":"B"}"#, completeness: .complete)
        let provider = ScriptedProvider { request, _ in
            request.messages.last?.role == .tool ? textResponse(request, "done") : toolResponse(request, [call])
        }
        let agent = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(preAdmissionReplanning: .evidenceRejection(toolNames: [ScopeFileMutationTool.name])))
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
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
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

private actor ScopeCancellationGate {
    private let cooperative: Bool
    private let cancelled = XCTestExpectation(description: "startup preflight received cancellation")
    private var entered = false
    private var enteredObservers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Error>?

    init(cooperative: Bool) { self.cooperative = cooperative }

    func wait() async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                entered = true
                let observers = enteredObservers
                enteredObservers.removeAll()
                observers.forEach { $0.resume() }
                if Task.isCancelled && cooperative {
                    self.continuation = nil
                    continuation.resume(throwing: CancellationError())
                }
            }
        }, onCancel: {
            cancelled.fulfill()
            Task { await self.cancelIfCooperative() }
        })
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredObservers.append($0) }
    }

    func waitForCancellation(timeout: TimeInterval) async -> Bool {
        await XCTWaiter.fulfillment(of: [cancelled], timeout: timeout) == .completed
    }

    func finishForCleanup() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    private func cancelIfCooperative() {
        guard cooperative else { return }
        finishForCleanup()
    }
}

private struct ScopeCancellationProjector: AgentContextProjector {
    let gate: ScopeCancellationGate
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        try await gate.wait()
        return try await AgentIdentityContextProjector().project(input)
    }
}

private struct ScopeCancellationEstimator: AgentContextTokenEstimator {
    let gate: ScopeCancellationGate
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        try await gate.wait()
        return .init(inputTokens: 1, accuracy: .estimated)
    }
}

private final class ScopeStartupFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false

    func arm() { lock.lock(); armed = true; lock.unlock() }

    func check(_ stage: JournalFileFaultStage) throws {
        guard case .afterCurrentReplace = stage else { return }
        lock.lock()
        let shouldFail = armed
        armed = false
        lock.unlock()
        if shouldFail { throw AgentJournalError.persistenceUnavailable("synthetic post-publication fault") }
    }
}

private final class ScopeIntentCommitGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered = XCTestExpectation(description: "intent publication reached CURRENT")
    private var armed = false
    private var released = false

    func arm() {
        condition.lock()
        armed = true
        condition.unlock()
    }

    func check(_ stage: JournalFileFaultStage) {
        guard case .afterCurrentReplace = stage else { return }
        condition.lock()
        guard armed else { condition.unlock(); return }
        armed = false
        entered.fulfill()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() async -> Bool {
        await XCTWaiter.fulfillment(of: [entered], timeout: 3) == .completed
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
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
