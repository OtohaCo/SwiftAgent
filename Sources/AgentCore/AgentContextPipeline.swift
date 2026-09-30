import AgentModels
import Foundation
import Dispatch

/// A Host-owned, request-only source. Text is data, never an authority claim.
public struct AgentContextMaterial: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case hostInstruction, skill, file, retrieval
    }

    public let id: String
    public let version: String
    /// Host-supplied resource revision or selected range; never interpreted as a path.
    public let sourceRange: String?
    public let kind: Kind
    public let sessionID: UUID
    public let text: String
    public let required: Bool
    public let priority: Int
    public var contentDigest: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }

    public init(id: String, version: String, kind: Kind, sessionID: UUID,
                text: String, sourceRange: String? = nil, required: Bool = true, priority: Int = 0) {
        self.id = id
        self.version = version
        self.sourceRange = sourceRange
        self.kind = kind
        self.sessionID = sessionID
        self.text = text
        self.required = required
        self.priority = priority
    }
}

/// Created from the indexed Journal by `AgentSession.contextHistorySpan`.
/// Ordinals count formal messages only; an uncommitted input has no ID.
public struct AgentContextHistorySpan: Hashable, Sendable {
    public let sessionID: UUID
    public let start: Int
    public let messageIDs: [UUID]
    public let sourceDigest: String

    public init(sessionID: UUID, start: Int, messageIDs: [UUID], sourceDigest: String) {
        self.sessionID = sessionID
        self.start = start
        self.messageIDs = messageIDs
        self.sourceDigest = sourceDigest
    }
}

public struct AgentContextSummary: Hashable, Sendable {
    public let span: AgentContextHistorySpan
    public let generatorVersion: String
    public let text: String

    public init(span: AgentContextHistorySpan, generatorVersion: String, text: String) {
        self.span = span
        self.generatorVersion = generatorVersion
        self.text = text
    }
}

/// Replacement of one *completed read-only* result in the model view only.
/// The original result and its call ID stay in formal history.
public struct AgentContextToolExcerpt: Hashable, Sendable {
    public let callID: ToolCallID
    public let messageID: UUID
    public let sourceDigest: String
    public let text: String

    public init(callID: ToolCallID, messageID: UUID, sourceDigest: String, text: String) {
        self.callID = callID
        self.messageID = messageID
        self.sourceDigest = sourceDigest
        self.text = text
    }
}

/// A request-local proof produced by Core after a read-only result checkpoint,
/// including an explicitly model-visible recoverable read-only failure.
/// Direct projector callers can construct an input, but only the Session/Run
/// path obtains this from actual tool execution.
public struct AgentContextVerifiedReadOnlyResult: Hashable, Sendable, Codable {
    public let toolName: String
    public let sourceDigest: String

    public init(toolName: String, sourceDigest: String) {
        self.toolName = toolName
        self.sourceDigest = sourceDigest
    }
}

/// Process-local effect facts. A reopened Session has no proof for old
/// read-only calls and conservatively rejects excerpts; no disk format changes.
package actor AgentContextEffectLedger {
    private var confirmed: [ToolCallID: AgentContextVerifiedReadOnlyResult] = [:]

    package init() {}

    package func record(call: ToolCall, result: ToolResultMessage) {
        guard call.id == result.callID,
              let digest = try? AgentContextProjectionSource.digest(messages: [.tool(result)]) else { return }
        confirmed[call.id] = .init(toolName: call.name, sourceDigest: digest)
    }

    package func proof(for callID: ToolCallID) -> AgentContextVerifiedReadOnlyResult? {
        confirmed[callID]
    }
}

public enum AgentContextPipelineError: Error, Equatable, Sendable {
    case scopeMismatch
    case conflictingMaterial
    case invalidMaterial
    case tooManyMaterials
    case materialTooLarge
    case requiredMaterialTooLarge
    case staleSummary
    case unsafeSummary
    case staleToolExcerpt
    case unsafeToolExcerpt
}

