import AgentCore
import AgentModels
import AgentTools
import Foundation

// These DTOs define schema 1 on disk. The public model and tool types are
// converted explicitly; their synthesized Codable layouts are not the format.
struct DiskMessageV1: Codable {
    let id: UUID
    let role: String
    let instructions: String?
    let content: [DiskContentV1]
    let calls: [DiskCallV1]
    let result: DiskResultV1?

    init(_ message: JournalMessage) {
        id = message.id
        switch message.value {
        case .system(let text):
            role = "system"; instructions = text; content = []; calls = []; result = nil
        case .developer(let text):
            role = "developer"; instructions = text; content = []; calls = []; result = nil
        case .user(let parts):
            role = "user"; instructions = nil; content = parts.map(DiskContentV1.init); calls = []; result = nil
        case .assistant(let parts, let toolCalls):
            role = "assistant"; instructions = nil; content = parts.map(DiskContentV1.init)
            calls = toolCalls.map(DiskCallV1.init); result = nil
        case .tool(let toolResult):
            role = "tool"; instructions = nil; content = []; calls = []
            result = DiskResultV1(toolResult)
        }
    }

    func value() throws -> JournalMessage {
        let message: ModelMessage
        switch role {
        case "system":
            guard let instructions, content.isEmpty, calls.isEmpty, result == nil else { throw AgentJournalError.invalidRecord }
            message = .system(instructions)
        case "developer":
            guard let instructions, content.isEmpty, calls.isEmpty, result == nil else { throw AgentJournalError.invalidRecord }
            message = .developer(instructions)
        case "user":
            guard instructions == nil, calls.isEmpty, result == nil else { throw AgentJournalError.invalidRecord }
            message = .user(try content.map { try $0.value() })
        case "assistant":
            guard instructions == nil, result == nil else { throw AgentJournalError.invalidRecord }
            message = .assistant(content: try content.map { try $0.value() }, toolCalls: try calls.map { try $0.value() })
        case "tool":
            guard instructions == nil, content.isEmpty, calls.isEmpty, let result else { throw AgentJournalError.invalidRecord }
            message = .tool(try result.value())
        default: throw AgentJournalError.unsupportedFormat
        }
        return JournalMessage(id: id, value: message)
    }
}

struct DiskContentV1: Codable {
    let kind: String
    let text: String?
    let json: JSONValue?
    let continuation: DiskContinuationV1?

    init(_ content: ModelContent) {
        switch content {
        case .text(let value): kind = "text"; text = value; json = nil; continuation = nil
        case .reasoning(let value): kind = "reasoning"; text = value; json = nil; continuation = nil
        case .json(let value): kind = "json"; text = nil; json = value; continuation = nil
        case .providerContinuation(let value): kind = "continuation"; text = nil; json = nil
            continuation = DiskContinuationV1(value)
        }
    }

    func value() throws -> ModelContent {
        switch kind {
        case "text" where json == nil && continuation == nil:
            guard let text else { break }; return .text(text)
        case "reasoning" where json == nil && continuation == nil:
            guard let text else { break }; return .reasoning(text)
        case "json" where text == nil && continuation == nil:
            guard let json else { break }; return .json(json)
        case "continuation" where text == nil && json == nil:
            guard let continuation else { break }; return .providerContinuation(continuation.value())
        default: break
        }
        throw AgentJournalError.invalidRecord
    }
}

struct DiskContinuationV1: Codable {
    let modelProvider: String
    let modelName: String
    let format: String
    let payload: Data
    let origin: DiskOriginV1?
    init(_ value: ModelProviderContinuation) {
        modelProvider = value.model.provider; modelName = value.model.name
        format = value.format; payload = value.payload
        origin = value.origin.map(DiskOriginV1.init)
    }
    func value() -> ModelProviderContinuation {
        ModelProviderContinuation(model: .init(provider: modelProvider, name: modelName),
                                  format: format, payload: payload, origin: origin?.value())
    }
}

