import Foundation

/// Replays one normalized model response. Call finish only after a clean stream EOF.
public struct ModelEventAccumulator: Sendable {
    private var info: ResponseInfo?
    private var content: [ModelContent] = []
    private var usage = ModelUsage()
    private var calls: [ToolCallID: ToolCall] = [:]
    private var callOrder: [ToolCallID] = []
    private var terminal: ModelResponse?
    private var failure: ModelStreamError?

    public init() {}

    public mutating func append(_ event: ModelEvent) throws {
        if let failure { throw failure }
        do { try accept(event) }
        catch let error as ModelStreamError {
            failure = error
            throw error
        }
    }

    private mutating func accept(_ event: ModelEvent) throws {
        guard terminal == nil else { throw ModelStreamError.eventAfterTerminal }
        if case .responseStarted(let started) = event {
            guard info == nil else { throw ModelStreamError.duplicateStart }
            info = started
            return
        }
        guard let info else { throw ModelStreamError.missingStart }
        switch event {
        case .responseStarted: break
        case .textDelta(let text):
            if case .text(let previous) = content.last {
                content[content.count - 1] = .text(previous + text)
            } else {
                content.append(.text(text))
            }
        case .reasoningDelta(let text):
            if case .reasoning(let previous) = content.last {
                content[content.count - 1] = .reasoning(previous + text)
            } else {
                content.append(.reasoning(text))
            }
        case .toolCallStarted(let id, let name):
            guard !id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ModelStreamError.invalidToolIdentity
            }
            guard calls[id] == nil else { throw ModelStreamError.duplicateToolCall(id) }
            calls[id] = ToolCall(id: id, name: name, argumentsJSON: "")
            callOrder.append(id)
        case .toolCallArgumentsDelta(let id, let delta):
            guard let call = calls[id] else { throw ModelStreamError.unknownToolCall(id) }
            guard call.completeness == .incomplete else { throw ModelStreamError.toolAlreadyCompleted(id) }
            calls[id] = ToolCall(id: id, name: call.name, argumentsJSON: call.argumentsJSON + delta)
        case .toolCallCompleted(let call):
            guard let pending = calls[call.id] else { throw ModelStreamError.unknownToolCall(call.id) }
            guard pending.completeness == .incomplete else { throw ModelStreamError.toolAlreadyCompleted(call.id) }
            guard call.completeness == .complete, call.name == pending.name,
                  call.argumentsJSON == pending.argumentsJSON else {
                throw ModelStreamError.toolCallMismatch(call.id)
            }
            guard (try? JSONValue.decodeToolArguments(call.argumentsJSON)) != nil else {
                throw ModelStreamError.invalidToolArguments(call.id)
            }
            calls[call.id] = call
        case .usage(let newer):
            let counts = [newer.inputTokens, newer.outputTokens, newer.cachedInputTokens,
                          newer.cacheWriteInputTokens, newer.reasoningTokens]
            guard counts.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
                throw ModelStreamError.invalidUsage
            }
            usage = ModelUsage(
                inputTokens: newer.inputTokens ?? usage.inputTokens,
                outputTokens: newer.outputTokens ?? usage.outputTokens,
                cachedInputTokens: newer.cachedInputTokens ?? usage.cachedInputTokens,
                cacheWriteInputTokens: newer.cacheWriteInputTokens ?? usage.cacheWriteInputTokens,
                reasoningTokens: newer.reasoningTokens ?? usage.reasoningTokens
            )
        case .responseCompleted(let response):
            guard response.info == info, response.content == content, response.usage == usage,
                  response.toolCalls == callOrder.compactMap({ calls[$0] }) else {
                throw ModelStreamError.responseMismatch
            }
            switch response.stopReason {
            case .toolCalls:
                guard !calls.isEmpty, calls.values.allSatisfy({ $0.completeness == .complete }) else {
                    throw ModelStreamError.invalidToolStop
                }
            case .endTurn, .stopSequence:
                guard calls.isEmpty else { throw ModelStreamError.invalidToolStop }
            case .maxOutputTokens, .refusal, .cancelled, .unknown:
                break
            }
            terminal = response
        }
    }

    public mutating func finish() throws -> ModelResponse {
        if let failure { throw failure }
        guard let terminal else {
            failure = .missingTerminal
            throw ModelStreamError.missingTerminal
        }
        return terminal
    }

}

public enum ModelStreamError: Error, Equatable, Sendable {
    case missingTerminal
    case missingStart
    case duplicateStart
    case eventAfterTerminal
    case responseMismatch
    case invalidUsage
    case unknownToolCall(ToolCallID)
    case duplicateToolCall(ToolCallID)
    case toolAlreadyCompleted(ToolCallID)
    case toolCallMismatch(ToolCallID)
    case invalidToolArguments(ToolCallID)
    case invalidToolIdentity
    case invalidToolStop
}
