import AgentModels
import Foundation

/// One Session's effective view. Canonical history remains owned by AgentSession.
package actor AgentNativeContextState {
    package init() {}
    private var checkpoint: ModelNativeContextCheckpoint?
    private var restored = false
    private var validatedID: UUID?
    func restore(_ value: ModelNativeContextCheckpoint?) {
        guard !restored else { return }; restored = true; checkpoint = value
    }
    func current() -> ModelNativeContextCheckpoint? { checkpoint }
    func install(_ value: ModelNativeContextCheckpoint) { checkpoint = value; restored = true; validatedID = value.id }

    func effectiveMessages(_ canonical: [ModelMessage], binding: AgentModelBinding,
                           sessionID: UUID, journal: AgentJournal?, structuredOutput: StructuredOutputSchema?) async throws -> [ModelMessage] {
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
                      anchor[0].message == canonical[leading + source.canonicalMessageCount - 1] else {
                    throw AgentJournalError.concurrentWriter
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
