import AgentModels
import Foundation

/// Encodes the conversation the on-device planner sees. System and developer
/// messages are host instructions, not transcript rows.
enum ApplePromptEncoding {
    struct PromptInput: Encodable {
        let messages: [PromptMessage]
        let tools: [PromptTool]
    }

    /// What the model plans with. The output schema is the runtime's to check, so it stays out of the
    /// small on-device context, as other adapters leave it out of their requests.
    struct PromptTool: Encodable {
        let name: String
        let description: String
        let inputSchema: JSONValue

        init(_ definition: ModelToolDefinition) {
            name = definition.name
            description = definition.description
            inputSchema = definition.inputSchema
        }
    }

    struct PromptMessage: Encodable {
        let role: ModelRole
        let content: String
        var toolCalls: [PromptCall] = []
        var callID: String?
        var isError: Bool?

        init(_ message: ModelMessage) throws {
            role = message.role
            let parts: [ModelContent]
            switch message {
            case .system(let text), .developer(let text): parts = [.text(text)]
            case .user(let content): parts = content
            case .assistant(let content, let calls):
                parts = content
                toolCalls = calls.map(PromptCall.init)
            case .tool(let result):
                parts = result.content
                callID = result.callID.rawValue
                isError = result.isError
            }
            content = try parts.compactMap { part -> String? in
                switch part {
                case .text(let text), .reasoning(let text): return text
                case .json(let value): return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
                case .providerContinuation: return nil
                case .image:
                    throw ModelProviderError(kind: .unsupportedCapability,
                                             message: "This adapter cannot send images to the model.")
                }
            }.joined(separator: "\n")
        }
    }

    struct PromptCall: Encodable {
        let id: String
        let name: String
        let argumentsJSON: String
        init(_ call: ToolCall) {
            id = call.id.rawValue
            name = call.name
            argumentsJSON = call.argumentsJSON
        }
    }

    static func encode(_ request: ModelRequest) throws -> Data {
        let messages = try request.messages
            .filter { $0.role != .system && $0.role != .developer }
            .map(PromptMessage.init)
        return try JSONEncoder().encode(PromptInput(messages: messages, tools: request.tools.map(PromptTool.init)))
    }
}
