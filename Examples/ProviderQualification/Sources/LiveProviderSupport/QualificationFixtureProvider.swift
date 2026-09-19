import AgentModels
import Foundation

struct QualificationFixtureProvider: ModelProvider {
    let providerID: String

    var descriptor: ModelProviderDescriptor {
        .init(id: providerID, capabilities: [.streaming, .multiTurn, .tools, .structuredOutput, .reasoning])
    }

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(
                id: "fixture-\(request.runID?.uuidString ?? UUID().uuidString)",
                model: request.model
            )
            try emit(.responseStarted(info))

            if lastUserText(request).contains("Hold this response until cancellation") {
                try await Task.sleep(for: .seconds(120))
                try Task.checkCancellation()
            }

            if let tool = request.messages.last.flatMap({ message -> ToolResultMessage? in
                guard case .tool(let result) = message else { return nil }
                return result
            }) {
                let text = tool.isError ? "The local tool reported an error." : "The verified sum is 5."
                try complete(text: text, info: info, input: 18, output: 6, emit: emit)
                return
            }

            if request.structuredOutput != nil {
                try complete(text: #"{"answer":"SwiftAgent"}"#, info: info, input: 14, output: 5, emit: emit)
                return
            }

            let prompt = lastUserText(request)
            if !request.tools.isEmpty,
               prompt.contains("Use add_numbers") || prompt.contains("lookup_account") {
                let toolName = request.tools.contains(where: { $0.name == "lookup_account" })
                    ? "lookup_account"
                    : "add_numbers"
                let arguments = toolName == "lookup_account"
                    ? #"{"id":"A-100"}"#
                    : #"{"lhs":2,"rhs":3}"#
                let call = ToolCall(
                    id: .init(rawValue: "fixture-call-\(request.runID?.uuidString ?? UUID().uuidString)"),
                    name: toolName,
                    argumentsJSON: arguments,
                    completeness: .complete
                )
                try emit(.reasoningDelta("Use the registered local tool."))
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                let usage = ModelUsage(inputTokens: 16, outputTokens: 8, reasoningTokens: 4)
                try emit(.usage(usage))
                try emit(.responseCompleted(.init(
                    info: info,
                    content: [.reasoning("Use the registered local tool.")],
                    toolCalls: [call],
                    usage: usage,
                    stopReason: .toolCalls
                )))
                return
            }

            let priorAssistantCount = request.messages.reduce(into: 0) { count, message in
                if case .assistant = message { count += 1 }
            }
            let text: String
            if prompt.contains("RESTART-TOOL-17") {
                text = "RESTART-TOOL-17 5"
            } else if prompt.contains("BLUE-17") || priorAssistantCount > 0 {
                text = "BLUE-17"
            } else {
                text = "SwiftAgent fixture response."
            }
            try complete(text: text, info: info, input: 10 + priorAssistantCount, output: 4, emit: emit)
        }
    }

    private func lastUserText(_ request: ModelRequest) -> String {
        request.messages.reversed().compactMap { message -> String? in
            guard case .user(let content) = message else { return nil }
            return content.compactMap { part -> String? in
                guard case .text(let text) = part else { return nil }
                return text
            }.joined(separator: "\n")
        }.first ?? ""
    }

    private func complete(
        text: String,
        info: ResponseInfo,
        input: Int,
        output: Int,
        emit: @escaping ModelEventStream.Emit
    ) throws {
        let usage = ModelUsage(inputTokens: input, outputTokens: output)
        try emit(.textDelta(text))
        try emit(.usage(usage))
        try emit(.responseCompleted(.init(
            info: info,
            content: [.text(text)],
            usage: usage,
            stopReason: .endTurn
        )))
    }
}
