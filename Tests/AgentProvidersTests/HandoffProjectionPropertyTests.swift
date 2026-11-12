import AgentCore
import AgentModels
import Foundation
import Testing
@testable import AgentProviders

/// Random histories made by several providers, handed to another one through `AgentSemanticHandoffProjector`: every call
/// keeps its result, nothing private of another binding is sent, no empty turn and no tool name a provider refuses goes out,
/// the projection is the same each time and the history it came from is untouched, and each provider's encoder accepts it.
struct HandoffProjectionPropertyTests {
    private static let vendors: [(model: ModelID, origin: ModelProviderContinuationOrigin)] = [
        (ModelID(provider: "anthropic", name: "claude-fixture"), origin("anthropic", dialect: "anthropic.messages")),
        (ModelID(provider: "openai", name: "gpt-fixture"), origin("openai", dialect: "openai.responses")),
        (ModelID(provider: "gemini", name: "gemini-fixture"), origin("gemini", dialect: "gemini.generateContent")),
        (ModelID(provider: "deepseek", name: "deepseek-fixture"), origin("deepseek", dialect: "deepseek.responses")),
    ]
    private static let names = ["lookup", "read_file", "fs/read", "mcp:search", "docs.find", "日本語", "with space",
                                String(repeating: "x", count: 70), "search-web"]

    private static func origin(_ provider: String, dialect: String) -> ModelProviderContinuationOrigin {
        ModelProviderContinuationOrigin(providerID: provider, serviceInstanceID: "\(provider)-service", endpointScope: "default",
            apiDialect: dialect, apiVersion: "1", configurationRevision: "rev-1")
    }

    @Test func randomMultiProviderHistoriesProjectSafely() async throws {
        var random = SplitMix(seed: 0x5EED_1623)
        for round in 0..<400 {
            let canonical = Self.history(&random)
            let target = Self.vendors[random.next(Self.vendors.count)]
            let keeps = random.next(2) == 0
            let projector = AgentSemanticHandoffProjector(keeping: keeps ? target.origin : nil)
            let input = AgentContextProjectionInput(canonicalMessages: canonical, model: target.model, sessionID: UUID(), runID: UUID(),
                conversationRevision: 7, contextEpoch: 3, modelTurn: 1)
            let first = try await projector.project(input)
            let second = try await projector.project(input)
            #expect(first.messages == second.messages, "round \(round): the same projection every time")
            #expect(input.canonicalMessages == canonical, "round \(round): the history is untouched")
            #expect(first.plan.sourceDigest == (try input.sourceDigest()) && first.plan.sourceRevision == 7 && first.plan.contextEpoch == 3)
            #expect(first.plan.lossy == (first.messages != canonical))

            // Every call keeps its result, in order.
            #expect(Self.callIDs(first.messages) == Self.callIDs(canonical), "round \(round): calls")
            #expect(Self.resultIDs(first.messages) == Self.resultIDs(canonical), "round \(round): results")
            let originals = Dictionary(Self.calls(canonical).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for message in first.messages {
                guard case .assistant(let content, let calls) = message else { continue }
                let own = keeps && Self.isOwn(content, model: target.model, origin: target.origin)
                #expect(!content.isEmpty || !calls.isEmpty, "round \(round): an empty turn went out")
                if own {
                    #expect(canonical.contains(message), "round \(round): the model's own turn is sent whole")
                    continue
                }
                #expect(!content.contains { if case .reasoning = $0 { true } else if case .providerContinuation = $0 { true } else { false } },
                        "round \(round): another binding's private state went out")
                for call in calls {
                    let original = try #require(originals[call.id])
                    #expect(ToolCall.isPortableName(call.name), "round \(round): \(call.name)")
                    #expect(call.name == ToolCall.portableName(for: original.name) && call.argumentsJSON == original.argumentsJSON)
                }
            }
            if !keeps { try Self.encode(first.messages, for: target.model) }
        }
    }

    @Test func aPortableNameIsKeptAndAnotherIsStable() {
        #expect(ToolCall.portableName(for: "read_file") == "read_file")
        let stand = ToolCall.portableName(for: "fs/read")
        #expect(stand == ToolCall.portableName(for: "fs/read") && stand != ToolCall.portableName(for: "fs:read"))
        #expect(stand.hasPrefix("tool_") && stand.utf8.count == 37 && ToolCall.isPortableName(stand))
    }

