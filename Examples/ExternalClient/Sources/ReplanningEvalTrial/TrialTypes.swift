import AgentCore
import AgentModels
import AgentTools
import Foundation

struct EvalTask: Codable, Sendable {
    let id: String
    let group: String
    let scenario: String
    let prompt: String
    let expectedEffect: String?
}

struct TrialInput: Codable, Sendable {
    let trialID: String
    let mode: String
    let arm: String
    let task: EvalTask
    let directory: String
    let operationID: String
    let model: String
    let endpoint: String?
    let reasoning: String
    let keyEnvironment: String?
    let authorizedLive: Bool
    let maxHTTPRequests: Int
    let maxOutputTokens: Int
    let maxInputBytes: Int
    let maxModelTurns: Int
    let maxToolCalls: Int
    let runTimeoutSeconds: Int
}

struct TrialFacts: Codable, Sendable {
    let trialID: String
    let mode: String
    let arm: String
    let taskID: String
    let sessionID: String
    let runIDs: [String]
    let operationID: String
    let outcome: String
    let failure: String?
    let providerRequests: Int
    let httpRequests: Int
    let searches: Int
    let toolAttempts: Int
    let executorEntered: Int
    let effectIDs: [String]
    let trustedReceipts: Int
    let settledA: Bool
    let replayOutputA: Bool
    let pendingStates: [String]?
    let pendingQueryError: String?
    let rejectionCallIDs: [String]
    let feedbackInLaterRequest: Bool
    let usage: [ResponseUsage]
    let milestonesNS: Milestones
    let reportComplete: Bool
    let reportDiagnostics: [String]
    let hostRetries: Int
}

struct ResponseUsage: Codable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let cacheWriteInputTokens: Int?
    let cacheWriteTTL: CacheWriteTTLUsage?
    let reasoningTokens: Int?

    init(_ value: ModelUsage) {
        inputTokens = value.inputTokens
        outputTokens = value.outputTokens
        cachedInputTokens = value.cachedInputTokens
        cacheWriteInputTokens = value.cacheWriteInputTokens
        cacheWriteTTL = value.cacheWriteTTL
        reasoningTokens = value.reasoningTokens
    }
}

struct Milestones: Codable, Sendable {
    let taskStart: UInt64
    let firstCandidate: UInt64?
    let rejection: UInt64?
    let feedbackRequest: UInt64?
    let effect: UInt64?
    let settlement: UInt64?
    let logicalEnd: UInt64
    let physicalDrain: UInt64
}

enum EvalTrialError: Error, CustomStringConvertible {
    case invalidConfiguration
    case httpBudgetExhausted
    case dryRunFailure

    var description: String {
        switch self {
        case .invalidConfiguration: "Invalid or incomplete trial configuration."
        case .httpBudgetExhausted: "Trial HTTP request budget exhausted."
        case .dryRunFailure: "The scripted provider stopped after a settled effect."
        }
    }
}

actor TrialProbe {
    private let started = DispatchTime.now().uptimeNanoseconds
    private let maxHTTPRequests: Int
    private(set) var providerRequests = 0
    private(set) var httpRequests = 0
    private(set) var searches = 0
    private(set) var attempts = 0
    private(set) var executorEntered = 0
    private(set) var rejectionCallIDs: [String] = []
    private(set) var feedbackInLaterRequest = false
    private(set) var usage: [ResponseUsage] = []
    private var firstCandidate: UInt64?
    private var rejected: UInt64?
    private var feedbackRequest: UInt64?
    private var effect: UInt64?
    private var settlement: UInt64?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(maxHTTPRequests: Int) { self.maxHTTPRequests = maxHTTPRequests }

    func monotonicNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func request(_ request: ModelRequest) {
        providerRequests += 1
        if !rejectionCallIDs.isEmpty, request.messages.contains(where: { message in
            guard case .tool(let result) = message else { return false }
            return result.isError && rejectionCallIDs.contains(result.callID.rawValue)
                && String(describing: result.content).contains("evidence_unavailable")
        }) {
            feedbackInLaterRequest = true
            feedbackRequest = feedbackRequest ?? monotonicNow()
        }
        let ready = requestWaiters.filter { providerRequests >= $0.0 }
        requestWaiters.removeAll { providerRequests >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
    }

    func waitForRequests(_ count: Int) async {
        if providerRequests >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func reserveHTTP() throws {
        guard httpRequests < maxHTTPRequests else { throw EvalTrialError.httpBudgetExhausted }
        httpRequests += 1
    }

    func searchReturned() { searches += 1; firstCandidate = firstCandidate ?? monotonicNow() }
    func executorEnteredEffect() { executorEntered += 1 }
    func effectSynced() { effect = effect ?? monotonicNow() }

    func observe(_ event: AgentEvent) {
        switch event {
        case .toolAdmissionRejected(let id):
            rejectionCallIDs.append(id.rawValue)
            rejected = rejected ?? monotonicNow()
        case .toolReceiptValidated: settlement = settlement ?? monotonicNow()
        case .model(.toolCallCompleted): attempts += 1
        case .model(.responseCompleted(let response)): usage.append(.init(response.usage))
        default: break
        }
    }

    func facts(logicalEnd: UInt64, drain: UInt64) -> (
        requests: Int, http: Int, searches: Int, attempts: Int, entered: Int,
        rejected: [String], feedback: Bool, usage: [ResponseUsage], time: Milestones
    ) {
        (providerRequests, httpRequests, searches, attempts, executorEntered,
         rejectionCallIDs, feedbackInLaterRequest, usage,
         .init(taskStart: started, firstCandidate: firstCandidate, rejection: rejected,
               feedbackRequest: feedbackRequest, effect: effect, settlement: settlement,
               logicalEnd: logicalEnd, physicalDrain: drain))
    }
}

actor TrialGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
