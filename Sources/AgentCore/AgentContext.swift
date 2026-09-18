import Foundation
import AgentModels

/// Distinguishes a single oversized input from accumulated conversation that
/// must go through the context policy.
public enum AgentContextError: Error, Equatable, Sendable {
    case inputTooLarge(bytes: Int, limit: Int)
    case historyTooLarge(bytes: Int, limit: Int)
}

/// Host-neutral summarizer. Core chooses the retain window; the host decides
/// summary wording. Core never invents host-domain content.
public protocol AgentContextCompactor: Sendable {
    func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary
}

/// Mechanical default. It records that earlier turns were dropped; it does not
/// interpret domain payloads.
public struct AgentRetainedTurnCompactor: AgentContextCompactor {
    public init() {}

    public func summarize(droppedConversation: [ModelMessage]) async throws -> AgentCompactionSummary {
        let droppedTurns = droppedConversation.reduce(into: 0) { count, message in
            if case .user = message { count += 1 }
        }
        return AgentCompactionSummary(
            goal: "Continue the existing conversation.",
            constraints: [],
            decisions: [],
            openWork: droppedTurns == 0 ? [] : ["\(droppedTurns) earlier user turn(s) were compacted."]
        )
    }
}

/// Bounds active Session history. A single input above `maxInputUTF8Bytes`
/// fails immediately. Accumulated history above `maxActiveHistoryUTF8Bytes`
/// is compacted instead of being written as an oversized journal frame.
public struct AgentContextPolicy: Sendable {
    public var maxInputUTF8Bytes: Int
    public var maxActiveHistoryUTF8Bytes: Int
    public var retainedRecentTurnCount: Int
    public var compactor: any AgentContextCompactor

    public static let `default` = AgentContextPolicy(
        maxInputUTF8Bytes: 8 * 1024 * 1024,
        maxActiveHistoryUTF8Bytes: 12 * 1024 * 1024,
        retainedRecentTurnCount: 6,
        compactor: AgentRetainedTurnCompactor()
    )

    public init(
        maxInputUTF8Bytes: Int = AgentContextPolicy.default.maxInputUTF8Bytes,
        maxActiveHistoryUTF8Bytes: Int = AgentContextPolicy.default.maxActiveHistoryUTF8Bytes,
        retainedRecentTurnCount: Int = AgentContextPolicy.default.retainedRecentTurnCount,
        compactor: any AgentContextCompactor = AgentRetainedTurnCompactor()
    ) {
        self.maxInputUTF8Bytes = maxInputUTF8Bytes
        self.maxActiveHistoryUTF8Bytes = maxActiveHistoryUTF8Bytes
        self.retainedRecentTurnCount = retainedRecentTurnCount
        self.compactor = compactor
    }

    func checkInput(_ text: String) throws {
        let bytes = text.utf8.count
        guard bytes <= maxInputUTF8Bytes else {
            throw AgentContextError.inputTooLarge(bytes: bytes, limit: maxInputUTF8Bytes)
        }
    }
}

enum AgentContextWindow {
    struct Split {
        var runtime: [ModelMessage]
        var dropped: [ModelMessage]
        var retained: [ModelMessage]
    }

    static func applyingCurrentInstructions(_ history: [ModelMessage], instructions: String) -> [ModelMessage] {
        let conversation = history.filter { message in
            switch message {
            case .system, .developer: false
            default: true
            }
        }
        var restored: [ModelMessage] = []
        if !instructions.isEmpty {
            restored.append(.system(instructions))
        }
        restored.append(contentsOf: conversation)
        return restored
    }

    static func encodedByteCount(_ messages: [ModelMessage]) throws -> Int {
        try JSONEncoder().encode(messages).count
    }

    static func summaryMessage(_ summary: AgentCompactionSummary) -> ModelMessage {
        var lines = ["Conversation summary:"]
        if !summary.goal.isEmpty { lines.append("Goal: \(summary.goal)") }
        if !summary.constraints.isEmpty {
            lines.append("Constraints: \(summary.constraints.joined(separator: "; "))")
        }
        if !summary.decisions.isEmpty {
            lines.append("Decisions: \(summary.decisions.joined(separator: "; "))")
        }
        if !summary.openWork.isEmpty {
            lines.append("Open work: \(summary.openWork.joined(separator: "; "))")
        }
        return .user([.text(lines.joined(separator: "\n"))])
    }

    static func split(_ history: [ModelMessage], retainingRecentTurns: Int) -> Split {
        var runtime: [ModelMessage] = []
        var conversation: [ModelMessage] = []
        var seenConversation = false
        for message in history {
            switch message {
            case .system, .developer:
                if seenConversation {
                    conversation.append(message)
                } else {
                    runtime.append(message)
                }
            default:
                seenConversation = true
                conversation.append(message)
            }
        }
        let recentFrom = indexRetainingRecentTurns(conversation, count: retainingRecentTurns)
        let unresolvedFrom = indexOfUnresolvedToolSpan(conversation) ?? conversation.count
        let retainFrom = min(recentFrom, unresolvedFrom)
        return Split(
            runtime: runtime,
            dropped: Array(conversation[..<retainFrom]),
            retained: Array(conversation[retainFrom...])
        )
    }

    private static func indexRetainingRecentTurns(_ conversation: [ModelMessage], count: Int) -> Int {
        guard count > 0 else { return conversation.count }
        var seen = 0
        for index in conversation.indices.reversed() {
            if conversation[index].role == .user {
                seen += 1
                if seen == count { return index }
            }
        }
        return 0
    }

    private static func indexOfUnresolvedToolSpan(_ conversation: [ModelMessage]) -> Int? {
        var openFrom: Int?
        var pending = Set<ToolCallID>()
        for (index, message) in conversation.enumerated() {
            switch message {
            case .assistant(_, let calls) where !calls.isEmpty:
                if pending.isEmpty { openFrom = index }
                pending.formUnion(calls.map(\.id))
            case .tool(let result):
                pending.remove(result.callID)
                if pending.isEmpty { openFrom = nil }
            default:
                break
            }
        }
        return openFrom
    }
}
