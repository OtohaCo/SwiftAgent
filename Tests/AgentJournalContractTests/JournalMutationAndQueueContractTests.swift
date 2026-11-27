@testable import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing

@Suite struct JournalMutationAndQueueContractTests {
    private func tempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-contract-\(label)-\(UUID())")
    }

    @Test(arguments: JournalContractBackends.all)
    func settledLargeOutputAndIdempotentReplaySurviveMaintenanceAndReopen(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("large-mutation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "large-mutation",
            smallMaintenanceSegments: true
        )
        let session = UUID(), run = UUID()
        let callID = ToolCallID(rawValue: "first-call")
        let target = EvidenceReference(namespace: "fixture", id: "blob-target")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let key = "stable-operation/tool/{\"id\":\"large\"}"
        let largePayload = JSONValue.string(String(repeating: "large-settled-payload-", count: 4000))

        let request = ToolMutationAdmissionRequest(
            sessionID: session,
            runID: run,
            callID: callID,
            name: "write",
            argumentsJSON: #"{"id":"large"}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )
        guard case .admitted = try await journal.admit(request) else {
            Issue.record("expected initial admission")
            return
        }
        #expect(try await journal.pendingMutations(sessionID: session).count == 1)

        let receipt = ToolReceipt(operationID: key, status: .succeeded, confirmedTargets: [target], revision: "v2")
        let history: [ModelMessage] = [
            .user([.text("write large output")]),
            .assistant(content: [], toolCalls: [.init(id: callID, name: "write", argumentsJSON: #"{"id":"large"}"#, completeness: .complete)]),
            .tool(.init(callID: callID, content: [.text("ok")], isError: false)),
        ]
        try await journal.commitMutation(
            sessionID: session,
            runID: run,
            callID: callID,
            receipt: receipt,
            output: largePayload,
            history: history,
            steeringIDs: []
        )
        #expect(try await journal.pendingMutations(sessionID: session).isEmpty)
        for _ in 0..<12 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        #expect(try await reopened.latestCheckpoint(sessionID: session)?.history == history)
        let retry = ToolMutationAdmissionRequest(
            sessionID: UUID(),
            runID: UUID(),
            callID: .init(rawValue: "retry"),
            name: "write",
            argumentsJSON: #"{"id":"large"}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )
        guard case .settled(let replayReceipt, let replayOutput) = try await reopened.admit(retry) else {
            Issue.record("retry must reuse settled result")
            return
        }
        #expect(replayReceipt == receipt)
        #expect(replayOutput == largePayload)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func reconciliationAndAbortedMutationRetryFollowExactLifecycleRules(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("reconcile-abort")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "reconcile-abort",
            capabilities: .init(supportsConfirmedNoEffect: true)
        )
        let session = UUID(), run = UUID()
        let callID = ToolCallID(rawValue: "abort-call")
        let target = EvidenceReference(namespace: "fixture", id: "item")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let key = "abort-retry-key"

        _ = try await journal.admit(.init(
            sessionID: session,
            runID: run,
            callID: callID,
            name: "write",
            argumentsJSON: #"{"a":1,"b":2}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        ))
        try await journal.markMutationNeedsReconciliation(sessionID: session, runID: run, callID: callID)
        try await journal.close()

        let reopened = try backend.open(at: directory)
        let pending = try #require(try await reopened.recoverPendingMutations(sessionID: session).first)
        #expect(pending.state == .needsReconciliation)
        try await reopened.abortMutation(
            pending,
            confirmedNoEffect: try AgentNoEffectConfirmation(basis: "verified absent on target")
        )
        #expect(try await reopened.pendingMutations(sessionID: session).isEmpty)

        // Semantically equivalent JSON key order is admitted again after confirmed no-effect abort.
        let retry = ToolMutationAdmissionRequest(
            sessionID: session,
            runID: UUID(),
            callID: .init(rawValue: "retry-call"),
            name: "write",
            argumentsJSON: #"{"b":2,"a":1}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )
        guard case .admitted = try await reopened.admit(retry) else {
            Issue.record("expected fresh admission after confirmed no-effect abort")
            return
        }
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func retryingAbortedMutationPreservesPriorInvocationHistoryAcrossReopen(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("aborted-retry-history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "aborted-retry-history",
            capabilities: .init(supportsConfirmedNoEffect: true)
        )
        let session = UUID()
        let run1 = UUID(), run2 = UUID(), run3 = UUID()
        let call1 = ToolCallID(rawValue: "attempt-1")
        let call2 = ToolCallID(rawValue: "attempt-2")
        let call3 = ToolCallID(rawValue: "attempt-3")
        let target = EvidenceReference(namespace: "fixture", id: "record-1")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let key = "aborted-retry-history/write/{\"a\":1,\"b\":2}"
        let confirmation = try AgentNoEffectConfirmation(basis: "verified absent on target")

        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run1,
            callID: call1,
            name: "write",
            argumentsJSON: #"{"a":1,"b":2}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected initial admission for run1")
            try? await journal.close()
            return
        }
        try await journal.markMutationNeedsReconciliation(sessionID: session, runID: run1, callID: call1)
        let pending = try #require(try await journal.recoverPendingMutations(sessionID: session).first)
        #expect(pending.state == .needsReconciliation)
        #expect(pending.runID == run1)
        #expect(pending.intent.call.id == call1)
        try await journal.abortMutation(pending, confirmedNoEffect: confirmation)
        #expect(try await journal.pendingMutations(sessionID: session).isEmpty)

        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run2,
            callID: call2,
            name: "write",
            argumentsJSON: #"{"b":2,"a":1}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected fresh admission for run2 after confirmed no-effect abort")
            try? await journal.close()
            return
        }

        let receipt = ToolReceipt(operationID: key, status: .succeeded, confirmedTargets: [target], revision: "v2")
        let settledOutput = JSONValue.object(["applied": .bool(true), "revision": .string("v2")])
        let history: [ModelMessage] = [
            .user([.text("apply mutation")]),
            .assistant(content: [], toolCalls: [.init(id: call2, name: "write", argumentsJSON: #"{"b":2,"a":1}"#, completeness: .complete)]),
            .tool(.init(callID: call2, content: [.text("applied")], isError: false)),
        ]
        try await journal.commitMutation(
            sessionID: session,
            runID: run2,
            callID: call2,
            receipt: receipt,
            output: settledOutput,
            history: history,
            steeringIDs: []
        )

        func verifyBothInvocations(on targetJournal: AgentJournal, phase: String) async throws {
            let firstStatus = try #require(
                try await targetJournal.mutationStatus(sessionID: session, runID: run1, callID: call1),
                "prior aborted invocation missing (\(phase))"
            )
            #expect(firstStatus.state == .aborted)
            #expect(firstStatus.receipt == nil)
            #expect(firstStatus.replayOutput == nil)
            #expect(firstStatus.abortConfirmation == confirmation)

            let secondStatus = try #require(
                try await targetJournal.mutationStatus(sessionID: session, runID: run2, callID: call2),
                "settled retry invocation missing (\(phase))"
            )
            #expect(secondStatus.state == .settled)
            #expect(secondStatus.receipt == receipt)
            #expect(secondStatus.replayOutput == settledOutput)
            #expect(secondStatus.abortConfirmation == nil)

            let currentIdentity = try #require(
                try await targetJournal.mutationStatus(identity: key),
                "latest logical identity missing (\(phase))"
            )
            #expect(currentIdentity == secondStatus)

            if let store = await targetJournal.store {
                let storedFirst = try #require(
                    try store.read { try $0.mutation(sessionID: session, runID: run1, callID: call1) },
                    "stored prior invocation missing (\(phase))"
                )
                #expect(storedFirst.sessionID == session)
                #expect(storedFirst.runID == run1)
                #expect(storedFirst.intent.call.id == call1)
                #expect(storedFirst.intent.idempotencyKey == key)
                #expect(storedFirst.state == .aborted)
                #expect(storedFirst.abortConfirmation == confirmation)

                let storedSecond = try #require(
                    try store.read { try $0.mutation(sessionID: session, runID: run2, callID: call2) },
                    "stored retry invocation missing (\(phase))"
                )
                #expect(storedSecond.sessionID == session)
                #expect(storedSecond.runID == run2)
                #expect(storedSecond.intent.call.id == call2)
                #expect(storedSecond.intent.idempotencyKey == key)
                #expect(storedSecond.state == .settled)
                #expect(storedSecond.receipt == receipt)
                #expect(storedSecond.output == settledOutput)
            }
        }

        try await verifyBothInvocations(on: journal, phase: "before close")
        try await journal.close()

        let reopened = try backend.open(at: directory)
        try await verifyBothInvocations(on: reopened, phase: "after reopen")

        guard case .settled(let replayedReceipt, let replayedOutput) = try await reopened.admit(.init(
            sessionID: session,
            runID: run3,
            callID: call3,
            name: "write",
            argumentsJSON: #"{"a":1,"b":2}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected settled replay for third attempt")
            try? await reopened.close()
            return
        }
        #expect(replayedReceipt == receipt)
        #expect(replayedOutput == settledOutput)

        let firstAfterReplay = try #require(
            try await reopened.mutationStatus(sessionID: session, runID: run1, callID: call1)
        )
        #expect(firstAfterReplay.state == .aborted)
        #expect(firstAfterReplay.abortConfirmation == confirmation)
        #expect(try await reopened.mutationStatus(sessionID: session, runID: run2, callID: call2)?.state == .settled)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func multipleAbortedAttemptsPreserveAllPriorInvocationsAndRejectOldCallReuse(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("multi-abort-history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "multi-abort-history",
            smallMaintenanceSegments: true,
            capabilities: .init(supportsConfirmedNoEffect: true)
        )
        let session = UUID()
        let run1 = UUID(), run2 = UUID(), run3 = UUID()
        let call1 = ToolCallID(rawValue: "multi-1")
        let call2 = ToolCallID(rawValue: "multi-2")
        let call3 = ToolCallID(rawValue: "multi-3")
        let target = EvidenceReference(namespace: "fixture", id: "record-2")
        let expectation = try ToolReceiptExpectation(targets: [target], revision: .present)
        let key = "multi-abort-history/write/{\"id\":2}"
        let confirmation1 = try AgentNoEffectConfirmation(basis: "first attempt never reached target")
        let confirmation2 = try AgentNoEffectConfirmation(basis: "second attempt rolled back before effect")

        // First attempt aborted.
        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run1,
            callID: call1,
            name: "write",
            argumentsJSON: #"{"id":2}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected admission for run1")
            try? await journal.close()
            return
        }
        try await journal.markMutationNeedsReconciliation(sessionID: session, runID: run1, callID: call1)
        let pending1 = try #require(try await journal.recoverPendingMutations(sessionID: session).first)
        try await journal.abortMutation(pending1, confirmedNoEffect: confirmation1)

        // Second attempt aborted.
        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run2,
            callID: call2,
            name: "write",
            argumentsJSON: #"{"id":2}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected admission for run2")
            try? await journal.close()
            return
        }
        try await journal.markMutationNeedsReconciliation(sessionID: session, runID: run2, callID: call2)
        let pending2 = try #require(try await journal.recoverPendingMutations(sessionID: session).first)
        try await journal.abortMutation(pending2, confirmedNoEffect: confirmation2)

        // Reusing the earlier aborted invocation identity (session, run1, call1) must be rejected.
        await #expect(throws: AgentJournalError.mutationIntentConflict) {
            _ = try await journal.admit(.init(
                sessionID: session,
                runID: run1,
                callID: call1,
                name: "write",
                argumentsJSON: #"{"id":2}"#,
                resources: [.named(target)],
                idempotencyKey: key,
                receiptExpectation: expectation
            ))
        }

        // Third attempt settles.
        guard case .admitted = try await journal.admit(.init(
            sessionID: session,
            runID: run3,
            callID: call3,
            name: "write",
            argumentsJSON: #"{"id":2}"#,
            resources: [.named(target)],
            idempotencyKey: key,
            receiptExpectation: expectation
        )) else {
            Issue.record("expected admission for run3")
            try? await journal.close()
            return
        }
        let receipt = ToolReceipt(operationID: key, status: .succeeded, confirmedTargets: [target], revision: "v3")
        let output = JSONValue.string("settled-on-third")
        let history: [ModelMessage] = [
            .user([.text("apply third attempt")]),
            .assistant(content: [], toolCalls: [.init(id: call3, name: "write", argumentsJSON: #"{"id":2}"#, completeness: .complete)]),
            .tool(.init(callID: call3, content: [.text("ok")], isError: false)),
        ]
        try await journal.commitMutation(
            sessionID: session,
            runID: run3,
            callID: call3,
            receipt: receipt,
            output: output,
            history: history,
            steeringIDs: []
        )
        for _ in 0..<8 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        let status1 = try #require(try await reopened.mutationStatus(sessionID: session, runID: run1, callID: call1))
        let status2 = try #require(try await reopened.mutationStatus(sessionID: session, runID: run2, callID: call2))
        let status3 = try #require(try await reopened.mutationStatus(sessionID: session, runID: run3, callID: call3))
        #expect(status1.state == .aborted)
        #expect(status1.abortConfirmation == confirmation1)
        #expect(status2.state == .aborted)
        #expect(status2.abortConfirmation == confirmation2)
        #expect(status3.state == .settled)
        #expect(status3.receipt == receipt)
        #expect(status3.replayOutput == output)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func followUpQueueAndRunRecordsPersistAcrossMaintenanceAndReopen(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("followup-runs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "followup-runs",
            smallMaintenanceSegments: true,
            capabilities: .init(supportsPerCallFollowUps: true, supportsRunRecords: true)
        )
        let session = UUID()

        let first = try await journal.enqueueFollowUp(
            .init(inputID: "in-1", text: "first queued", operationID: "op-1", configurationRef: "cfg"),
            sessionID: session
        )
        let second = try await journal.enqueueFollowUp(
            .init(inputID: "in-2", text: "second queued", operationID: "op-2", configurationRef: "cfg"),
            sessionID: session
        )
        #expect(first.ordinal < second.ordinal)
        #expect(try await journal.followUps(sessionID: session, after: nil, limit: 10).map(\.inputID) == ["in-1", "in-2"])

        let withdrawn = try await journal.withdrawFollowUp(sessionID: session, inputID: "in-2")
        #expect(withdrawn == .withdrawn)

        let model = ModelID(provider: "contract-fixture", name: "script")
        let agent = try Agent(model: model, provider: SimpleCompletionProvider())
        let agentSession = try agent.makeSession(id: session, journal: journal)
        let activeRun = try await agentSession.run("recorded input", operationID: "op-run", correlation: try AgentRunCorrelation(key: "corr/1", payloadDigest: "digest-1"))
        #expect(try await activeRun.wait().outcome == .completed)
        try await activeRun.waitForDrain()

        for _ in 0..<8 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        #expect(try await reopened.followUp(sessionID: session, inputID: "in-1")?.state == .queued)
        #expect(try await reopened.followUp(sessionID: session, inputID: "in-2")?.state == .withdrawn)

        let byCorrelation = try await reopened.runRecord(sessionID: session, correlationKey: "corr/1")
        guard case .terminal(let runRecord, .completed) = byCorrelation else {
            Issue.record("expected completed terminal run record, got \(String(describing: byCorrelation))")
            return
        }
        #expect(try await reopened.runRecord(sessionID: session, runID: runRecord.runID) == byCorrelation)
        try await reopened.close()
    }

    @Test(arguments: JournalContractBackends.all)
    func runtimeAdmissionRejectionMarkersSurviveMaintenanceAndReopen(
        _ backend: any JournalBackendHarness
    ) async throws {
        let directory = tempDir("admission-rejection")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try backend.create(
            at: directory,
            operationDomain: "rejection-contract",
            smallMaintenanceSegments: true,
            capabilities: .init(supportsAdmissionRejections: true)
        )
        let sessionID = UUID()
        let agent = try Agent(
            model: .init(provider: "rejection-contract", name: "script"),
            provider: ContractRejectionProvider(),
            tools: [ContractDiscoveryTool(), ContractGuardedMutationTool()],
            configuration: .init(preAdmissionReplanning: .evidenceRejection(toolNames: [ContractGuardedMutationTool.name]))
        )
        let session = try agent.makeSession(id: sessionID, journal: journal)
        let run = try await session.run("Choose resource", operationID: "op-reject")
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()

        let marker = try #require(try await journal.admissionRejection(
            sessionID: sessionID,
            runID: run.id,
            callID: .init(rawValue: "rejected-call")
        ))
        #expect(marker.toolName == ContractGuardedMutationTool.name)
        for _ in 0..<8 {
            if try await journal.requestMaintenance()?.sealedSegments == 0 { break }
        }
        try await journal.close()

        let reopened = try backend.open(at: directory, smallMaintenanceSegments: true)
        let restored = try #require(try await reopened.admissionRejection(
            sessionID: sessionID,
            runID: run.id,
            callID: .init(rawValue: "rejected-call")
        ))
        #expect(restored == marker)
        try await reopened.close()
    }
}

