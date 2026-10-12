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
    private enum CodingKeys: String, CodingKey {
        case maxAttempts, maxRetriesPerProvider, retryableKinds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            maxAttempts: values.decode(Int.self, forKey: .maxAttempts),
            maxRetriesPerProvider: values.decode(Int.self, forKey: .maxRetriesPerProvider),
            retryableKinds: values.decode(Set<ModelProviderError.Kind>.self, forKey: .retryableKinds)
        )
    }

}

public enum ModelProviderFallbackPolicyError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidRetryableKinds
    case emptyCandidates
    case candidateProviderIDMismatch(routeID: String, candidateID: String)
    case invalidCandidateIdentity
}

/// Composes validated model turns without executing tools or owning an agent loop.
/// A mutation boundary blocks switching to another candidate for that run.
///
/// Candidates are separate service instances. Opaque continuation state a candidate produces
/// is returned only to that candidate: a request carrying it is served by its owner or refused
/// with `fallbackBlocked`, and state the Route cannot attribute to a candidate is refused too.
public struct ModelProviderRoute: ModelProvider, ModelProviderMutationBoundary, ModelProviderRunDrain {
    /// One service instance. The ID names that deployment (endpoint, account, configuration)
    /// for as long as conversations holding its continuation state may continue; do not reuse
    /// an ID for a different deployment. Order is fallback preference and may change freely.
    public struct Candidate: Sendable {
        public let id: String
        public let provider: any ModelProvider

        public init(id: String, provider: any ModelProvider) {
            self.id = id
            self.provider = provider
        }
    }

    public let descriptor: ModelProviderDescriptor
    private let candidates: [Candidate]
    private let policy: ModelProviderFallbackPolicy
    private let boundaryState: MutationBoundaryState

    /// Candidates without declared identities are known only to this Route instance, so their
    /// continuation state is refused after a restart. Declare `Candidate` IDs to keep it usable.
    public init(
        id: String,
        candidates: [any ModelProvider],
        policy: ModelProviderFallbackPolicy = try! .init()
    ) throws {
        let instance = UUID().uuidString
        try self.init(id: id, candidates: candidates.enumerated().map {
            Candidate(id: "anonymous:\(instance):\($0.offset)", provider: $0.element)
        }, policy: policy)
    }

