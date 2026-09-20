import AgentModels
@testable import AgentUsage
import Foundation
import Testing

struct UsageLedgerTests {
    @Test func multiTurnToolRunSumsEveryFinalizedResponse() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let model = ModelID(provider: "fixture", name: "usage")
        let ledger = UsageLedger()

        _ = await ledger.record(.init(
            identity: .init(
                source: .modelResponse,
                sessionID: sessionID,
                runID: runID,
                invocationID: "turn-1",
                providerResponseID: "response-1",
                model: model
            ),
            usage: .init(inputTokens: 120, outputTokens: 7),
            status: .finalized
        ))
        _ = await ledger.record(.init(
            identity: .init(
                source: .modelResponse,
                sessionID: sessionID,
                runID: runID,
                invocationID: "turn-2",
                providerResponseID: "response-2",
                model: model
            ),
            usage: .init(inputTokens: 200, outputTokens: 11),
            status: .finalized
        ))

        let summary = await ledger.summary(sessionID: sessionID, runID: runID)
        #expect(summary.observedResponseCount == 2)
        #expect(summary.finalizedResponseCount == 2)
        #expect(summary.provisionalResponseCount == 0)
        #expect(summary.inputTokens.reportedSubtotal == 320)
        #expect(summary.inputTokens.reportedCount == 2)
        #expect(summary.inputTokens.missingCount == 0)
        #expect(summary.inputTokens.complete)
        #expect(summary.outputTokens.reportedSubtotal == 18)
        #expect(summary.outputTokens.complete)
        #expect(summary.totalTokens == 338)
    }

    @Test func crossResponseMissingFieldsRemainPartialInsteadOfBecomingZero() async throws {
        let sessionID = UUID()
        let runID = UUID()
        let model = ModelID(provider: "fixture", name: "usage")
        let ledger = UsageLedger()

        _ = await ledger.record(.init(
            identity: .init(
                source: .modelResponse,
                sessionID: sessionID,
                runID: runID,
                invocationID: "turn-1",
                providerResponseID: "shared-id",
                model: model
            ),
            usage: .init(inputTokens: 100),
            status: .finalized
        ))
        _ = await ledger.record(.init(
            identity: .init(
                source: .modelResponse,
                sessionID: sessionID,
                runID: runID,
                invocationID: "turn-2",
                providerResponseID: "shared-id",
                model: model
            ),
            usage: .init(outputTokens: 0),
            status: .finalized
        ))

        let summary = await ledger.summary(sessionID: sessionID, runID: runID)
        #expect(summary.inputTokens.reportedSubtotal == 100)
        #expect(summary.inputTokens.reportedCount == 1)
        #expect(summary.inputTokens.missingCount == 1)
        #expect(!summary.inputTokens.complete)
        #expect(summary.outputTokens.reportedSubtotal == 0)
        #expect(summary.outputTokens.reportedCount == 1)
        #expect(summary.outputTokens.missingCount == 1)
        #expect(!summary.outputTokens.complete)
        #expect(summary.totalTokens == nil)
    }

    @Test func cumulativeSnapshotsReplaceWithinAResponseAndSparseFieldsArePreserved() async throws {
        let identity = makeIdentity(invocationID: "turn-1")
        let ledger = UsageLedger()

        #expect((await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: 50, outputTokens: 2),
            status: .provisional
        ))).disposition == .inserted)
        #expect((await ledger.record(.init(
            identity: identity,
            usage: .init(outputTokens: 5),
            status: .provisional
        ))).disposition == .updated)
        #expect((await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: 50, outputTokens: 5),
            status: .finalized
        ))).disposition == .updated)

        let response = await ledger.summary(identity: identity)
        #expect(response.observedResponseCount == 1)
        #expect(response.finalizedResponseCount == 1)
        #expect(response.inputTokens.reportedSubtotal == 50)
        #expect(response.outputTokens.reportedSubtotal == 5)
        #expect(response.totalTokens == 55)
    }

    @Test func cacheAndReasoningSubsetsAreNotAddedToTotalTokens() async throws {
        let ledger = UsageLedger()
        _ = await ledger.record(.init(
            identity: makeIdentity(invocationID: "turn-1"),
            usage: .init(
                inputTokens: 50,
                outputTokens: 18,
                cachedInputTokens: 20,
                cacheWriteInputTokens: 3,
                reasoningTokens: 15
            ),
            status: .finalized
        ))

        let summary = await ledger.summary()
        #expect(summary.totalTokens == 68)
        #expect(summary.cachedInputTokens.reportedSubtotal == 20)
        #expect(summary.cacheWriteInputTokens.reportedSubtotal == 3)
        #expect(summary.reasoningTokens.reportedSubtotal == 15)
    }

    @Test func noSamplesUnreportedAndExplicitZeroRemainDistinct() async throws {
        let empty = await UsageLedger().summary()
        #expect(empty.observedResponseCount == 0)
        #expect(empty.inputTokens.reportedSubtotal == nil)
        #expect(empty.inputTokens.reportedCount == 0)
        #expect(empty.inputTokens.missingCount == 0)
        #expect(!empty.inputTokens.complete)

        let unreported = UsageLedger()
        _ = await unreported.record(.init(
            identity: makeIdentity(invocationID: "turn-1"),
            usage: .init(),
            status: .finalized
        ))
        _ = await unreported.record(.init(
            identity: makeIdentity(invocationID: "turn-2"),
            usage: .init(),
            status: .finalized
        ))
        let missing = await unreported.summary()
        #expect(missing.inputTokens.reportedSubtotal == nil)
        #expect(missing.inputTokens.reportedCount == 0)
        #expect(missing.inputTokens.missingCount == 2)

        let zero = UsageLedger()
        _ = await zero.record(.init(
            identity: makeIdentity(invocationID: "turn-1"),
            usage: .init(inputTokens: 0, outputTokens: 0),
            status: .finalized
        ))
        _ = await zero.record(.init(
            identity: makeIdentity(invocationID: "turn-2"),
            usage: .init(inputTokens: 0, outputTokens: 0),
            status: .finalized
        ))
        let reportedZero = await zero.summary()
        #expect(reportedZero.inputTokens.reportedSubtotal == 0)
        #expect(reportedZero.inputTokens.complete)
        #expect(reportedZero.totalTokens == 0)
    }

    @Test func decodedFieldWithoutASubtotalCannotClaimCompleteness() throws {
        let field = try JSONDecoder().decode(
            UsageFieldSummary.self,
            from: Data(#"{"reportedSubtotal":null,"reportedCount":3,"missingCount":0}"#.utf8)
        )

        #expect(!field.complete)
    }

    @Test func fieldSummationStaysIncompleteAfterOverflow() {
        let field = summarizeUsageField([Int.max, Int.max, 5])

        #expect(field.reportedSubtotal == nil)
        #expect(field.reportedCount == 3)
        #expect(field.missingCount == 0)
        #expect(!field.complete)
    }

    @Test func duplicatesAreNoOpsConflictsAreDiagnosedAndFinalizedRecordsDoNotRegress() async throws {
        let identity = makeIdentity(invocationID: "turn-1")
        let observation = UsageObservation(
            identity: identity,
            usage: .init(inputTokens: 10, outputTokens: 5),
            status: .finalized
        )
        let ledger = UsageLedger()

        #expect((await ledger.record(observation)).disposition == .inserted)
        #expect((await ledger.record(observation)).disposition == .duplicate)
        let conflict = await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: 10, outputTokens: 6),
            status: .finalized
        ))
        #expect(conflict.disposition == .rejected)
        #expect(conflict.diagnostic?.kind == .finalizedConflict)
        let late = await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: 10, outputTokens: 4),
            status: .provisional
        ))
        #expect(late.disposition == .rejected)
        #expect(late.diagnostic?.kind == .finalizedConflict)
        #expect((await ledger.summary()).outputTokens.reportedSubtotal == 5)
    }

    @Test func providerResponseIDIsNotAGlobalDeduplicationKey() async throws {
        let sharedResponseID = "shared-response"
        let ledger = UsageLedger()
        _ = await ledger.record(.init(
            identity: makeIdentity(
                runID: UUID(), invocationID: "turn-1", providerResponseID: sharedResponseID,
                model: .init(provider: "provider-a", name: "model")
            ),
            usage: .init(inputTokens: 4, outputTokens: 1),
            status: .finalized
        ))
        _ = await ledger.record(.init(
            identity: makeIdentity(
                runID: UUID(), invocationID: "turn-1", providerResponseID: sharedResponseID,
                model: .init(provider: "provider-b", name: "model")
            ),
            usage: .init(inputTokens: 6, outputTokens: 2),
            status: .finalized
        ))

        let summary = await ledger.summary()
        #expect(summary.observedResponseCount == 2)
        #expect(summary.inputTokens.reportedSubtotal == 10)
        #expect(summary.outputTokens.reportedSubtotal == 3)
    }

    @Test func provisionalResponsesRemainSeparateFromFinalizedTotals() async throws {
        let ledger = UsageLedger()
        _ = await ledger.record(.init(
            identity: makeIdentity(invocationID: "completed"),
            usage: .init(inputTokens: 10, outputTokens: 3),
            status: .finalized
        ))
        _ = await ledger.record(.init(
            identity: makeIdentity(invocationID: "cancelled"),
            usage: .init(inputTokens: 8, outputTokens: 1),
            status: .provisional
        ))

        let summary = await ledger.summary()
        #expect(summary.observedResponseCount == 2)
        #expect(summary.finalizedResponseCount == 1)
        #expect(summary.provisionalResponseCount == 1)
        #expect(summary.inputTokens.reportedSubtotal == 18)
        #expect(summary.finalizedUsage.sampleCount == 1)
        #expect(summary.finalizedUsage.inputTokens.reportedSubtotal == 10)
        #expect(summary.finalizedUsage.outputTokens.reportedSubtotal == 3)
        #expect(summary.finalizedUsage.totalTokens == 13)
        #expect(summary.provisionalUsage.sampleCount == 1)
        #expect(summary.provisionalUsage.inputTokens.reportedSubtotal == 8)
        #expect(summary.provisionalUsage.outputTokens.reportedSubtotal == 1)
        #expect(summary.provisionalUsage.totalTokens == 9)
        #expect(!summary.allResponsesFinalized)
    }

    @Test func summariesStayPartitionedByRunSessionAndModel() async throws {
        let sessionA = UUID()
        let sessionB = UUID()
        let runA1 = UUID()
        let runA2 = UUID()
        let runB = UUID()
        let modelA = ModelID(provider: "provider-a", name: "model")
        let modelB = ModelID(provider: "provider-b", name: "model")
        let ledger = UsageLedger()

        for (identity, input) in [
            (makeIdentity(sessionID: sessionA, runID: runA1, invocationID: "a1", model: modelA), 1),
            (makeIdentity(sessionID: sessionA, runID: runA2, invocationID: "a2", model: modelA), 2),
            (makeIdentity(sessionID: sessionB, runID: runB, invocationID: "b", model: modelB), 4),
        ] {
            _ = await ledger.record(.init(
                identity: identity,
                usage: .init(inputTokens: input, outputTokens: 0),
                status: .finalized
            ))
        }

        #expect((await ledger.summary(sessionID: sessionA)).inputTokens.reportedSubtotal == 3)
        #expect((await ledger.summary(sessionID: sessionA, runID: runA1)).inputTokens.reportedSubtotal == 1)
        #expect((await ledger.summary(model: modelA)).observedResponseCount == 2)
        #expect((await ledger.summary(model: modelB)).inputTokens.reportedSubtotal == 4)
    }

    @Test func aNewLedgerDoesNotInventUsageFromConversationRecovery() async throws {
        let priorWindow = UsageLedger()
        _ = await priorWindow.record(.init(
            identity: makeIdentity(invocationID: "before-restart"),
            usage: .init(inputTokens: 9, outputTokens: 3),
            status: .finalized
        ))

        let restartedWindow = UsageLedger()
        #expect((await restartedWindow.summary()).observedResponseCount == 0)
        _ = await restartedWindow.record(.init(
            identity: makeIdentity(invocationID: "after-restart"),
            usage: .init(inputTokens: 5, outputTokens: 2),
            status: .finalized
        ))
        #expect((await restartedWindow.summary()).totalTokens == 7)
    }

    @Test func decisionUsageRetainsItsSourceWithoutPretendingToBeAModelTurn() async throws {
        let ledger = UsageLedger()
        let identity = UsageRecordIdentity(
            source: .decision,
            invocationID: "jev-choice",
            providerResponseID: "decision-1",
            model: .init(provider: "jev", name: "configured-model")
        )
        _ = await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: 12, outputTokens: 3),
            status: .finalized
        ))

        let summary = await ledger.summary()
        #expect(summary.sources == [.decision])
        #expect(summary.coverage == .decisionResponses)
        #expect(summary.totalTokens == 15)
    }

    @Test func invalidRegressingSubsetAndOverflowObservationsAreRejectedAtomically() async throws {
        let identity = makeIdentity(invocationID: "turn-1")
        let ledger = UsageLedger()

        let negative = await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: -1),
            status: .provisional
        ))
        #expect(negative.diagnostic?.kind == .negativeValue)
        #expect((await ledger.summary()).observedResponseCount == 0)

        _ = await ledger.record(.init(
            identity: identity,
            usage: .init(inputTokens: 10, outputTokens: 5, cachedInputTokens: 4),
            status: .provisional
        ))
        let decrease = await ledger.record(.init(
            identity: identity,
            usage: .init(outputTokens: 4),
            status: .provisional
        ))
        #expect(decrease.diagnostic?.kind == .decreasedValue)
        let subset = await ledger.record(.init(
            identity: identity,
            usage: .init(cachedInputTokens: 11),
            status: .provisional
        ))
        #expect(subset.diagnostic?.kind == .subsetExceedsTotal)
        #expect((await ledger.summary()).outputTokens.reportedSubtotal == 5)

        let overflowLedger = UsageLedger()
        _ = await overflowLedger.record(.init(
            identity: makeIdentity(invocationID: "large"),
            usage: .init(inputTokens: Int.max, outputTokens: nil),
            status: .finalized
        ))
        let overflow = await overflowLedger.record(.init(
            identity: makeIdentity(invocationID: "one-more"),
            usage: .init(inputTokens: 1, outputTokens: nil),
            status: .finalized
        ))
        #expect(overflow.diagnostic?.kind == .arithmeticOverflow)
        #expect((await overflowLedger.summary()).observedResponseCount == 1)
        #expect((await overflowLedger.summary()).inputTokens.reportedSubtotal == Int.max)
    }

    @Test func unknownDecodedSourceIsRejectedInsteadOfMisreportingCoverage() async throws {
        let source = try JSONDecoder().decode(
            UsageSource.self,
            from: Data(#"{"rawValue":"unwired_internal_model"}"#.utf8)
        )
        let ledger = UsageLedger()
        let result = await ledger.record(.init(
            identity: makeIdentity(source: source, invocationID: "unknown-source"),
            usage: .init(inputTokens: 1, outputTokens: 1),
            status: .finalized
        ))

        #expect(result.diagnostic?.kind == .invalidIdentity)
        #expect((await ledger.summary()).coverage == .noSamples)
    }

    @Test func observationsAndSummariesRoundTripThroughCodableExport() async throws {
        let observation = UsageObservation(
            identity: makeIdentity(invocationID: "exported-response"),
            usage: .init(inputTokens: 8, outputTokens: 3, reasoningTokens: 2),
            status: .finalized
        )
        let encodedObservation = try JSONEncoder().encode(observation)
        #expect(try JSONDecoder().decode(UsageObservation.self, from: encodedObservation) == observation)

        let ledger = UsageLedger()
        _ = await ledger.record(observation)
        let summary = await ledger.summary()
        let encodedSummary = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(UsageSummary.self, from: encodedSummary) == summary)
    }

    @Test func removeAllStartsANewExplicitAccountingWindow() async throws {
        let ledger = UsageLedger()
        _ = await ledger.record(.init(
            identity: makeIdentity(invocationID: "turn-1"),
            usage: .init(inputTokens: 1, outputTokens: 1),
            status: .finalized
        ))
        await ledger.removeAll()
        #expect((await ledger.summary()).observedResponseCount == 0)
    }
}

private func makeIdentity(
    source: UsageSource = .modelResponse,
    sessionID: UUID = UUID(),
    runID: UUID = UUID(),
    invocationID: String,
    providerResponseID: String? = nil,
    model: ModelID = .init(provider: "fixture", name: "usage")
) -> UsageRecordIdentity {
    .init(
        source: source,
        sessionID: sessionID,
        runID: runID,
        invocationID: invocationID,
        providerResponseID: providerResponseID,
        model: model
    )
}