struct DiskOriginV1: Codable {
    let provider: String
    let instance: String
    let endpoint: String
    let dialect: String
    let version: String?
    let revision: String
    init(_ value: ModelProviderContinuationOrigin) {
        provider = value.providerID; instance = value.serviceInstanceID
        endpoint = value.endpointScope; dialect = value.apiDialect
        version = value.apiVersion; revision = value.configurationRevision
    }
    func value() -> ModelProviderContinuationOrigin {
        .init(providerID: provider, serviceInstanceID: instance, endpointScope: endpoint,
              apiDialect: dialect, apiVersion: version, configurationRevision: revision)
    }
}

struct DiskCallV1: Codable {
    let id: String
    let name: String
    let arguments: String
    let completeness: String
    init(_ call: ToolCall) {
        id = call.id.rawValue; name = call.name; arguments = call.argumentsJSON
        completeness = call.completeness == .complete ? "complete" : "incomplete"
    }
    func value() throws -> ToolCall {
        guard completeness == "complete" || completeness == "incomplete" else { throw AgentJournalError.invalidRecord }
        return .init(id: .init(rawValue: id), name: name, argumentsJSON: arguments,
                     completeness: completeness == "complete" ? .complete : .incomplete)
    }
}

struct DiskResultV1: Codable {
    let callID: String
    let content: [DiskContentV1]
    let isError: Bool
    init(_ result: ToolResultMessage) {
        callID = result.callID.rawValue; content = result.content.map(DiskContentV1.init)
        isError = result.isError
    }
    func value() throws -> ToolResultMessage {
        .init(callID: .init(rawValue: callID), content: try content.map { try $0.value() }, isError: isError)
    }
}

struct DiskTargetV1: Codable {
    let namespace: String
    let id: String
    init(_ value: EvidenceReference) { namespace = value.namespace; id = value.id }
    func value() -> EvidenceReference { .init(namespace: namespace, id: id) }
}

struct DiskResourceV1: Codable {
    let kind: String
    let target: DiskTargetV1?
    init(_ value: ToolResource) {
        switch value {
        case .global: kind = "global"; target = nil
        case .named(let reference): kind = "named"; target = DiskTargetV1(reference)
        }
    }
    func value() throws -> ToolResource {
        switch kind {
        case "global" where target == nil: return .global
        case "named": guard let target else { break }; return .named(target.value())
        default: break
        }
        throw AgentJournalError.invalidRecord
    }
}

struct DiskExpectationV1: Codable {
    let targets: [DiskTargetV1]
    let revisionKind: String
    let revisionValue: String?
    init(_ value: ToolReceiptExpectation) {
        targets = value.targets.map(DiskTargetV1.init)
        switch value.revision {
        case .optional: revisionKind = "optional"; revisionValue = nil
        case .present: revisionKind = "present"; revisionValue = nil
        case .exact(let text): revisionKind = "exact"; revisionValue = text
        case .changed(let text): revisionKind = "changed"; revisionValue = text
        }
    }
    func value() throws -> ToolReceiptExpectation {
        let revision: ToolReceiptExpectation.Revision
        switch revisionKind {
        case "optional" where revisionValue == nil: revision = .optional
        case "present" where revisionValue == nil: revision = .present
        case "exact": guard let revisionValue else { throw AgentJournalError.invalidRecord }; revision = .exact(revisionValue)
        case "changed": guard let revisionValue else { throw AgentJournalError.invalidRecord }; revision = .changed(from: revisionValue)
        default: throw AgentJournalError.unsupportedFormat
        }
        return try ToolReceiptExpectation(targets: targets.map { $0.value() }, revision: revision)
    }
}

