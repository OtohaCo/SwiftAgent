import AgentModels
import Foundation

/// Retry and fallback limits for a route of single-turn model providers.
public struct ModelProviderFallbackPolicy: Hashable, Codable, Sendable {
    public let maxAttempts: Int
    public let maxRetriesPerProvider: Int
    public let retryableKinds: Set<ModelProviderError.Kind>

    public init(
        maxAttempts: Int = 2,
        maxRetriesPerProvider: Int = 0,
        retryableKinds: Set<ModelProviderError.Kind> = [.rateLimited, .unavailable, .transport]
    ) throws {
        guard maxAttempts > 0, maxRetriesPerProvider >= 0 else {
            throw ModelProviderFallbackPolicyError.invalidLimits
        }
        guard retryableKinds.isSubset(of: [.rateLimited, .unavailable, .transport]) else {
            throw ModelProviderFallbackPolicyError.invalidRetryableKinds
        }
        self.maxAttempts = maxAttempts
        self.maxRetriesPerProvider = maxRetriesPerProvider
        self.retryableKinds = retryableKinds
    }
}

public enum ModelProviderFallbackPolicyError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidRetryableKinds
    case emptyCandidates
    case candidateProviderIDMismatch(routeID: String, candidateID: String)
}

/// Composes validated model turns without executing tools or owning an agent loop.
/// A mutation boundary blocks switching to another candidate for that run.
public struct ModelProviderRoute: ModelProvider, ModelProviderMutationBoundary, ModelProviderRunDrain {
    public let descriptor: ModelProviderDescriptor
    private let candidates: [any ModelProvider]
    private let policy: ModelProviderFallbackPolicy
    private let boundaryState: MutationBoundaryState