    // MARK: Encoding with the target's encoder

    private static func encode(_ messages: [ModelMessage], for model: ModelID) throws {
        let request = ModelRequest(model: model, messages: messages)
        switch model.provider {
        case "anthropic": _ = try AnthropicRequestEncoder.encode(request, maximumOutputTokens: 1_024, thinking: .disabled)
        case "openai": _ = try OpenAIResponsesRequestEncoder.encode(request, maximumOutputTokens: 1_024, reasoningEffort: nil, reasoningSummary: nil)
        case "gemini":
            let configuration = try GeminiConfiguration(baseURL: GeminiProvider.defaultBaseURL, streaming: false, thinking: nil,
                profile: .requireCurrentTurnFunctionSignatures, maximumOutputTokens: nil, maximumRequestBytes: 100_000_000,
                maximumResponseBytes: 16_000_000, authorizationScopeID: "default", caching: .implicit)
            _ = try GeminiRequestEncoder.encode(request, configuration: configuration)
        default:
            // DeepSeek takes no pictures; the binding turns them into text before a request (`imageInput`).
            let described = messages.map { message -> ModelMessage in
                guard case .tool(let result) = message else { return message }
                return .tool(.init(callID: result.callID, content: result.content.map {
                    if case .image = $0 { .text("[picture]") } else { $0 }
                }, isError: result.isError))
            }
            _ = try DeepSeekResponsesRequestEncoder.encode(ModelRequest(model: model, messages: described), maximumOutputTokens: 1_024,
                reasoningEffort: .high)
        }
    }

    // MARK: Histories

    private static func history(_ random: inout SplitMix) -> [ModelMessage] {
        var messages: [ModelMessage] = [.user([.text("Start")])]
        var next = 0
        for _ in 0..<(1 + random.next(5)) {
            let maker = vendors[random.next(vendors.count)]
            var content: [ModelContent] = []
            if random.next(2) == 0 { content.append(.reasoning("thinking of \(maker.model.provider)")) }
            if random.next(3) == 0 { content.append(.text("Visible answer")) }
            if random.next(2) == 0 {
                let sameOrigin = random.next(2) == 0
                content.append(.providerContinuation(ModelProviderContinuation(model: maker.model, format: "\(maker.model.provider).fixture",
                    payload: Data("private".utf8), origin: sameOrigin ? maker.origin : origin("other", dialect: "other.dialect"))))
            }
            var calls: [ToolCall] = []
            for _ in 0..<random.next(3) {
                next += 1
                calls.append(ToolCall(id: .init(rawValue: "call-\(next)"), name: names[random.next(names.count)],
                    argumentsJSON: #"{"n":\#(next)}"#, completeness: .complete))
            }
            messages.append(.assistant(content: content, toolCalls: calls))
            for call in calls {
                var result: [ModelContent] = [random.next(2) == 0 ? .text("found \(call.id.rawValue)") : .json(.object(["n": .number(1)]))]
                if random.next(4) == 0, let picture = try? ModelImage(data: Self.png, mediaType: .png, description: "a picture") { result.append(.image(picture)) }
                messages.append(.tool(.init(callID: call.id, content: result, isError: random.next(5) == 0)))
            }
            if random.next(2) == 0 { messages.append(.user([.text("Go on")])) }
        }
        if case .assistant = messages.last { messages.append(.user([.text("And then?")])) }
        if case .tool = messages.last { messages.append(.user([.text("And then?")])) }
        return messages
    }

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private static func isOwn(_ content: [ModelContent], model: ModelID, origin: ModelProviderContinuationOrigin) -> Bool {
        let states = content.compactMap { part -> ModelProviderContinuation? in if case .providerContinuation(let state) = part { state } else { nil } }
        return !states.isEmpty && states.allSatisfy { $0.model == model && $0.origin == origin }
    }
    private static func calls(_ messages: [ModelMessage]) -> [ToolCall] {
        messages.flatMap { message -> [ToolCall] in if case .assistant(_, let calls) = message { calls } else { [] } }
    }
    private static func callIDs(_ messages: [ModelMessage]) -> [ToolCallID] { calls(messages).map(\.id) }
    private static func resultIDs(_ messages: [ModelMessage]) -> [ToolCallID] {
        messages.compactMap { message -> ToolCallID? in if case .tool(let result) = message { result.callID } else { nil } }
    }
}

/// A small seeded generator, so a failing history can be made again.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}
