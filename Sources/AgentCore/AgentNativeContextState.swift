import AgentModels
import Foundation

/// One Session's effective view. Canonical history remains owned by AgentSession.
package actor AgentNativeContextState {
    package init() {}
    private var checkpoint: ModelNativeContextCheckpoint?
    private var handoff: AgentContextHandoff?
    private var validatedHandoffID: UUID?
    private var restored = false
    private var validatedID: UUID?
    func restore(_ value: ModelNativeContextCheckpoint?, handoff: AgentContextHandoff? = nil) {
        guard !restored else { return }; restored = true; checkpoint = value; self.handoff = handoff
    }
    func current() -> ModelNativeContextCheckpoint? { checkpoint }
    func currentHandoff() -> AgentContextHandoff? { handoff }
    func installHandoff(_ value: AgentContextHandoff) { handoff = value; checkpoint = nil; restored = true; validatedID = nil; validatedHandoffID = value.id }
    func ordinaryMessages(_ canonical: [ModelMessage]) throws -> [ModelMessage] { try handoff?.ordinaryView(canonical) ?? canonical }
    func rejectRetiredReinjection(_ projected: [ModelMessage], canonical: [ModelMessage]) throws {
        try handoff?.rejectReinjection(projected, canonical: canonical)
    }
    func install(_ value: ModelNativeContextCheckpoint) { checkpoint = value; restored = true; validatedID = value.id }

    func effectiveMessages(_ canonical: [ModelMessage], binding: AgentModelBinding,
                           sessionID: UUID, journal: AgentJournal?, structuredOutput: StructuredOutputSchema?) async throws -> [ModelMessage] {
        let original = canonical
        if let handoff {
            guard handoff.targetOrigin == binding.continuationOrigin,
                  handoff.targetRootDigest == (try Self.rootDigest(original, binding: binding, structuredOutput: structuredOutput)) else {
                throw AgentModelBindingError.incompatibleContinuation
            }
            if validatedHandoffID != handoff.id, let journal, journal.storage == .durable {
                let anchor = try await journal.readMessages(sessionID: sessionID, after: UInt64(handoff.canonicalMessageCount - 1), limit: 1)
                let leading = original.prefix { $0.role == .system || $0.role == .developer }.count
                guard anchor.count == 1, anchor[0].id == handoff.lastMessageID,
                      original.indices.contains(leading + handoff.canonicalMessageCount - 1),
                      anchor[0].message == original[leading + handoff.canonicalMessageCount - 1] else { throw AgentJournalError.concurrentWriter }
                validatedHandoffID = handoff.id
            }
        }
        let canonical = try ordinaryMessages(original)
        guard let checkpoint else { return canonical }
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        let formalCount = canonical.count - leading
        guard checkpoint.transition.source.canonicalMessageCount > 0,
              checkpoint.canonicalTailStart >= checkpoint.transition.source.canonicalMessageCount,
              checkpoint.generation > 0, !checkpoint.continuation.payload.isEmpty,
              checkpoint.continuation.contextTransition == checkpoint.transition,
              checkpoint.continuation.model == binding.model,
              checkpoint.continuation.origin == binding.continuationOrigin,
              checkpoint.transition.source.sessionID == sessionID,
              checkpoint.canonicalTailStart <= formalCount,
              checkpoint.rootConfigurationDigest == (try Self.rootDigest(canonical, binding: binding, structuredOutput: structuredOutput)) else {
            throw AgentModelBindingError.incompatibleContinuation
        }
        if validatedID != checkpoint.id {
            let source = checkpoint.transition.source
            if let journal, journal.storage == .durable {
                let anchor = try await journal.readMessages(sessionID: sessionID, after: UInt64(source.canonicalMessageCount - 1), limit: 1)
                guard anchor.count == 1, anchor[0].id == source.lastMessageID,
                      anchor[0].message == original[leading + source.canonicalMessageCount - 1] else {
                    throw AgentJournalError.concurrentWriter
                }
            }
            if let lineage = checkpoint.preservedThinkingLineage {
                let cut = checkpoint.canonicalTailStart
                guard lineage.boundary.source.sessionID == sessionID,
                      lineage.boundary.source.canonicalMessageCount == cut,
                      lineage.boundary.origin == binding.continuationOrigin,
                      lineage.boundary.rootConfigurationDigest == checkpoint.rootConfigurationDigest,
                      lineage.parentCheckpointID == source.previousCheckpointID,
                      lineage.tailMessageCount > 0, lineage.tailMessageCount <= formalCount - cut,
                      !lineage.boundary.witness.qualificationScope.isEmpty,
                      try AgentContextProjectionSource.digest(messages: Array(canonical.dropFirst(leading + cut).prefix(lineage.tailMessageCount))) == lineage.tailDigest,
                      case .assistant(let firstContent, _) = canonical[leading + cut],
                      firstContent.contains(where: { if case .providerContinuation(let state) = $0 { state.requestBoundary == lineage.boundary } else { false } }) else {
                    throw AgentModelBindingError.incompatibleContinuation
                }
            }
            // Restoration validates once. Normal appends use the stable anchor and history CAS;
            // neither publication revision nor every covered message is hashed on every request.
            validatedID = checkpoint.id
        }
        return Array(canonical.prefix(leading)) + canonical.dropFirst(leading + checkpoint.canonicalTailStart)
    }

    func pendingCalls(in canonical: [ModelMessage]) -> Set<ToolCallID> {
        guard let checkpoint else { return [] }
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        let last = leading + checkpoint.canonicalTailStart - 1
        guard last >= leading, last < canonical.count,
              case .assistant(_, let calls) = canonical[last] else { return [] }
        return Set(calls.map(\.id))
    }

    static func rootDigest(_ canonical: [ModelMessage], binding: AgentModelBinding,
                           structuredOutput: StructuredOutputSchema?) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let scope = try encoder.encode(binding.continuationOrigin)
        let output = try encoder.encode(structuredOutput)
        return try AgentContextProjectionSource.digest(messages: Array(canonical.prefix { $0.role == .system || $0.role == .developer }) + [
            .system(String(decoding: scope, as: UTF8.self)), .system(String(decoding: output, as: UTF8.self))])
    }

    func source(for prepared: AgentPreparedModelRequest, sessionID: UUID, journal: AgentJournal?,
                provider: any ModelProvider, compactionMode: ModelCompactionMode? = nil) async throws -> ModelNativeContextSource {
        let canonical = prepared.canonicalMessages
        let leading = canonical.prefix { $0.role == .system || $0.role == .developer }.count
        let count = canonical.count - leading
        guard count > 0 else { throw ModelProviderError(kind: .invalidRequest, message: "A closed conversation is required for native context.") }
        var anchor: UUID?
        if let journal, journal.storage == .durable {
            let page = try await journal.readMessages(sessionID: sessionID, after: UInt64(count - 1), limit: 1)
            guard page.count == 1, page[0].message == canonical.last else { throw AgentJournalError.concurrentWriter }
            anchor = page[0].id
        }
        let prior = checkpoint
        // A chained digest includes the immutable prior checkpoint, and the actual uncovered source.
        let covered = prior?.canonicalTailStart ?? 0
        let digestMessages = [ModelMessage.system(prior?.transition.source.canonicalDigest ?? "initial")] + canonical.dropFirst(leading + covered)
        let requestDigest: String
        if let witness = provider as? any ModelProviderNativeContextWitness {
            requestDigest = try witness.nativeContextRequestDigest(request: prepared.request, compactionMode: compactionMode)
        } else {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            requestDigest = ModelImageDigest.sha256Hex(try encoder.encode(prepared.request))
        }
        return .init(sessionID: sessionID, canonicalMessageCount: count, lastMessageID: anchor,
                     canonicalDigest: try AgentContextProjectionSource.digest(messages: digestMessages),
                     requestDigest: requestDigest,
                     projectionID: prepared.projection.plan.projectionID, projectionVersion: prepared.projection.plan.version,
                     previousCheckpointID: prior?.id)
    }

    func candidate(_ state: ModelProviderContinuation, request: ModelRequest, canonicalTailStart: Int,
                   canonical: [ModelMessage], binding: AgentModelBinding,
                   usage: ModelUsage) throws -> ModelNativeContextCheckpoint {
        guard let transition = state.contextTransition, let source = request.nativeContextSource,
              transition.source == source, transition.invocationID == request.invocationID,
              source.previousCheckpointID == checkpoint?.id,
              state.model == binding.model, state.origin == nil || state.origin == binding.continuationOrigin,
              !(state.payload.isEmpty), !state.format.isEmpty,
              canonicalTailStart >= source.canonicalMessageCount,
              canonicalTailStart <= canonical.count - canonical.prefix { $0.role == .system || $0.role == .developer }.count,
              checkpoint?.generation != .max else { throw AgentModelBindingError.incompatibleContinuation }
        let scoped = ModelProviderContinuation(model: state.model, format: state.format, payload: state.payload,
                                               origin: binding.continuationOrigin, contextTransition: transition)
        return .init(id: UUID(), generation: (checkpoint?.generation ?? 0) + 1, continuation: scoped,
                     transition: transition, rootConfigurationDigest: try Self.rootDigest(canonical, binding: binding, structuredOutput: request.structuredOutput),
                     toolBaseline: request.tools, usage: usage, canonicalTailStart: canonicalTailStart)
    }
}
