@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

struct AgentPreAdmissionReplanningTests {
    private let policy = AgentPreAdmissionReplanning.evidenceRejection(toolNames: [BoundedTestMutation.name])

    @Test func optInRequiresARejectionCapableStoreBeforeProviderOrInputCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "replan-legacy")
        let provider = rejectionProvider()
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try ResourceDiscovery(), try BoundedTestMutation()],
            configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
        await #expect(throws: AgentSessionError.admissionRejectionJournalRequired) {
            try await session.run("start")
        }
        #expect(await provider.log.requests.isEmpty)
        #expect(try await journal.readMessages(sessionID: session.id).isEmpty)
        try await journal.close()
    }

    @Test func requiredAuditAndBoundedCorrectionKeepSeparateCallInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "replan-audit", supportsAuthorizationAudit: true)
        let authorizer = AuditTestAuthorizer(), provider = rejectionProvider()
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try ResourceDiscovery(), try BoundedTestMutation()],
            configuration: .init(preAdmissionReplanning: policy, authorization: auditTestConfiguration(authorizer: authorizer)))
            .makeSession(journal: journal)
        let run = try await session.run("start")
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(await authorizer.requests.count == 1) // The read, never the Evidence-rejected mutation.
        let facts = try await journal.auditRecords(matching: .init(runID: run.id)).records
        #expect(facts.contains { if case .authorization(let a) = $0.fact { return a.status == .notEvaluated }; return false })
        #expect(Set(facts.map(\.links.invocationID)).count == 2)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func unrelatedPendingDoesNotBlockButSameOperationPendingClosesFeedback() async throws {
        for (related, reconciled) in [(false, false), (true, false), (true, true)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-pending-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "replan-pending",
                supportsAdmissionRejections: true)
            let prior = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(),
                callID: .init(rawValue: "prior"), name: "other_mutation", argumentsJSON: "{}",
                resources: [.global], idempotencyKey: related ? "same-operation/other_mutation/{}" : "unrelated/other_mutation/{}",
                receiptExpectation: .init(targets: [.init(namespace: "resource", id: "prior")]))
            guard case .admitted = try await journal.admit(prior) else {
                Issue.record("fixture failed to publish the prior durable intent"); return
            }
            if reconciled {
                #expect(try await journal.recoverPendingMutations(sessionID: prior.sessionID).map(\.state)
                    == [.needsReconciliation])
            }
            let provider = rejectionProvider()
            let agent = try Agent(model: fixtureModel, provider: provider,
                tools: [try ResourceDiscovery(), try BoundedTestMutation()],
                configuration: .init(preAdmissionReplanning: policy))
            let session = try agent.makeSession(journal: journal)
            let run = try await session.run("start", operationID: "same-operation")
            if related {
                await #expect(throws: EvidenceError.unavailable(.init(namespace: "resource", id: "X"))) {
                    try await run.wait()
                }
                #expect(await provider.log.requests.count == 2)
            } else {
                #expect(try await run.wait().outcome == .completed)
                #expect(await provider.log.requests.count == 3)
            }
            try await run.waitForDrain()
            #expect(try await journal.pendingMutations().count == 1)
            try await journal.close()
        }
    }

    @Test func operationIdentityDoesNotConfuseNestedOrOverlappingIDs() async throws {
        let cases: [(operation: String?, priorIdentity: String, shouldContinue: Bool)] = [
            ("team/a", "team/a/other_mutation/{}", false),
            ("team/a", "team/a-long/other_mutation/{}", true),
            ("team/a", "team/a/child/other_mutation/{}", true),
            ("team/a/child", "team/a/child/other_mutation/{}", false),
            (nil, "team/a/other_mutation/{}", true),
            ("", "team/a/other_mutation/{}", true),
        ]
        for (operation, identity, shouldContinue) in cases {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-identity-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = try AgentIncrementalJournal.create(at: directory,
                operationDomain: "replan-identity", supportsAdmissionRejections: true)
            let prior = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(),
                callID: .init(rawValue: "prior"), name: "other_mutation", argumentsJSON: "{}",
                resources: [.global], idempotencyKey: identity,
                receiptExpectation: .init(targets: [.init(namespace: "resource", id: "prior")]))
            guard case .admitted = try await journal.admit(prior) else { Issue.record("Fixture intent missing"); return }
            let provider = rejectionProvider()
            let session = try Agent(model: fixtureModel, provider: provider,
                tools: [try ResourceDiscovery(), try BoundedTestMutation()],
                configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
            let run = try await session.run("start", operationID: operation)
            if shouldContinue {
                #expect(try await run.wait().outcome == .completed, "\(identity)")
                #expect(await provider.log.requests.count == 3, "\(identity)")
            } else {
                await #expect(throws: EvidenceError.self) { try await run.wait() }
                #expect(await provider.log.requests.count == 2, "\(identity)")
            }
            try await run.waitForDrain()
            try await journal.close()
        }
    }

    @Test func measurePendingLookupAcrossUnrelatedSessions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-query-cost-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory,
            operationDomain: "replan-query-cost", supportsAdmissionRejections: true)
        for sessionCount in [0, 120] {
            if sessionCount > 0 {
                for index in 0..<sessionCount {
                    let request = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(),
                        callID: .init(rawValue: "pending-\(index)"), name: "fixture_mutation",
                        argumentsJSON: "{}", resources: [.global],
                        idempotencyKey: "unrelated-\(index)/fixture_mutation/{}",
                        receiptExpectation: .init(targets: [.init(namespace: "fixture", id: "\(index)")]))
                    guard case .admitted = try await journal.admit(request) else {
                        Issue.record("Failed to seed unrelated pending"); return
                    }
                }
            }
            let prior = try #require(await journal.storageMetrics())
            let priorStart = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<3 { #expect(try await journal.pendingMutations().count == sessionCount) }
            let priorElapsed = DispatchTime.now().uptimeNanoseconds - priorStart
            let priorAfter = try #require(await journal.storageMetrics())
            print("replan-query-cost-original sessions=\(sessionCount) queries=3 bytesRead=\(priorAfter.bytesRead - prior.bytesRead) decodedBatches=\(priorAfter.decodedBatches - prior.decodedBatches) elapsedNs=\(priorElapsed)")
            let before = try #require(await journal.storageMetrics())
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<3 {
                #expect(try await !journal.hasRelatedPendingMutation(sessionID: UUID(),
                    operationID: "target/with-slash"))
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let after = try #require(await journal.storageMetrics())
            print("replan-query-cost-indexed sessions=\(sessionCount) queries=3 bytesRead=\(after.bytesRead - before.bytesRead) decodedBatches=\(after.decodedBatches - before.decodedBatches) elapsedNs=\(elapsed)")
        }
        try await journal.close()
    }

    @Test func indexedOperationTracksMultipleSessionsUntilEachIntentSettles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-multi-operation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AgentIncrementalJournal.create(at: directory,
            operationDomain: "replan-multi-operation", supportsAdmissionRejections: true)
        var requests: [ToolMutationAdmissionRequest] = []
        for id in ["A", "B"] {
            let request = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(),
                callID: .init(rawValue: "call-\(id)"), name: "fixture_mutation",
                argumentsJSON: #"{"id":"\#(id)"}"#, resources: [.global],
                idempotencyKey: #"shared/fixture_mutation/{"id":"\#(id)"}"#,
                receiptExpectation: .init(targets: [.init(namespace: "fixture", id: id)], revision: .present))
            guard case .admitted = try await journal.admit(request) else {
                Issue.record("Expected two independent durable intents"); return
            }
            requests.append(request)
        }
        let observer = UUID()
        #expect(try await journal.hasRelatedPendingMutation(sessionID: observer, operationID: "shared"))
        try await journal.close()
        journal = try AgentIncrementalJournal.open(at: directory)
        #expect(try await journal.hasRelatedPendingMutation(sessionID: observer, operationID: "shared"))
        for (index, request) in requests.enumerated() {
            let id = index == 0 ? "A" : "B"
            try await journal.commitMutation(sessionID: request.sessionID, runID: request.runID,
                callID: request.callID,
                receipt: .init(operationID: request.idempotencyKey, status: .succeeded,
                               confirmedTargets: [.init(namespace: "fixture", id: id)], revision: "1"),
                output: .object(["id": .string(id)]), history: [], steeringIDs: [])
            #expect(try await journal.hasRelatedPendingMutation(sessionID: observer,
                operationID: "shared") == (index == 0))
        }
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await !reopened.hasRelatedPendingMutation(sessionID: observer, operationID: "shared"))
        try await reopened.close()
    }

    @Test func unparseableCrossSessionPendingIdentityFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-unknown-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory,
            operationDomain: "replan-unknown-key", supportsAdmissionRejections: true)
        let request = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(),
            callID: .init(rawValue: "unknown"), name: "fixture_mutation", argumentsJSON: "{}",
            resources: [.global], idempotencyKey: "unparseable",
            receiptExpectation: .init(targets: [.init(namespace: "fixture", id: "unknown")]))
        guard case .admitted = try await journal.admit(request) else { Issue.record("Missing intent"); return }
        let provider = rejectionProvider()
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try ResourceDiscovery(), try BoundedTestMutation()],
            configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
        let run = try await session.run("start", operationID: "different-operation")
        await #expect(throws: EvidenceError.self) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await provider.log.requests.count == 2)
        try await journal.close()
    }

    @Test func pendingWithoutLogicalOperationDoesNotBlockUnrelatedExplicitOperation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-no-op-id-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory,
            operationDomain: "replan-no-op-id", supportsAdmissionRejections: true)
        let priorRun = UUID(), priorCall = ToolCallID(rawValue: "prior")
        let request = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: priorRun,
            callID: priorCall, name: "fixture_mutation", argumentsJSON: "{}",
            resources: [.global], idempotencyKey: "\(priorRun.uuidString)/\(priorCall.rawValue)",
            receiptExpectation: .init(targets: [.init(namespace: "fixture", id: "prior")]))
        guard case .admitted = try await journal.admit(request) else { Issue.record("Missing intent"); return }
        let provider = rejectionProvider()
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try ResourceDiscovery(), try BoundedTestMutation()],
            configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
        let run = try await session.run("start", operationID: "unrelated")
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(await provider.log.requests.count == 3)
        try await journal.close()
    }

    @Test func operationIndexFollowsTheRootAfterFailedOrUnknownIntentPublication() async throws {
        for afterPublication in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-operation-fault-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = ReplanningJournalFault(afterPublication: afterPublication)
            let journal = try AgentIncrementalJournal.createForTesting(at: directory,
                operationDomain: "replan-operation-fault", supportsAdmissionRejections: true,
                fault: { try fault.check($0) })
            let request = try ToolMutationAdmissionRequest(sessionID: UUID(), runID: UUID(),
                callID: .init(rawValue: "prior"), name: "fixture_mutation", argumentsJSON: "{}",
                resources: [.global], idempotencyKey: "logical/fixture_mutation/{}",
                receiptExpectation: .init(targets: [.init(namespace: "fixture", id: "prior")]))
            fault.arm()
            if afterPublication {
                await #expect(throws: AgentJournalError.commitUnknown) { try await journal.admit(request) }
            } else {
                await #expect(throws: AgentJournalError.persistenceUnavailable("rejection fixture fault")) {
                    try await journal.admit(request)
                }
            }
            try await journal.close()
            let reopened = try AgentIncrementalJournal.open(at: directory)
            #expect(try await reopened.hasRelatedPendingMutation(sessionID: UUID(),
                operationID: "logical") == afterPublication)
            #expect(try await reopened.pendingMutations().count == (afterPublication ? 1 : 0))
            try await reopened.close()
        }
    }

    @Test func resourceOutsideScopeStillFailsBeforeReplanning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-scope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "replan-scope",
            supportsAdmissionRejections: true)
        let provider = rejectionProvider()
        let session = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
        let scope = try await session.bindCapabilities(identity: "limited", version: "1",
            backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.global, .named(.init(namespace: "resource", id: "1"))],
            tools: [.init(id: "discover", version: "1", tool: try ResourceDiscovery()),
                    .init(id: "commit", version: "1", tool: try BoundedTestMutation())])
        let run = try await session.run("start", capabilities: scope)
        await #expect(throws: AgentCapabilityError.resourceOutsideScope) { try await run.wait() }
        try await run.waitForDrain()
        #expect(await provider.log.requests.count == 2)
        #expect(try await journal.pendingMutations().isEmpty)
        try await journal.close()
    }

    @Test func rejectedMutationInMultiCallBatchDoesNotDiscardCompletedSibling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-batch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "replan-batch",
            supportsAdmissionRejections: true)
        let provider = rejectionProvider(multiCall: true)
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try ResourceDiscovery(), try BoundedTestMutation()],
            configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
        let run = try await session.run("start")
        await #expect(throws: EvidenceError.unavailable(.init(namespace: "resource", id: "X"))) {
            try await run.wait()
        }
        try await run.waitForDrain()
        #expect(await provider.log.requests.count == 2)
        let snapshot = try await session.conversationSnapshot()
        #expect(snapshot.messages.contains {
            if case .tool(let result) = $0 { return result.callID.rawValue == "sibling" && !result.isError }
            return false
        })
        #expect(!snapshot.messages.contains {
            if case .tool(let result) = $0 { return result.callID.rawValue == "invalid-X" }
            return false
        })
        try await journal.close()
    }

    @Test func rejectionCommitFailureAndUnknownNeverRequestAnotherModelTurn() async throws {
        for failure: AgentJournalError in [.commitUnknown, .persistenceUnavailable("fixture")] {
            let provider = rejectionProvider()
            let loop = try AgentLoop(binding: .legacy(model: fixtureModel, provider: provider),
                tools: ToolRegistry(tools: [AnyAgentTool(try ResourceDiscovery()),
                                           AnyAgentTool(try BoundedTestMutation())]),
                preAdmissionReplanning: policy)
            let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
                checkpoint: { messages, _ in messages },
                checkReplanningSafety: { _ in true },
                recordAdmissionRejection: { _, _ in throw failure })
            await #expect(throws: failure) {
                try await loop.execute(messages: [.user([.text("start")])], sessionID: UUID(),
                    runID: UUID(), budget: testBudget(turns: 4, calls: 3),
                    structuredOutput: nil, emitter: nil, lifecycle: lifecycle)
            }
            #expect(await provider.log.requests.count == 2)
        }
    }

    @Test func durableRejectionPublicationFaultDoesNotSendAnotherRequest() async throws {
        for afterPublication in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replan-commit-fault-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let fault = ReplanningJournalFault(afterPublication: afterPublication)
            let journal = try AgentIncrementalJournal.createForTesting(at: directory,
                operationDomain: "replan-commit-fault", supportsAdmissionRejections: true,
                fault: { try fault.check($0) })
            let provider = rejectionProvider(beforeInvalid: { fault.arm() })
            let session = try Agent(model: fixtureModel, provider: provider,
                tools: [try ResourceDiscovery(), try BoundedTestMutation()],
                configuration: .init(preAdmissionReplanning: policy)).makeSession(journal: journal)
            let run = try await session.run("start")
            if afterPublication {
                await #expect(throws: AgentJournalError.commitUnknown) { try await run.wait() }
            } else {
                await #expect(throws: AgentJournalError.persistenceUnavailable("rejection fixture fault")) {
                    try await run.wait()
                }
            }
            try await run.waitForDrain()
            #expect(await provider.log.requests.count == 2)
            if !afterPublication { try await journal.close() }
        }
    }

    @Test func uncertainSafetyStateNeverBecomesAnEmptyPendingSet() async throws {
        let provider = rejectionProvider()
        let loop = try makeLoop(provider)
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages },
            checkReplanningSafety: { _ in throw AgentJournalError.persistenceUnavailable("fixture read failed") })
        await #expect(throws: AgentJournalError.persistenceUnavailable("fixture read failed")) {
            try await loop.execute(messages: [.user([.text("start")])], sessionID: UUID(),
                runID: UUID(), budget: testBudget(), structuredOutput: nil, emitter: nil, lifecycle: lifecycle)
        }
        #expect(await provider.log.requests.count == 2)
    }

    @Test func hostComputedReferenceIsNotExposedInModelFeedback() async throws {
        let provider = rejectionProvider()
        let tool = try BoundedTestMutation(referenceOverride: .init(namespace: "private", id: "secret/path"))
        let loop = try AgentLoop(binding: .legacy(model: fixtureModel, provider: provider),
            tools: ToolRegistry(tools: [AnyAgentTool(try ResourceDiscovery()), AnyAgentTool(tool)]),
            preAdmissionReplanning: policy)
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages }, checkReplanningSafety: { _ in true },
            recordAdmissionRejection: { _, messages in messages })
        #expect(try await loop.execute(messages: [.user([.text("start")])], sessionID: UUID(),
            runID: UUID(), budget: testBudget(), structuredOutput: nil, emitter: nil,
            lifecycle: lifecycle).outcome == .completed)
        let third = try #require(await provider.log.requests.last)
        guard case .tool(let result)? = third.messages.last else { Issue.record("Missing feedback"); return }
        #expect(result.isError && result.callID.rawValue == "invalid-X")
        #expect(!String(describing: result.content).contains("secret/path"))
        #expect(String(describing: result.content).contains("denied before execution"))
    }

    @Test func cancellationWhileRejectionCommitsDoesNotSendALateRequest() async throws {
        let gate = ManualGate()
        let provider = rejectionProvider()
        let loop = try makeLoop(provider)
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages }, checkReplanningSafety: { _ in true },
            recordAdmissionRejection: { _, messages in
                await gate.wait()
                return messages
            })
        let task = Task { try await loop.execute(messages: [.user([.text("start")])], sessionID: UUID(),
            runID: UUID(), budget: testBudget(), structuredOutput: nil, emitter: nil, lifecycle: lifecycle) }
        await gate.waitUntilBlocked()
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await provider.log.requests.count == 2)
    }

    @Test func originalAbsoluteDeadlineStopsARejectionCommitWithoutAnotherRequest() async throws {
        let gate = ManualGate()
        let provider = rejectionProvider()
        let loop = try makeLoop(provider)
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages }, checkReplanningSafety: { _ in true },
            recordAdmissionRejection: { _, messages in
                await gate.wait()
                return messages
            })
        let budget = try AgentBudget(maxModelTurns: 6, maxToolCalls: 5,
            deadline: .now.advanced(by: .seconds(2)))
        let task = Task { try await loop.execute(messages: [.user([.text("start")])], sessionID: UUID(),
            runID: UUID(), budget: budget, structuredOutput: nil, emitter: nil, lifecycle: lifecycle) }
        await gate.waitUntilBlocked()
        await #expect(throws: AgentLoopError.deadlineExceeded) { try await task.value }
        await gate.open()
        #expect(await provider.log.requests.count == 2)
    }

    @Test func revocationAfterRejectionCommitCannotStartTheNextRequest() async throws {
        let gate = ManualGate()
        let provider = rejectionProvider()
        let sessionID = UUID(), runID = UUID(), instanceID = UUID()
        let scope = AgentCapabilityScope(instanceID: UUID(), sessionID: sessionID,
            sessionInstanceID: instanceID, resources: [.global,
                .named(.init(namespace: "resource", id: "X"))])
        try await scope.register(runID: runID, sessionID: sessionID, sessionInstanceID: instanceID,
            cancel: {})
        let loop = try AgentLoop(binding: .legacy(model: fixtureModel, provider: provider),
            tools: ToolRegistry(tools: [AnyAgentTool(try ResourceDiscovery()),
                                       AnyAgentTool(try BoundedTestMutation())]),
            capabilityScope: scope, preAdmissionReplanning: policy)
        let lifecycle = AgentLoopLifecycle(control: AgentRunControl(), evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages }, checkReplanningSafety: { _ in true },
            recordAdmissionRejection: { _, messages in
                await gate.wait()
                return messages
            })
        let task = Task { try await loop.execute(messages: [.user([.text("start")])], sessionID: sessionID,
            runID: runID, budget: testBudget(), structuredOutput: nil, emitter: nil, lifecycle: lifecycle) }
        await gate.waitUntilBlocked()
        await scope.revoke()
        await gate.open()
        await #expect(throws: AgentCapabilityError.revoked) { try await task.value }
        #expect(await provider.log.requests.count == 2)
        await scope.releaseRun(runID)
    }

    @Test func steeringDuringRejectionCommitIsAppliedBeforeContinuation() async throws {
        let gate = ManualGate()
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("hold")]) {
                guard request.messages.contains(where: {
                    if case .tool(let result) = $0 { return result.callID.rawValue == "invalid-X" && result.isError }
                    return false
                }) else { throw ModelProviderError(kind: .invalidRequest, message: "missing committed rejection") }
                return textResponse(request, "Stopped")
            }
            switch request.messages.last {
            case .user:
                return toolResponse(request, [.init(id: .init(rawValue: "first"), name: ResourceDiscovery.name,
                    argumentsJSON: "{}", completeness: .complete)])
            case .tool(let result) where result.callID.rawValue == "first":
                return toolResponse(request, [.init(id: .init(rawValue: "invalid-X"), name: BoundedTestMutation.name,
                    argumentsJSON: #"{"id":"X"}"#, completeness: .complete)])
            default: throw ModelProviderError(kind: .invalidRequest, message: "unexpected continuation")
            }
        }
        let control = AgentRunControl()
        let loop = try makeLoop(provider)
        let lifecycle = AgentLoopLifecycle(control: control, evidenceLedger: EvidenceLedger(),
            checkpoint: { messages, _ in messages }, checkReplanningSafety: { _ in true },
            recordAdmissionRejection: { _, messages in
                await gate.wait()
                return messages
            })
        let task = Task { try await loop.execute(messages: [.user([.text("start")])], sessionID: UUID(),
            runID: UUID(), budget: testBudget(), structuredOutput: nil, emitter: nil, lifecycle: lifecycle) }
        await gate.waitUntilBlocked()
        _ = try await control.enqueue("hold")
        await gate.open()
        #expect(try await task.value.outcome == .completed)
        #expect(await provider.log.requests.count == 3)
    }

    private func makeLoop(_ provider: ScriptedProvider) throws -> AgentLoop {
        try AgentLoop(binding: .legacy(model: fixtureModel, provider: provider),
            tools: ToolRegistry(tools: [AnyAgentTool(try ResourceDiscovery()),
                                       AnyAgentTool(try BoundedTestMutation())]),
            preAdmissionReplanning: policy)
    }
}

