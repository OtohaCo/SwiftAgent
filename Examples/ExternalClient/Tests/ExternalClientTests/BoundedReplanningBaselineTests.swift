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
        #expect(observed.executorSawDurableIntent == 1)
        #expect(observed.validMutationState == .settled)
        #expect(observed.settledReceiptAndOutput)
        #expect(observed.validatedReceiptEvents == 1)
        #expect(observed.pendingStates.isEmpty)
        #expect(observed.physicalDrainNanoseconds >= observed.logicalEndNanoseconds)
    }
}