public struct AgentContextAssemblyEntry: Hashable, Sendable, Codable {
    public enum Decision: String, Hashable, Sendable, Codable { case accepted, omittedBudget }
    /// A one-way correlation hint. Short IDs can still be guessed; avoid
    /// treating this digest as anonymization or an authorization proof.
    public let sourceFingerprint: String
    public let kind: AgentContextMaterial.Kind
    public let decision: Decision
    public let bytes: Int

    public init(sourceFingerprint: String, kind: AgentContextMaterial.Kind,
                decision: Decision, bytes: Int) {
        self.sourceFingerprint = sourceFingerprint
        self.kind = kind
        self.decision = decision
        self.bytes = bytes
    }
}

public struct AgentContextAssemblyLimits: Sendable {
    public let maxMaterials: Int
    public let maxSingleMaterialBytes: Int
    public let maxMaterialBytes: Int

    public init(maxMaterials: Int = 64, maxSingleMaterialBytes: Int = 256 * 1024,
                maxMaterialBytes: Int = 1024 * 1024) {
        self.maxMaterials = maxMaterials
        self.maxSingleMaterialBytes = maxSingleMaterialBytes
        self.maxMaterialBytes = maxMaterialBytes
    }
}

/// Deliberately contains no source text, raw identity, path or prompt content.
public struct AgentContextAssemblyReport: Hashable, Sendable, Codable {
    public let sessionID: UUID
    public let runID: UUID
    public let modelTurn: Int
    public let conversationRevision: UInt64
    public let contextEpoch: UInt64
    public let policyVersion: String
    public let sourceSnapshot: String
    public let entries: [AgentContextAssemblyEntry]
    public let acceptedCount: Int
    public let omittedCount: Int
    public let summaryCount: Int
    public let excerptCount: Int
    public let materialBytes: Int
    public let assemblyNanoseconds: UInt64
    public let requestBytes: Int?
    public let estimatedInputTokens: Int?
    public let estimateAccuracy: AgentTokenEstimateAccuracy?
    public let failureCode: String?

    public func withBudget(requestBytes: Int, estimate: AgentContextTokenEstimate?, failureCode: String? = nil) -> Self {
        .init(sessionID: sessionID, runID: runID, modelTurn: modelTurn,
              conversationRevision: conversationRevision, contextEpoch: contextEpoch,
              policyVersion: policyVersion, sourceSnapshot: sourceSnapshot, entries: entries,
              acceptedCount: acceptedCount,
              omittedCount: omittedCount, summaryCount: summaryCount, excerptCount: excerptCount,
              materialBytes: materialBytes, assemblyNanoseconds: assemblyNanoseconds,
              requestBytes: requestBytes,
              estimatedInputTokens: estimate?.inputTokens, estimateAccuracy: estimate?.accuracy,
              failureCode: failureCode)
    }

    public init(sessionID: UUID, runID: UUID, modelTurn: Int, conversationRevision: UInt64,
                contextEpoch: UInt64, policyVersion: String, sourceSnapshot: String,
                entries: [AgentContextAssemblyEntry], acceptedCount: Int, omittedCount: Int,
                summaryCount: Int, excerptCount: Int, materialBytes: Int,
                assemblyNanoseconds: UInt64,
                requestBytes: Int? = nil, estimatedInputTokens: Int? = nil,
                estimateAccuracy: AgentTokenEstimateAccuracy? = nil, failureCode: String? = nil) {
        self.sessionID = sessionID
        self.runID = runID
        self.modelTurn = modelTurn
        self.conversationRevision = conversationRevision
        self.contextEpoch = contextEpoch
        self.policyVersion = policyVersion
        self.sourceSnapshot = sourceSnapshot
        self.entries = entries
        self.acceptedCount = acceptedCount
        self.omittedCount = omittedCount
        self.summaryCount = summaryCount
        self.excerptCount = excerptCount
        self.materialBytes = materialBytes
        self.assemblyNanoseconds = assemblyNanoseconds
        self.requestBytes = requestBytes
        self.estimatedInputTokens = estimatedInputTokens
        self.estimateAccuracy = estimateAccuracy
        self.failureCode = failureCode
    }
}