private func rejectionProvider(multiCall: Bool = false,
                               beforeInvalid: @escaping @Sendable () -> Void = {}) -> ScriptedProvider {
    ScriptedProvider { request, _ in
        switch request.messages.last {
        case .user:
            return toolResponse(request, [.init(id: .init(rawValue: "first"), name: ResourceDiscovery.name,
                argumentsJSON: "{}", completeness: .complete)])
        case .tool(let result) where result.callID.rawValue == "first":
            beforeInvalid()
            let invalid = ToolCall(id: .init(rawValue: "invalid-X"), name: BoundedTestMutation.name,
                argumentsJSON: #"{"id":"X"}"#, completeness: .complete)
            if multiCall {
                return toolResponse(request, [
                    .init(id: .init(rawValue: "sibling"), name: ResourceDiscovery.name,
                          argumentsJSON: "{}", completeness: .complete), invalid,
                ])
            }
            return toolResponse(request, [invalid])
        case .tool(let result) where result.callID.rawValue == "invalid-X" && result.isError:
            return textResponse(request, "Denied before execution")
        default:
            throw ModelProviderError(kind: .invalidRequest, message: "unexpected fixture request")
        }
    }
}

private final class ReplanningJournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let afterPublication: Bool

    init(afterPublication: Bool) { self.afterPublication = afterPublication }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func check(_ stage: JournalFileFaultStage) throws {
        if afterPublication {
            guard case .afterCurrentReplace = stage else { return }
        } else {
            guard case .beforeAppend = stage else { return }
        }
        lock.lock()
        let fail = armed
        armed = false
        lock.unlock()
        if fail { throw AgentJournalError.persistenceUnavailable("rejection fixture fault") }
    }
}

private struct BoundedTestMutation: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let id: String }
    static let name = "bounded_test_commit"
    static let description = "Test-only bounded mutation"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    let policy = try! ToolPolicy.mutation(authorization: .notRequired)
    let referenceOverride: EvidenceReference?
    init(referenceOverride: EvidenceReference? = nil) throws { self.referenceOverride = referenceOverride }
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: referenceOverride ?? .init(namespace: "resource", id: input.id))]
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "resource", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "resource", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        Issue.record("A missing-Evidence mutation must not reach the executor")
        throw EvidenceError.unavailable(.init(namespace: "resource", id: input.id))
    }
}
