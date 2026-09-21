import AgentCore
import AgentModels
import AgentProviders
import AgentTools
import Foundation

public enum FixtureConversationRoute: String, CaseIterable, Equatable, Sendable {
    case direct
    case validated
}

public enum FixtureConversationPacing: Equatable, Sendable {
    case immediate
    case visible

    var delay: Duration? {
        switch self {
        case .immediate: nil
        case .visible: .milliseconds(90)
        }
    }
}

public struct FixtureConversationConfiguration: Sendable {
    public let model: ModelID
    public let provider: any ModelProvider
    public let mode: FixtureConversationRoute
    let tools: [any AgentTool]
}

public func makeFixtureConversationConfiguration(
    route: FixtureConversationRoute = .direct,
    pacing: FixtureConversationPacing = .visible
) throws -> FixtureConversationConfiguration {
    let model = ModelID(provider: StreamingFixtureProvider.providerID, name: "account-assistant")
    let direct = StreamingFixtureProvider(pacing: pacing)
    let provider: any ModelProvider
    switch route {
    case .direct:
        provider = direct
    case .validated:
        provider = try ModelProviderRoute(
            id: StreamingFixtureProvider.providerID,
            candidates: [direct],
            policy: .init(maxAttempts: 1)
        )
    }
    return FixtureConversationConfiguration(
        model: model,
        provider: provider,
        mode: route,
        tools: [try AccountLookupTool()]
    )
}

public func makeFixtureConversationController(
    conversationID: UUID = UUID(),
    sessionID: UUID? = nil,
    route: FixtureConversationRoute = .direct,
    pacing: FixtureConversationPacing = .visible,
    maxDisplayItems: Int = 100
) throws -> ConversationController {
    let fixture = try makeFixtureConversationConfiguration(route: route, pacing: pacing)
    let agent = try Agent(
        model: fixture.model,
        provider: fixture.provider,
        tools: fixture.tools,
        configuration: .init(
            instructions: "Use lookup_account when the user asks about an account. Report the observed result only.",
            maxModelTurns: 4,
            maxToolCalls: 2,
            runTimeout: .seconds(15)
        )
    )
    let session = try agent.makeSession(id: sessionID ?? conversationID)
    return ConversationController(
        conversationID: conversationID,
        session: AgentConversationSessionHandle(session: session),
        maxDisplayItems: maxDisplayItems
    )
}

private struct StreamingFixtureProvider: ModelProvider {
    static let providerID = "apple-chat-fixture"

    let descriptor = ModelProviderDescriptor(
        id: providerID,
        capabilities: [.streaming, .multiTurn, .tools]
    )
    let pacing: FixtureConversationPacing

    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let responseID = "fixture-\(request.runID?.uuidString ?? UUID().uuidString)-\(request.messages.count)"
            let info = ResponseInfo(id: responseID, model: request.model)
            try emit(.responseStarted(info))

            if case .tool(let result)? = request.messages.last {
                if request.messages.contains(where: { message in
                    guard case .user(let content) = message else { return false }
                    return content.contains { content in
                        guard case .text(let text) = content else { return false }
                        return text.localizedCaseInsensitiveContains("fail-after-tool")
                    }
                }) {
                    try emit(.textDelta("The tool completed, but the final reply failed."))
                    throw ModelProviderError(kind: .invalidResponse, message: "Fixture protocol failure after tool.")
                }
                let text: String
                if result.isError {
                    text = "I could not find that account. Try another account ID."
                } else {
                    let values = result.content.compactMap { content -> [String: JSONValue]? in
                        guard case .json(.object(let object)) = content else { return nil }
                        return object
                    }.first
                    let account = values?["id"]?.stringValue ?? "the account"
                    let status = values?["status"]?.stringValue ?? "unknown"
                    text = "Account \(account) is \(status)."
                }
                try await emitText(text, info: info, stopReason: .endTurn, emit: emit)
                return
            }

            let prompt = request.messages.reversed().compactMap { message -> String? in
                guard case .user(let content) = message else { return nil }
                return content.compactMap { part -> String? in
                    guard case .text(let text) = part else { return nil }
                    return text
                }.joined()
            }.first ?? ""

            switch prompt.lowercased() {
            case "/refuse":
                try await emitText(
                    "I cannot help with that request.",
                    info: info,
                    stopReason: .refusal,
                    emit: emit
                )
            case "/incomplete":
                try await emitText(
                    "This response is incomplete",
                    info: info,
                    stopReason: .maxOutputTokens,
                    emit: emit
                )
            case "/fail":
                try emit(.textDelta("This draft will not be committed."))
                try await pauseIfNeeded()
                throw ModelProviderError(kind: .invalidResponse, message: "Fixture protocol failure.")
            default:
                if prompt.localizedCaseInsensitiveContains("account") {
                    let accountID = prompt.localizedCaseInsensitiveContains("missing") ? "missing" : "A-100"
                    let call = ToolCall(
                        id: .init(rawValue: "lookup-\(request.runID?.uuidString ?? UUID().uuidString)"),
                        name: AccountLookupTool.name,
                        argumentsJSON: #"{"id":"\#(accountID)"}"#,
                        completeness: .complete
                    )
                    try emit(.toolCallStarted(call.id, name: call.name))
                    try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                    try emit(.toolCallCompleted(call))
                    let usage = ModelUsage(inputTokens: 12, outputTokens: 5)
                    try emit(.usage(usage))
                    try emit(.responseCompleted(.init(
                        info: info,
                        toolCalls: [call],
                        usage: usage,
                        stopReason: .toolCalls
                    )))
                    return
                }
                try await emitText(
                    "Fixture reply: \(prompt)",
                    info: info,
                    stopReason: .endTurn,
                    emit: emit
                )
            }
        }
    }

    private func emitText(
        _ text: String,
        info: ResponseInfo,
        stopReason: StopReason,
        emit: @escaping ModelEventStream.Emit
    ) async throws {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        for (index, word) in words.enumerated() {
            let separator = index == words.count - 1 ? "" : " "
            try emit(.textDelta(String(word) + separator))
            try await pauseIfNeeded()
        }
        try emit(.usage(.init(inputTokens: 10, outputTokens: words.count)))
        try emit(.responseCompleted(.init(
            info: info,
            content: [.text(text)],
            usage: .init(inputTokens: 10, outputTokens: words.count),
            stopReason: stopReason
        )))
    }

    private func pauseIfNeeded() async throws {
        if let delay = pacing.delay {
            try await Task.sleep(for: delay)
        }
    }
}

struct AccountLookupTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let id: String; let status: String }

    static let name = "lookup_account"
    static let description = "Look up the current status of an account."
    static let inputSchema = ToolSchema.object(
        properties: ["id": .string],
        required: ["id"]
    )
    static let outputSchema = ToolSchema.object(
        properties: ["id": .string, "status": .string],
        required: ["id", "status"]
    )
    let policy: ToolPolicy

    init() throws {
        policy = try .readOnly(
            authorization: .notRequired,
            recoverableErrors: .modelVisible
        )
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        if input.id == "missing" {
            throw try RecoverableToolError(
                code: "not_found",
                message: "No matching account was found.",
                details: .object(["id": .string(input.id)])
            )
        }
        return ToolResult(output: .init(id: input.id, status: "active"))
    }
}

private extension JSONValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}