    public init(
        id: String,
        candidates: [any ModelProvider],
        policy: ModelProviderFallbackPolicy = try! .init()
    ) throws {
        guard !candidates.isEmpty else { throw ModelProviderFallbackPolicyError.emptyCandidates }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderFallbackPolicyError.emptyCandidates
        }
        if let candidate = candidates.first(where: { $0.descriptor.id != id }) {
            throw ModelProviderFallbackPolicyError.candidateProviderIDMismatch(
                routeID: id,
                candidateID: candidate.descriptor.id
            )
        }
        self.candidates = candidates
        self.policy = policy
        self.boundaryState = MutationBoundaryState()
        var capabilities = candidates.dropFirst().reduce(candidates[0].descriptor.capabilities) { current, candidate in
            ModelCapabilities(rawValue: current.rawValue & candidate.descriptor.capabilities.rawValue)
        }
        capabilities.remove(.streaming)
        descriptor = ModelProviderDescriptor(id: id, capabilities: capabilities)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            try await streamValidated(request: request, emit: emit)
        }
    }

    public func markMutationBoundary(sessionID: UUID, runID: UUID) async {
        await boundaryState.mark(sessionID: sessionID, runID: runID)
        for candidate in candidates {
            guard let boundary = candidate as? any ModelProviderMutationBoundary else { continue }
            await boundary.markMutationBoundary(sessionID: sessionID, runID: runID)
        }
    }

    public func clearMutationBoundary(sessionID: UUID, runID: UUID) async {
        await boundaryState.clear(sessionID: sessionID, runID: runID)
        for candidate in candidates {
            guard let boundary = candidate as? any ModelProviderMutationBoundary else { continue }
            await boundary.clearMutationBoundary(sessionID: sessionID, runID: runID)
        }
    }

    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        for candidate in candidates {
            guard let provider = candidate as? any ModelProviderRunDrain else { continue }
            await provider.waitForRunToDrain(sessionID: sessionID, runID: runID)
        }
    }

    private func streamValidated(request: ModelRequest, emit: @escaping ModelEventStream.Emit) async throws {
        guard request.model.provider.utf8.elementsEqual(descriptor.id.utf8) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Provider route does not serve this model namespace.")
        }

        let admission = await boundaryState.admission(sessionID: request.sessionID, runID: request.runID)
        if admission.boundaryReached {
            return try await streamPinnedCandidate(admission, request: request, emit: emit)
        }

        var attempts = 0
        var lastError: (any Error)?
        for (candidateIndex, candidate) in candidates.enumerated() {
            var retries = 0
            while attempts < policy.maxAttempts {
                try Task.checkCancellation()
                attempts += 1
                do {
                    let events = try await validatedEvents(from: candidate, request: request)
                    for event in events { try emit(event) }
                    await boundaryState.recordValidatedCandidate(
                        sessionID: request.sessionID,
                        runID: request.runID,
                        generation: admission.generation,
                        candidateIndex: candidateIndex
                    )
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ModelProviderError {
                    lastError = error
                    guard policy.retryableKinds.contains(error.kind) else { throw error }
                    let boundaryReached = await boundaryState.admission(
                        sessionID: request.sessionID,
                        runID: request.runID
                    ).boundaryReached
                    if boundaryReached {
                        if retries < policy.maxRetriesPerProvider || candidateIndex + 1 < candidates.count {
                            throw ModelProviderError(kind: .fallbackBlocked,
                                                     message: "Provider fallback is blocked after a mutation boundary.")
                        }
                        throw error
                    }
                    if retries < policy.maxRetriesPerProvider {
                        retries += 1
                        if let retryAfter = error.retryAfter {
                            try await Task.sleep(for: retryAfter)
                        }
                        continue
                    }
                } catch {
                    throw error
                }

                guard candidateIndex + 1 < candidates.count, attempts < policy.maxAttempts else {
                    throw lastError ?? ModelProviderError(kind: .unavailable, message: "Provider route exhausted.")
                }
                if await boundaryState.admission(
                    sessionID: request.sessionID,
                    runID: request.runID
                ).boundaryReached {
                    throw ModelProviderError(kind: .fallbackBlocked,
                                             message: "Provider fallback is blocked after a mutation boundary.")
                }
                break
            }
        }
        throw lastError ?? ModelProviderError(kind: .unavailable, message: "Provider route exhausted.")
    }

    private func streamPinnedCandidate(
        _ admission: MutationBoundaryState.Admission,
        request: ModelRequest,
        emit: @escaping ModelEventStream.Emit
    ) async throws {
        // A direct boundary mark without a prior validated turn keeps the old conservative
        // contract: probe the first candidate once, then pin it if it validates. Never search
        // later candidates from an unowned boundary.
        let candidateIndex = admission.pinnedCandidateIndex ?? 0

        let candidate = candidates[candidateIndex]
        do {
            let events = try await validatedEvents(from: candidate, request: request)
            for event in events { try emit(event) }
            if admission.pinnedCandidateIndex == nil {
                await boundaryState.recordValidatedCandidate(
                    sessionID: request.sessionID,
                    runID: request.runID,
                    generation: admission.generation,
                    candidateIndex: candidateIndex
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ModelProviderError {
            let couldRetry = policy.maxRetriesPerProvider > 0
            let hasLaterCandidate = candidateIndex + 1 < candidates.count
            if policy.retryableKinds.contains(error.kind), couldRetry || hasLaterCandidate {
                throw ModelProviderError(
                    kind: .fallbackBlocked,
                    message: "Provider fallback is blocked after a mutation boundary."
                )
            }
            throw error
        }
    }

    private func validatedEvents(from candidate: any ModelProvider, request: ModelRequest) async throws -> [ModelEvent] {
        var accumulator = ModelEventAccumulator()
        var events: [ModelEvent] = []
        for try await event in candidate.stream(request: request) {
            try accumulator.append(event)
            events.append(event)
        }
        let response = try accumulator.finish()
        guard response.info.model == request.model else {
            throw ModelProviderError(kind: .invalidResponse, message: "Provider returned a different model identity.")
        }
        return events
    }
}

private actor MutationBoundaryState {
    struct Admission: Sendable {
        let boundaryReached: Bool
        let pinnedCandidateIndex: Int?
        let generation: UUID?
    }

    private struct Key: Hashable {
        let sessionID: UUID
        let runID: UUID
    }

    private struct State {
        let generation: UUID
        var boundaryReached = false
        var pinnedCandidateIndex: Int?

        init(generation: UUID = UUID()) {
            self.generation = generation
        }
    }

    private var states: [Key: State] = [:]

    func mark(sessionID: UUID, runID: UUID) {
        let key = Key(sessionID: sessionID, runID: runID)
        states[key, default: .init()].boundaryReached = true
    }

    func clear(sessionID: UUID, runID: UUID) {
        states.removeValue(forKey: Key(sessionID: sessionID, runID: runID))
    }

    func recordValidatedCandidate(
        sessionID: UUID?,
        runID: UUID?,
        generation: UUID?,
        candidateIndex: Int
    ) {
        guard let sessionID, let runID, let generation else { return }
        let key = Key(sessionID: sessionID, runID: runID)
        guard states[key]?.generation == generation else { return }
        states[key]?.pinnedCandidateIndex = candidateIndex
    }

    func admission(sessionID: UUID?, runID: UUID?) -> Admission {
        guard let sessionID, let runID else {
            return .init(boundaryReached: false, pinnedCandidateIndex: nil, generation: nil)
        }
        let key = Key(sessionID: sessionID, runID: runID)
        let state: State
        if let existing = states[key] {
            state = existing
        } else {
            let created = State()
            states[key] = created
            state = created
        }
        return .init(boundaryReached: state.boundaryReached,
                     pinnedCandidateIndex: state.pinnedCandidateIndex,
                     generation: state.generation)
    }
}