private struct SimpleCompletionProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "contract-fixture", capabilities: [.streaming, .multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "resp-1", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}

private struct ContractDiscoveryTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "discover_item"
    static let description = "Discovers valid resources"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        .init(output: "A and B", evidence: [
            .init(namespace: "contract", id: "A", issuedAt: Date()),
            .init(namespace: "contract", id: "B", issuedAt: Date()),
        ])
    }
}

private struct ContractGuardedMutationTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    static let name = "mutate_item"
    static let description = "Mutates a discovered resource"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.string
    let policy = try! ToolPolicy.mutation(authorization: .notRequired)
    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "contract", id: input.id))]
    }
    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "contract", id: input.id))]
    }
    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "contract", id: input.id)], revision: .present)
    }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        throw AgentJournalError.invalidRecord
    }
}

private struct ContractRejectionProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "rejection-contract", capabilities: [.multiTurn, .tools])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixture", model: request.model)
            let call: ToolCall?
            switch request.messages.last {
            case .user:
                call = .init(id: .init(rawValue: "discover-call"), name: ContractDiscoveryTool.name, argumentsJSON: "{}", completeness: .complete)
            case .tool(let result) where result.callID.rawValue == "discover-call":
                call = .init(id: .init(rawValue: "rejected-call"), name: ContractGuardedMutationTool.name, argumentsJSON: #"{"id":"X"}"#, completeness: .complete)
            case .tool(let result) where result.callID.rawValue == "rejected-call" && result.isError:
                call = nil
            default:
                throw ModelProviderError(kind: .invalidRequest, message: "unexpected request")
            }
            try emit(.responseStarted(info))
            if let call {
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("denied"))
                try emit(.responseCompleted(.init(info: info, content: [.text("denied")], stopReason: .endTurn)))
            }
        }
    }
}
