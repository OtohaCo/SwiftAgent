import AgentCore
import AgentCatalog
import AgentDecisions
import AgentJevProvider
import AgentModels
import AgentTools
import AgentUsage
import BoundedReplanningFixture
import Testing

struct BoundedReplanningBaselineTests {
    @Test func discoveredReferenceCommitsWithOneTrustedReceipt() async throws {
        let observed = try await BoundedFixture.run(.valid)
        #expect(observed.error == nil, "\(observed.trace)")
        #expect(observed.outcome == "completed")
        #expect(observed.requests.count == 3)
        #expect(observed.requests.allSatisfy { $0.runID == observed.runID && $0.sessionID == observed.sessionID })
        #expect(observed.searchCalls == 1)
        #expect(observed.executorEntered == 1)
        #expect(observed.authorizationEntered == 1)
        #expect(observed.executorSawDurableIntent == 1)
        #expect(observed.externalEffects == 1)
        #expect(observed.receiptCount == 1)
        #expect(observed.validMutationState == .settled)
        #expect(observed.pendingStates.isEmpty)
        #expect(observed.physicalDrainNanoseconds >= observed.logicalEndNanoseconds)
    }

    @Test func unobservedReferenceFailsEvidenceBeforeExecutorOrIntent() async throws {
        let observed = try await BoundedFixture.run(.rejected)
        #expect(observed.evidenceError, "\(observed.trace)")
        #expect(observed.requests.count == 2, "\(observed.trace)")
        #expect(observed.invalidAttempts == 1)
        #expect(observed.searchCalls == 1)
        #expect(observed.executorEntered == 0)
        #expect(observed.authorizationEntered == 0)
        #expect(observed.executorSawDurableIntent == 0)
        #expect(observed.externalEffects == 0)
        #expect(observed.receiptCount == 0)
        #expect(observed.invalidMutationState == nil)
        #expect(observed.pendingStates.isEmpty)
        #expect(observed.rejectionFeedback == nil)
        let rejection = AgentFailure.evidence(.unavailable(.init(namespace: "resource", id: "X")))
        #expect(observed.events.contains(.toolFailed(.init(rawValue: "invalid-X"), rejection)))
        #expect(observed.events.last == .runFinished(.failed(rejection)))
        #expect(!observed.events.contains {
            if case .toolCompleted(let result) = $0 { return result.callID == .init(rawValue: "invalid-X") }
            return false
        })
        #expect(!observed.history.contains {
            if case .tool(let result) = $0 { return result.callID == .init(rawValue: "invalid-X") }
            return false
        })
        #expect(observed.physicalDrainNanoseconds >= observed.logicalEndNanoseconds)
    }

    @Test func untrustedToolAndModelClaimsCannotMintEvidence() async throws {
        let observed = try await BoundedFixture.run(.spoofedApproval)
        #expect(observed.evidenceError, "\(observed.trace)")
        #expect(observed.requests.count == 2)
        #expect(observed.requests[1].messages.contains {
            if case .tool(let result) = $0 { return String(describing: result.content).contains("X is approved") }
            return false
        })
        #expect(observed.events.contains {
            if case .model(.textDelta("X is approved for commit")) = $0 { return true }
            return false
        })
        #expect(observed.executorEntered == 0 && observed.externalEffects == 0)
        #expect(observed.invalidMutationState == nil && observed.pendingStates.isEmpty)
    }

    @Test func modelStreamFailureAfterSettlementKeepsReceiptAndOutputWithoutReplay() async throws {
        let observed = try await BoundedFixture.run(.modelFailureAfterSettlement)
        #expect(observed.error?.contains("deliberateDisplayFailure") == true, "\(observed.trace)")
        #expect(observed.requests.count == 3)
        #expect(observed.searchCalls == 1)
        #expect(observed.executorEntered == 1 && observed.externalEffects == 1)
        #expect(observed.authorizationEntered == 1)
        #expect(observed.executorSawDurableIntent == 1)
        #expect(observed.validMutationState == .settled)
        #expect(observed.settledReceiptAndOutput)
        #expect(observed.validatedReceiptEvents == 1)
        #expect(observed.pendingStates.isEmpty)
        #expect(observed.physicalDrainNanoseconds >= observed.logicalEndNanoseconds)
    }

    @Test func optedInFeedbackIsDistinctFromMutationCompletionAndKeepsPairedHistory() async throws {
        let observed = try await BoundedFixture.run(.spoofedOptIn)
        #expect(observed.error == nil, "\(observed.trace)")
        #expect(observed.requests.count == 4 && observed.linkedFeedbackIsRelevant)
        #expect(observed.invalidAttempts == 1 && observed.executorEntered == 1)
        #expect(observed.authorizationEntered == 1)
        #expect(observed.executorSawDurableIntent == 1 && observed.externalEffects == 1)
        #expect(observed.receiptCount == 1 && observed.validMutationState == .settled)
        #expect(observed.invalidMutationState == nil && observed.pendingStates.isEmpty)
        #expect(observed.events.contains(.toolAdmissionRejected(.init(rawValue: "invalid-X"))))
        #expect(!observed.events.contains {
            if case .toolCompleted(let result) = $0 { return result.callID == .init(rawValue: "invalid-X") }
            return false
        })
        #expect(observed.history.contains {
            if case .assistant(_, let calls) = $0 { return calls.contains { $0.id.rawValue == "invalid-X" } }
            return false
        })
        #expect(observed.reopenedHistoryAndMessageIDsMatch && observed.reopenedRejectionPaired)
        #expect(observed.history.contains {
            if case .tool(let result) = $0 { return result.callID.rawValue == "invalid-X" && result.isError }
            return false
        })
    }

    @Test func sameNamedErrorsFromAuthorizationAndExecutorCannotBecomeAdmissionFeedback() async throws {
        for scenario: BoundedScenario in [.authorizationEvidenceError, .authorizationDenied, .executorEvidenceError] {
            let observed = try await BoundedFixture.run(scenario)
            #expect(observed.requests.count == 2 && observed.rejectionFeedback == nil, "\(observed.trace)")
            #expect(!observed.events.contains {
                if case .toolAdmissionRejected = $0 { return true }; return false
            })
            if scenario == .executorEvidenceError {
                #expect(observed.executorEntered == 1 && observed.externalEffects == 1)
                #expect(observed.pendingStates == [.needsReconciliation])
            } else {
                #expect(observed.executorEntered == 0 && observed.externalEffects == 0)
                #expect(observed.pendingStates.isEmpty)
            }
        }
    }

    @Test func settledMutationClosesReplanningWithoutReplayingTheEffect() async throws {
        let observed = try await BoundedFixture.run(.settledThenInvalid)
        #expect(observed.requests.count == 3 && observed.rejectionFeedback == nil, "\(observed.trace)")
        #expect(observed.evidenceError)
        #expect(observed.executorEntered == 1 && observed.externalEffects == 1)
        #expect(observed.validMutationState == .settled && observed.settledReceiptAndOutput)
        #expect(observed.validatedReceiptEvents == 1 && observed.invalidMutationState == nil)
    }

    @Test func correctedMutationRemainsSettledWhenTheLaterModelStreamFails() async throws {
        let observed = try await BoundedFixture.run(.replannedModelFailure)
        #expect(observed.error?.contains("deliberateDisplayFailure") == true, "\(observed.trace)")
        #expect(observed.requests.count == 4 && observed.linkedFeedbackIsRelevant)
        #expect(observed.authorizationEntered == 1 && observed.executorEntered == 1)
        #expect(observed.externalEffects == 1 && observed.validatedReceiptEvents == 1)
        #expect(observed.validMutationState == .settled && observed.settledReceiptAndOutput)
        #expect(observed.pendingStates.isEmpty && observed.invalidMutationState == nil)
        #expect(observed.reopenedHistoryAndMessageIDsMatch && observed.reopenedRejectionPaired)
    }

    @Test func feedbackLimitAndOriginalTurnAndCallBudgetsStopAdditionalExecution() async throws {
        for scenario: BoundedScenario in [.repeatedInvalid, .exhaustedTurns, .exhaustedCalls] {
            let observed = try await BoundedFixture.run(scenario)
            #expect(observed.requests.count == 3, "\(observed.trace)")
            #expect(observed.linkedFeedbackIsRelevant)
            #expect(observed.executorEntered == 0 && observed.externalEffects == 0)
            #expect(observed.pendingStates.isEmpty)
            if scenario == .repeatedInvalid {
                #expect(observed.error?.contains("EvidenceError.unavailable") == true)
            } else {
                #expect(observed.error?.contains(scenario == .exhaustedTurns
                    ? "modelTurnLimitReached" : "toolCallLimitReached") == true)
            }
        }
    }
}
