import BoundedReplanningFixture
import Foundation

@main
enum BoundedReplanningProbe {
    static func main() async {
        var failed = false
        for scenario: BoundedScenario in [.correctFromCandidates, .searchAgain] {
            do {
                let observed = try await BoundedFixture.run(scenario)
                print(observed.trace)
                let expectedSearches = scenario == .searchAgain ? 2 : 1
                let expectedRequests = scenario == .searchAgain ? 5 : 4
                let rejectionIsSafe = observed.evidenceError == false
                    && observed.invalidAttempts == 1
                    && observed.invalidMutationState == nil
                    && observed.pendingStates.isEmpty
                let correctionCompleted = observed.linkedFeedbackIsRelevant
                    && observed.requests.count == expectedRequests
                    && observed.requests.allSatisfy { $0.runID == observed.runID && $0.sessionID == observed.sessionID }
                    && observed.searchCalls == expectedSearches
                    && observed.executorEntered == 1 && observed.externalEffects == 1
                    && observed.authorizationEntered == 1
                    && observed.validMutationState == .settled && observed.receiptCount == 1
                    && observed.reopenedHistoryAndMessageIDsMatch && observed.reopenedRejectionPaired
                    && observed.outcome == "completed" && observed.error == nil
                    && observed.physicalDrainNanoseconds >= observed.logicalEndNanoseconds
                if rejectionIsSafe && correctionCompleted {
                    print("PASS \(scenario.rawValue): linked rejection, original Run/budget, full admission and one settled effect")
                } else {
                    failed = true
                    let reason: String
                    if observed.requests.count == 2 && observed.evidenceError { reason = "no continuation request after Evidence rejection" }
                    else if observed.rejectionFeedback == nil { reason = "continuation lacks linked rejection feedback" }
                    else if !observed.linkedFeedbackIsRelevant { reason = "rejection feedback lacks relevant reference" }
                    else if observed.error != nil { reason = "feedback visible but script protocol/admission failed: \(observed.error!)" }
                    else { reason = "continuation or lifecycle did not meet target assertions" }
                    print("FAIL \(scenario.rawValue): \(reason)")
                }
            } catch {
                failed = true
                print("FAIL \(scenario.rawValue): fixture/environment failure: \(error)")
            }
        }
        if failed { exit(1) }
    }
}
