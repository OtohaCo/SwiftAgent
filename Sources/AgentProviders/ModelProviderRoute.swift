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
        self.candidates = candidates
        self.policy = policy
        self.boundaryState = MutationBoundaryState()
        let capabilities = candidates.dropFirst().reduce(candidates[0].descriptor.capabilities) { current, candidate in
            ModelCapabilities(rawValue: current.rawValue & candidate.descriptor.capabilities.rawValue)
        }
        descriptor = ModelProviderDescriptor(id: id, capabilities: capabilities)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            try await streamValidated(request: request, emit: emit)
        }
    }

    public func markMutationBoundary(sessionID: UUID, runID: UUID) async {
        await boundaryState.mark(sessionID: sessionID, runID: runID)
    }

    public func clearMutationBoundary(sessionID: UUID, runID: UUID) async {
        await boundaryState.clear(sessionID: sessionID, runID: runID)
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
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ModelProviderError {
                    lastError = error
                    guard policy.retryableKinds.contains(error.kind) else { throw error }
                    let boundaryReached = await boundaryState.contains(
                        sessionID: request.sessionID,
                        runID: request.runID
                    )
                    if boundaryReached {
                        if retries < policy.maxRetriesPerProvider || candidateIndex + 1 < candidates.count {
                            throw ModelProviderError(kind: .fallbackBlocked,
                                                     message: "Provider fallback is blocked after a mutation boundary.")
                        }
                        throw error
                    }
                    if retries < policy.maxRetriesPerProvider {
                        retries += 1
                        continue
                    }
                } catch {
                    throw error
                }

                guard candidateIndex + 1 < candidates.count, attempts < policy.maxAttempts else {
                    throw lastError ?? ModelProviderError(kind: .unavailable, message: "Provider route exhausted.")
                }
                if await boundaryState.contains(sessionID: request.sessionID, runID: request.runID) {
                    throw ModelProviderError(kind: .fallbackBlocked,
                                             message: "Provider fallback is blocked after a mutation boundary.")
                }
                break
            }
        }
        throw lastError ?? ModelProviderError(kind: .unavailable, message: "Provider route exhausted.")
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
    private struct Key: Hashable {
        let sessionID: UUID
        let runID: UUID
    }

    private var keys: Set<Key> = []

    func mark(sessionID: UUID, runID: UUID) {
        keys.insert(Key(sessionID: sessionID, runID: runID))
    }

    func clear(sessionID: UUID, runID: UUID) {
        keys.remove(Key(sessionID: sessionID, runID: runID))
    }

    func contains(sessionID: UUID?, runID: UUID?) -> Bool {
        guard let sessionID, let runID else { return false }
        return keys.contains(Key(sessionID: sessionID, runID: runID))
    }
}