struct DiskIntentV1: Codable {
    let call: DiskCallV1
    let resources: [DiskResourceV1]
    let identity: String
    let expectation: DiskExpectationV1
    init(_ value: PendingMutationIntent) throws {
        guard let receipt = value.receiptExpectation else { throw AgentJournalError.invalidMutationIntent }
        call = DiskCallV1(value.call); resources = value.resources.map(DiskResourceV1.init)
        identity = value.idempotencyKey; expectation = DiskExpectationV1(receipt)
    }
    func value() throws -> PendingMutationIntent {
        try PendingMutationIntent(call: call.value(), resources: resources.map { try $0.value() },
                                  idempotencyKey: identity, receiptExpectation: expectation.value())
    }
}

struct DiskReceiptV1: Codable {
    let operationID: String
    let status: String
    let targets: [DiskTargetV1]
    let revision: String?
    let failure: String?
    init(_ value: ToolReceipt) {
        operationID = value.operationID; status = value.status.rawValue
        targets = value.confirmedTargets.map(DiskTargetV1.init)
        revision = value.revision; failure = value.failure?.rawValue
    }
    func value() throws -> ToolReceipt {
        guard let status = ToolReceipt.Status(rawValue: status),
              failure == nil || ToolReceipt.Failure(rawValue: failure!) != nil else { throw AgentJournalError.invalidRecord }
        return ToolReceipt(operationID: operationID, status: status,
                           confirmedTargets: targets.map { $0.value() }, revision: revision,
                           failure: failure.flatMap(ToolReceipt.Failure.init(rawValue:)))
    }
}

struct DiskMutationV1: Codable {
    let sessionID: UUID
    let runID: UUID
    let intent: DiskIntentV1
    let sequence: UInt64
    let state: String
    let receipt: DiskReceiptV1?
    let output: JSONValue?
    let noEffectBasis: String?
    init(_ value: JournalStoredMutation) throws {
        sessionID = value.sessionID; runID = value.runID
        intent = try DiskIntentV1(value.intent); sequence = value.sequence
        state = value.state.rawValue; receipt = value.receipt.map(DiskReceiptV1.init)
        output = value.output; noEffectBasis = value.abortConfirmation?.basis
    }
    func value() throws -> JournalStoredMutation {
        guard let state = AgentMutationState(rawValue: state) else { throw AgentJournalError.invalidRecord }
        let restoredIntent = try intent.value()
        let restoredReceipt = try receipt?.value()
        switch state {
        case .intent, .needsReconciliation:
            guard restoredReceipt == nil, output == nil, noEffectBasis == nil else {
                throw AgentJournalError.invalidRecord
            }
        case .settled:
            guard let restoredReceipt, output != nil, noEffectBasis == nil,
                  let expectation = restoredIntent.receiptExpectation else { throw AgentJournalError.invalidRecord }
            try ToolReceiptValidator.validate(restoredReceipt,
                                              operationID: restoredIntent.idempotencyKey,
                                              expectation: expectation)
        case .aborted:
            guard restoredReceipt == nil, output == nil, noEffectBasis != nil else {
                throw AgentJournalError.invalidRecord
            }
        }
        return try JournalStoredMutation(sessionID: sessionID, runID: runID, intent: restoredIntent,
                                         sequence: sequence, state: state, receipt: restoredReceipt,
                                         output: output,
                                         abortConfirmation: noEffectBasis.map { try AgentNoEffectConfirmation(basis: $0) })
    }
}

struct DiskHeaderV1: Codable {
    let revision: UInt64
    let created: Bool
    let lastRunID: UUID?
    let steeringIDs: [UUID]
    let historyHead: UInt64?
    let messageCount: UInt64
    let pendingIdentity: String?
    init(_ value: JournalSessionHeader) {
        revision = value.revision; created = value.created; lastRunID = value.lastRunID
        steeringIDs = value.steeringIDs; historyHead = value.historyHead
        messageCount = value.messageCount; pendingIdentity = value.pendingIdentity
    }
    func value() -> JournalSessionHeader {
        .init(revision: revision, created: created, lastRunID: lastRunID,
              steeringIDs: steeringIDs, historyHead: historyHead,
              messageCount: messageCount, pendingIdentity: pendingIdentity)
    }
}