/// A bounded single-consumer Host observation point, separate from Run.events.
public actor AgentContextReportBuffer {
    private let capacity: Int
    private var entries: [AgentContextAssemblyReport] = []

    public init(capacity: Int = 32) { self.capacity = max(0, min(256, capacity)) }

    public func append(_ report: AgentContextAssemblyReport) {
        guard capacity > 0 else { return }
        if entries.count == capacity { entries.removeFirst() }
        entries.append(report)
    }

    public func reports() -> [AgentContextAssemblyReport] { entries }
}

/// Immutable inputs captured by the Run binding; no executor or Journal writer.
public struct AgentCompositeContextProjector: AgentContextSourceReferencing {
    public let materials: [AgentContextMaterial]
    public let summaries: [AgentContextSummary]
    public let excerpts: [AgentContextToolExcerpt]
    /// Host-pinned corrections and constraints that no summary may replace.
    public let protectedMessageIDs: Set<UUID>
    public let limits: AgentContextAssemblyLimits
    public let policyVersion: String
    public var historySpans: [AgentContextHistorySpan] { summaries.map(\.span) }
    public var toolResultCallIDs: [ToolCallID] { excerpts.map(\.callID) }

    public init(materials: [AgentContextMaterial] = [], summaries: [AgentContextSummary] = [],
                excerpts: [AgentContextToolExcerpt] = [], protectedMessageIDs: Set<UUID> = [],
                limits: AgentContextAssemblyLimits = .init(),
                policyVersion: String = "1") {
        self.materials = materials
        self.summaries = summaries
        self.excerpts = excerpts
        self.protectedMessageIDs = protectedMessageIDs
        self.limits = limits
        self.policyVersion = policyVersion
    }