    public init(
        id: String,
        candidates: [Candidate],
        policy: ModelProviderFallbackPolicy = try! .init()
    ) throws {
        guard !candidates.isEmpty else { throw ModelProviderFallbackPolicyError.emptyCandidates }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderFallbackPolicyError.emptyCandidates
        }
        if let candidate = candidates.first(where: { $0.provider.descriptor.id != id }) {
            throw ModelProviderFallbackPolicyError.candidateProviderIDMismatch(
                routeID: id,
                candidateID: candidate.provider.descriptor.id
            )
        }
        guard candidates.allSatisfy({ Self.validCandidateID($0.id) }),
              Set(candidates.map { Array($0.id.utf8) }).count == candidates.count else {
            throw ModelProviderFallbackPolicyError.invalidCandidateIdentity
        }
        self.candidates = candidates
        self.policy = policy
        self.boundaryState = MutationBoundaryState()
        var capabilities = candidates.dropFirst().reduce(candidates[0].provider.descriptor.capabilities) { current, candidate in
            ModelCapabilities(rawValue: current.rawValue & candidate.provider.descriptor.capabilities.rawValue)
        }
        capabilities.remove(.streaming)
        descriptor = ModelProviderDescriptor(id: id, capabilities: capabilities)
    }

    private static func validCandidateID(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 256
            && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            try await streamValidated(request: request, emit: emit)
        }
    }

    public func markMutationBoundary(sessionID: UUID, runID: UUID) async {
        await boundaryState.mark(sessionID: sessionID, runID: runID)
        for candidate in candidates {
            guard let boundary = candidate.provider as? any ModelProviderMutationBoundary else { continue }
            await boundary.markMutationBoundary(sessionID: sessionID, runID: runID)
        }
    }

    public func clearMutationBoundary(sessionID: UUID, runID: UUID) async {
        await boundaryState.clear(sessionID: sessionID, runID: runID)
        for candidate in candidates {
            guard let boundary = candidate.provider as? any ModelProviderMutationBoundary else { continue }
            await boundary.clearMutationBoundary(sessionID: sessionID, runID: runID)
        }
    }

    public func waitForRunToDrain(sessionID: UUID, runID: UUID) async {
        for candidate in candidates {
            guard let provider = candidate.provider as? any ModelProviderRunDrain else { continue }
            await provider.waitForRunToDrain(sessionID: sessionID, runID: runID)
        }
    }

    private func streamValidated(request: ModelRequest, emit: @escaping ModelEventStream.Emit) async throws {
        guard request.model.provider.utf8.elementsEqual(descriptor.id.utf8) else {
            throw ModelProviderError(kind: .invalidRequest, message: "Provider route does not serve this model namespace.")
        }

        let (owner, request) = try continuationOwner(of: request)
        let admission = await boundaryState.admission(sessionID: request.sessionID, runID: request.runID)
        if request.nativeContextSource != nil || request.nativeContext != nil {
            // Exact wire provenance is qualified for one actual owner. A retry would
            // need a new managed invocation; never silently reuse its identity.
            let index = try nativeOwnerIndex(owner: owner, request: request)
            if admission.boundaryReached, let pinned = admission.pinnedCandidateIndex, pinned != index {
                throw OwnedContinuation.unknownOrigin
            }
            let events = try await validatedEvents(from: candidates[index].provider, request: request)
            try emitOwned(events, by: candidates[index], emit: emit)
            await boundaryState.recordValidatedCandidate(sessionID: request.sessionID, runID: request.runID,
                generation: admission.generation, candidateIndex: index)
            return
        }
        if admission.boundaryReached || owner != nil {
            return try await streamPinnedCandidate(admission, owner: owner, request: request, emit: emit)
        }

        var attempts = 0
        var lastError: (any Error)?
        for (candidateIndex, candidate) in candidates.enumerated() {
            var retries = 0
            while attempts < policy.maxAttempts {
                try Task.checkCancellation()
                attempts += 1
                do {
                    let events = try await validatedEvents(from: candidate.provider, request: request)
                    try emitOwned(events, by: candidate, emit: emit)
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
                    if retries < policy.maxRetriesPerProvider, attempts < policy.maxAttempts {
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

    /// Serves a Run pinned by a mutation boundary, or a request holding one candidate's
    /// continuation state, from that one candidate. Another candidate is never tried.
    private func streamPinnedCandidate(
        _ admission: MutationBoundaryState.Admission,
        owner: Int?,
        request: ModelRequest,
        emit: @escaping ModelEventStream.Emit
    ) async throws {
        if admission.boundaryReached, let owner, let pinned = admission.pinnedCandidateIndex, pinned != owner {
            throw ModelProviderError(kind: .fallbackBlocked,
                                     message: "Provider continuation state belongs to a candidate other than the pinned one.")
        }
        // A direct boundary mark without a prior validated turn keeps the old conservative
        // contract: probe the first candidate once, then pin it if it validates. Never search
        // later candidates from an unowned boundary.
        let candidateIndex = owner ?? admission.pinnedCandidateIndex ?? 0
        let candidate = candidates[candidateIndex]
        // Only the continuation owner may retry itself, and only before a mutation boundary.
        let retries = admission.boundaryReached ? 0 : min(policy.maxRetriesPerProvider, policy.maxAttempts - 1)
        var attempt = 0
        while true {
            do {
                let events = try await validatedEvents(from: candidate.provider, request: request)
                try emitOwned(events, by: candidate, emit: emit)
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ModelProviderError where attempt < retries && policy.retryableKinds.contains(error.kind) {
                attempt += 1
                if let retryAfter = error.retryAfter { try await Task.sleep(for: retryAfter) }
            } catch let error as ModelProviderError {
                let couldRetry = admission.boundaryReached && policy.maxRetriesPerProvider > 0
                let hasOtherCandidate = owner != nil ? candidates.count > 1 : candidateIndex + 1 < candidates.count
                if policy.retryableKinds.contains(error.kind), couldRetry || hasOtherCandidate {
                    throw ModelProviderError(
                        kind: .fallbackBlocked,
                        message: admission.boundaryReached
                            ? "Provider fallback is blocked after a mutation boundary."
                            : "Provider fallback is blocked: another candidate cannot continue this candidate's state."
                    )
                }
                throw error
            }
        }
        if admission.pinnedCandidateIndex == nil {
            await boundaryState.recordValidatedCandidate(
                sessionID: request.sessionID,
                runID: request.runID,
                generation: admission.generation,
                candidateIndex: candidateIndex
            )
        }
    }

    /// Records which candidate produced each continuation, so later requests return it to that
    /// candidate only. The same state is wrapped identically in its delta and in the response.
    private func emitOwned(_ events: [ModelEvent], by candidate: Candidate, emit: ModelEventStream.Emit) throws {
        var wrapped: [ModelProviderContinuation: ModelProviderContinuation] = [:]
        func own(_ state: ModelProviderContinuation) throws -> ModelProviderContinuation {
            if let existing = wrapped[state] { return existing }
            let owned = try OwnedContinuation.wrap(state, candidate: candidate.id)
            wrapped[state] = owned
            return owned
        }
        for event in events {
            switch event {
            case .providerContinuation(let state):
                try emit(.providerContinuation(try own(state)))
            case .responseCompleted(let response):
                try emit(.responseCompleted(.init(
                    info: response.info,
                    content: try response.content.map { part in
                        guard case .providerContinuation(let state) = part else { return part }
                        return .providerContinuation(try own(state))
                    },
                    toolCalls: response.toolCalls,
                    usage: response.usage,
                    stopReason: response.stopReason, inputTransformations: response.inputTransformations
                )))
            default:
                try emit(event)
            }
        }
    }

    /// Finds the one candidate that owns every continuation in the request and returns the
    /// request with that candidate's native state. State of unknown or mixed origin is refused
    /// before any candidate receives it.
    private func continuationOwner(of request: ModelRequest) throws -> (Int?, ModelRequest) {
        var owner: Int?
        var changed = false
        let messages = try request.messages.map { message -> ModelMessage in
            guard case .assistant(let content, let calls) = message,
                  content.contains(where: { if case .providerContinuation = $0 { true } else { false } }) else {
                return message
            }
            changed = true
            return .assistant(content: try content.map { part in
                guard case .providerContinuation(let state) = part else { return part }
                let (candidateID, native) = try OwnedContinuation.unwrap(state)
                guard let index = candidates.firstIndex(where: { $0.id.utf8.elementsEqual(candidateID.utf8) }),
                      owner == nil || owner == index else {
                    throw OwnedContinuation.unknownOrigin
                }
                owner = index
                return .providerContinuation(native)
            }, toolCalls: calls)
        }
        let checkpoint: ModelNativeContextCheckpoint?
        if let value = request.nativeContext {
            let (candidateID, native) = try OwnedContinuation.unwrap(value.continuation)
            guard let index = candidates.firstIndex(where: { $0.id.utf8.elementsEqual(candidateID.utf8) }),
                  owner == nil || owner == index else { throw OwnedContinuation.unknownOrigin }
            owner = index; changed = true
            checkpoint = .init(id: value.id, generation: value.generation, continuation: native, transition: value.transition,
                rootConfigurationDigest: value.rootConfigurationDigest, toolBaseline: value.toolBaseline,
                usage: value.usage, canonicalTailStart: value.canonicalTailStart)
        } else { checkpoint = nil }
        guard changed else { return (nil, request) }
        return (owner, ModelRequest(model: request.model, messages: messages, tools: request.tools,
                                    structuredOutput: request.structuredOutput,
                                    sessionID: request.sessionID, runID: request.runID, nativeContext: checkpoint,
                                    nativeContextSource: request.nativeContextSource, invocationID: request.invocationID))
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

extension ModelProviderRoute: ModelProviderNativeContextWitness, ModelProviderRequestValidator {
    /// A Route only advertises modes implemented and qualified by every candidate.
    public var compactionModes: Set<ModelCompactionMode> {
        candidates.reduce(Set([.anthropicThreshold, .anthropicOnDemand, .openAIAutomatic, .openAIStandalone])) {
            $0.intersection(($1.provider as? any ModelProviderCompaction)?.compactionModes ?? [])
        }
    }
    public var automaticCompaction: ModelAutomaticCompaction? {
        let values = candidates.map { ($0.provider as? any ModelProviderCompaction)?.automaticCompaction }
        guard let first = values.first ?? nil, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    private func nativeOwner(_ request: ModelRequest) throws -> (Candidate, ModelRequest) {
        let (owner, unwrapped) = try continuationOwner(of: request)
        return (candidates[try nativeOwnerIndex(owner: owner, request: request)], unwrapped)
    }
    private func nativeOwnerIndex(owner: Int?, request: ModelRequest) throws -> Int {
        let selected = boundaryState.nativeOwners.selected(sessionID: request.sessionID, runID: request.runID)
        if let owner, let selected, owner != selected { throw OwnedContinuation.unknownOrigin }
        return owner ?? selected ?? 0
    }
    public func validate(request: ModelRequest) throws {
        guard request.nativeContext != nil || request.nativeContextSource != nil || candidates.contains(where: { ($0.provider as? any ModelProviderCompaction)?.automaticCompaction != nil }) else { return }
        let (candidate, unwrapped) = try nativeOwner(request)
        if candidates.contains(where: { ($0.provider as? any ModelProviderCompaction)?.automaticCompaction != nil }), automaticCompaction == nil {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Route candidates must agree on their automatic compaction policy.")
        }
        try (candidate.provider as? any ModelProviderRequestValidator)?.validate(request: unwrapped)
    }
    public func nativeContextRequestDigest(request: ModelRequest, compactionMode: ModelCompactionMode?) throws -> String {
        let (candidate, unwrapped) = try nativeOwner(request)
        guard let provider = candidate.provider as? any ModelProviderNativeContextWitness else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "The native owner cannot bind an exact request.")
        }
        return try provider.nativeContextRequestDigest(request: unwrapped, compactionMode: compactionMode)
    }
    public func validateCompaction(request: ModelCompactionRequest) throws {
        let (candidate, unwrapped) = try nativeOwner(request.request)
        guard compactionModes.contains(request.mode), let provider = candidate.provider as? any ModelProviderCompaction else {
            throw ModelProviderError(kind: .unsupportedCapability, message: "Route native compaction is not qualified.")
        }
        try provider.validateCompaction(request: .init(request: unwrapped, mode: request.mode,
            operationID: request.operationID, invocationID: request.invocationID))
    }
    public func compact(request: ModelCompactionRequest) -> AsyncThrowingStream<ModelCompactionEvent, Error> {
        AsyncThrowingStream { continuation in
            guard !Task.isCancelled else { continuation.finish(throwing: CancellationError()); return }
            let worker = Task {
                do {
                    try Task.checkCancellation()
                    try validateCompaction(request: request)
                    let (candidate, unwrapped) = try nativeOwner(request.request)
                    let provider = candidate.provider as! any ModelProviderCompaction // validated above
                    for try await event in provider.compact(request: .init(request: unwrapped, mode: request.mode,
                        operationID: request.operationID, invocationID: request.invocationID)) {
                        try Task.checkCancellation()
                        if case .completed(let response) = event {
                            let state = try response.continuation.map { try OwnedContinuation.wrap($0, candidate: candidate.id) }
                            continuation.yield(.completed(.init(info: response.info, continuation: state, usage: response.usage,
                                nativeStopReason: response.nativeStopReason, inputTransformations: response.inputTransformations)))
                        } else { continuation.yield(event) }
                    }
                    try Task.checkCancellation(); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
    public func waitForCompactionToDrain(sessionID: UUID, operationID: UUID) async {
        for candidate in candidates {
            await (candidate.provider as? any ModelProviderCompaction)?.waitForCompactionToDrain(sessionID: sessionID, operationID: operationID)
        }
    }
}

// Synchronous validators and wire witnesses must observe the same validated owner
// as the actor-managed dispatch path. This cache contains no conversation state.
private final class NativeOwnerCache: @unchecked Sendable {
    private struct Key: Hashable { let sessionID: UUID; let runID: UUID }
    private let lock = NSLock()
    private var owners: [Key: Int] = [:]
    func selected(sessionID: UUID?, runID: UUID?) -> Int? {
        guard let sessionID, let runID else { return nil }
        lock.lock(); defer { lock.unlock() }
        return owners[Key(sessionID: sessionID, runID: runID)]
    }
    func record(sessionID: UUID, runID: UUID, candidateIndex: Int) {
        lock.lock(); defer { lock.unlock() }
        owners[Key(sessionID: sessionID, runID: runID)] = candidateIndex
    }
    func clear(sessionID: UUID, runID: UUID) {
        lock.lock(); defer { lock.unlock() }
        owners.removeValue(forKey: Key(sessionID: sessionID, runID: runID))
    }
}

private actor MutationBoundaryState {
    nonisolated let nativeOwners = NativeOwnerCache()
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
        nativeOwners.clear(sessionID: sessionID, runID: runID)
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
        nativeOwners.record(sessionID: sessionID, runID: runID, candidateIndex: candidateIndex)
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

/// A candidate's continuation as the Route records it: the owning candidate ID with the
/// provider's native format and payload. Only the Route reads it; candidates receive their own
/// state unwrapped.
private struct OwnedContinuation: Codable {
    static let format = "swiftagent.route-candidate.v1"
    static let unknownOrigin = ModelProviderError(
        kind: .fallbackBlocked,
        message: "Provider continuation state was not produced by a candidate of this route."
    )

    let candidate: String
    let format: String
    let payload: Data

    static func wrap(_ state: ModelProviderContinuation, candidate: String) throws -> ModelProviderContinuation {
        let owned = OwnedContinuation(candidate: candidate, format: state.format, payload: state.payload)
        return ModelProviderContinuation(model: state.model, format: format,
                                         payload: try ProviderJSON.encode(owned), origin: state.origin, contextTransition: state.contextTransition)
    }

    static func unwrap(_ state: ModelProviderContinuation) throws -> (String, ModelProviderContinuation) {
        guard state.format.utf8.elementsEqual(format.utf8),
              let owned = try? JSONDecoder().decode(OwnedContinuation.self, from: state.payload),
              !owned.format.isEmpty, !owned.payload.isEmpty else { throw unknownOrigin }
        return (owned.candidate, ModelProviderContinuation(model: state.model, format: owned.format,
                                                           payload: owned.payload, origin: state.origin, contextTransition: state.contextTransition))
    }
}