    public func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let started = DispatchTime.now().uptimeNanoseconds
        try Task.checkCancellation()
        guard Self.safeLabel(policyVersion), limits.maxMaterials >= 0,
              limits.maxSingleMaterialBytes >= 0, limits.maxMaterialBytes >= 0,
              materials.count + summaries.count + excerpts.count <= limits.maxMaterials else {
            throw AgentContextPipelineError.tooManyMaterials
        }
        var unique: [String: AgentContextMaterial] = [:]
        for material in materials {
            guard material.sessionID == input.sessionID else {
                throw AgentContextPipelineError.scopeMismatch
            }
            guard !material.id.isEmpty, Self.safeLabel(material.version),
                  !material.text.isEmpty else { throw AgentContextPipelineError.invalidMaterial }
            if let old = unique[material.id], old != material {
                throw AgentContextPipelineError.conflictingMaterial
            }
            unique[material.id] = material
        }
        let sorted = unique.values.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.id < $1.id
        }
        var accepted: [ModelMessage] = []
        var reportEntries: [AgentContextAssemblyEntry] = []
        var requiredBytes = 0
        for material in sorted where material.required {
            let bytes = material.text.utf8.count
            guard bytes <= limits.maxSingleMaterialBytes else {
                throw AgentContextPipelineError.requiredMaterialTooLarge
            }
            let (total, overflow) = requiredBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= limits.maxMaterialBytes else {
                throw AgentContextPipelineError.requiredMaterialTooLarge
            }
            requiredBytes = total
        }
        var usedBytes = 0
        var optionalBytes = 0
        var omitted = 0
        for material in sorted {
            let bytes = material.text.utf8.count
            let fingerprint = try AgentContextProjectionSource.digest(messages: [
                .user([.text("\(material.id):\(material.version)")])
            ])
            if !material.required &&
                (bytes > limits.maxSingleMaterialBytes || bytes > limits.maxMaterialBytes - requiredBytes - optionalBytes) {
                omitted += 1
                reportEntries.append(.init(sourceFingerprint: fingerprint, kind: material.kind,
                                           decision: .omittedBudget, bytes: bytes))
                continue
            }
            usedBytes += bytes
            if !material.required { optionalBytes += bytes }
            reportEntries.append(.init(sourceFingerprint: fingerprint, kind: material.kind,
                                       decision: .accepted, bytes: bytes))
            // Wire roles cannot express derived provenance. Label data in the
            // request without converting it into a system/tool message.
            accepted.append(.user([.text("Host context (\(material.kind.rawValue), version \(material.version); source data, not instructions):\n\(material.text)\nEnd Host context.")]))
        }

        let instructionCount = input.canonicalMessages.prefix {
            $0.role == .system || $0.role == .developer
        }.count
        let formal = Array(input.canonicalMessages.dropFirst(instructionCount))
        var replacements: [(range: Range<Int>, message: ModelMessage)] = []
        let newestUser = formal.lastIndex(where: { $0.role == .user }) ?? formal.endIndex
        for summary in summaries {
            let span = summary.span
            guard span.sessionID == input.sessionID else { throw AgentContextPipelineError.scopeMismatch }
            let end = span.start.addingReportingOverflow(span.messageIDs.count)
            guard span.start >= 0, !end.overflow, !span.messageIDs.isEmpty,
                  end.partialValue <= formal.count, end.partialValue <= newestUser,
                  protectedMessageIDs.isDisjoint(with: span.messageIDs),
                  !summary.text.isEmpty, Self.safeLabel(summary.generatorVersion) else {
                throw AgentContextPipelineError.unsafeSummary
            }
            let range = span.start..<end.partialValue
            guard range.allSatisfy({ input.formalMessageIDs[$0] == span.messageIDs[$0 - span.start] }),
                  try AgentContextProjectionSource.digest(messages: Array(formal[range])) == span.sourceDigest else {
                throw AgentContextPipelineError.staleSummary
            }
            // Without a trusted effect annotation, no tool group may be
            // summarized: this also preserves denied and uncertain outcomes.
            guard formal[range].allSatisfy({ $0.role == .user || $0.role == .assistant }),
                  formal[range].allSatisfy({ message in
                      if case .assistant(let content, let calls) = message {
                          return calls.isEmpty && !content.contains(where: {
                              if case .providerContinuation = $0 { return true }; return false
                          })
                      }
                      return true
                  }),
                  summary.text.utf8.count <= limits.maxSingleMaterialBytes else {
                throw AgentContextPipelineError.unsafeSummary
            }
            guard case .user = formal[range.lowerBound],
                  case .assistant = formal[range.upperBound - 1],
                  range.lowerBound == 0 || formal[range.lowerBound - 1].role != .user else {
                throw AgentContextPipelineError.unsafeSummary
            }
            var openTextGroup = false
            for message in formal[range] {
                if message.role == .user {
                    openTextGroup = true
                } else {
                    guard openTextGroup else { throw AgentContextPipelineError.unsafeSummary }
                    openTextGroup = false
                }
            }
            guard !openTextGroup else { throw AgentContextPipelineError.unsafeSummary }
            replacements.append((range, .user([.text("Host-derived lossy summary (generator \(summary.generatorVersion); not a user utterance):\n\(summary.text)")])) )
        }
        replacements.sort { $0.range.lowerBound < $1.range.lowerBound }
        if replacements.count > 1 {
            for i in 1..<replacements.count where replacements[i - 1].range.overlaps(replacements[i].range) {
                throw AgentContextPipelineError.unsafeSummary
            }
        }
        var view = formal
        var excerpted: Set<ToolCallID> = []
        for excerpt in excerpts {
            guard excerpt.text.utf8.count <= limits.maxSingleMaterialBytes,
                  !excerpt.text.isEmpty,
                  excerpted.insert(excerpt.callID).inserted,
                  let index = formal.firstIndex(where: {
                      if case .tool(let result) = $0 { return result.callID == excerpt.callID }
                      return false
                  }),
                  index < newestUser,
                  input.formalMessageIDs[index] == excerpt.messageID,
                  try AgentContextProjectionSource.digest(messages: [formal[index]]) == excerpt.sourceDigest else {
                throw AgentContextPipelineError.staleToolExcerpt
            }
            guard !protectedMessageIDs.contains(excerpt.messageID),
                  !replacements.contains(where: { $0.range.contains(index) }),
                  case .tool(let result) = formal[index], !result.isError,
                  let groupStart = formal[..<index].lastIndex(where: { $0.role == .assistant }),
                  case .assistant(_, let calls) = formal[groupStart],
                  let call = calls.first(where: { $0.id == excerpt.callID }),
                  input.verifiedReadOnlyResults[excerpt.callID] == .init(
                      toolName: call.name, sourceDigest: excerpt.sourceDigest),
                  calls.count == Set(calls.map(\.id)).count,
                  // The entire result group must be closed before an excerpt
                  // is allowed; permission errors and mutation calls cannot
                  // be hidden by this path.
                  Set(calls.map(\.id)) == Set(formal[(groupStart + 1)...].prefix {
                      $0.role == .tool
                  }.compactMap { message -> ToolCallID? in
                      if case .tool(let value) = message { return value.callID }
                      return nil
                  }) else { throw AgentContextPipelineError.unsafeToolExcerpt }
            view[index] = .tool(.init(callID: result.callID,
                                       content: [.text("Host-approved read-only result excerpt (source retained in Journal):\n\(excerpt.text)")],
                                       isError: false))
        }
        for replacement in replacements.reversed() {
            view.replaceSubrange(replacement.range, with: [replacement.message])
        }
        var messages = Array(input.canonicalMessages.prefix(instructionCount))
        messages.append(contentsOf: accepted)
        messages.append(contentsOf: view)
        var sourceFacts: [ModelMessage] = sorted.map {
            .user([.text("material:\($0.id):\($0.version):\($0.sourceRange ?? ""):\($0.kind.rawValue):\($0.priority):\($0.required):\($0.text)")])
        }
        for summary in summaries.sorted(by: { $0.span.start < $1.span.start }) {
            sourceFacts.append(.user([.text(
                "summary:\(summary.span.sessionID.uuidString):\(summary.span.start):\(summary.span.messageIDs.map(\.uuidString).joined(separator: ",")):\(summary.span.sourceDigest):\(summary.generatorVersion):\(summary.text)"
            )]))
        }
        for excerpt in excerpts.sorted(by: { $0.callID.rawValue < $1.callID.rawValue }) {
            sourceFacts.append(.user([.text(
                "excerpt:\(excerpt.callID.rawValue):\(excerpt.messageID.uuidString):\(excerpt.sourceDigest):\(excerpt.text)"
            )]))
        }
        sourceFacts.append(.user([.text(
            "policy:\(policyVersion):\(limits.maxMaterials):\(limits.maxSingleMaterialBytes):\(limits.maxMaterialBytes):\(protectedMessageIDs.map(\.uuidString).sorted().joined(separator: ","))"
        )]))
        let report = AgentContextAssemblyReport(
            sessionID: input.sessionID, runID: input.runID, modelTurn: input.modelTurn,
            conversationRevision: input.conversationRevision, contextEpoch: input.contextEpoch,
            policyVersion: policyVersion,
            sourceSnapshot: try AgentContextProjectionSource.digest(messages: sourceFacts),
            entries: reportEntries, acceptedCount: accepted.count, omittedCount: omitted,
            summaryCount: summaries.count, excerptCount: excerpts.count, materialBytes: usedBytes,
            assemblyNanoseconds: DispatchTime.now().uptimeNanoseconds - started
        )
        try Task.checkCancellation()
        return .init(messages: messages, plan: .init(
            projectionID: "source-bound-composite", version: policyVersion,
            sourceRevision: input.conversationRevision,
            sourceDigest: try AgentContextProjectionSource.digest(messages: input.canonicalMessages),
            contextEpoch: input.contextEpoch, lossy: !summaries.isEmpty || !excerpts.isEmpty || omitted > 0,
            reason: !summaries.isEmpty || !excerpts.isEmpty || omitted > 0 ? "Host-approved derived context." : nil
        ), report: report)
    }

    private static func safeLabel(_ label: String) -> Bool {
        !label.isEmpty && label.utf8.count <= 80 && label.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }
}
