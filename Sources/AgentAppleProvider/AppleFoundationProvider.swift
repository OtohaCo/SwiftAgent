import AgentModels
import Foundation

/// One structured model plan per request. Host tools are never registered with the native session.
public struct AppleFoundationProvider: ModelProvider {
    public static let modelID = ModelID(provider: "apple-foundation", name: "on-device")
    public static let privateCloudComputeModelID = ModelID(provider: "apple-foundation", name: "private-cloud-compute")
    public let descriptor = ModelProviderDescriptor(id: "apple-foundation", capabilities: [.multiTurn, .tools])
    /// The fixed instructions the adapter puts before the host's system and developer messages in every
    /// native session. A host budgeting the model's small context counts them with its own.
    public static let plannerInstructions = """
    You are the planner for an external tool runtime. Produce exactly one plan for the supplied conversation.
    The runtime executes the tool action you propose and sends you its real result in the next request.
    If the user asks to use a tool, choose tool unless its actual result is already in the conversation.
    Request a tool by selecting the tool case with its name and argumentsJSON.
    Choose tool when an operation is needed, using a name from the supplied tool declarations.
    Choose answer when the requested operations already have actual results, or no tool is needed.
    Each argumentsJSON is a valid JSON object string matching that tool's inputSchema.
    Never invent a tool result. Use actual tool messages when answering after a tool call.
    Do not repeat a successful call already present in the conversation unless newer data was requested.
    Choose refusal to decline a request.
    """
    private let acceptedModelID: ModelID
    let generate: @Sendable (ModelRequest) async throws -> AppleGeneratedTurn

    init(generate: @escaping @Sendable (ModelRequest) async throws -> AppleModelPlan) {
        self.init(modelID: Self.modelID, generate: generate)
    }

    init(modelID: ModelID, generate: @escaping @Sendable (ModelRequest) async throws -> AppleModelPlan) {
        self.init(modelID: modelID) { request in
            AppleGeneratedTurn(plan: try await generate(request))
        }
    }

    init(modelID: ModelID, generatedTurn: @escaping @Sendable (ModelRequest) async throws -> AppleGeneratedTurn) {
        acceptedModelID = modelID
        generate = generatedTurn
    }

    public func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            guard request.model == acceptedModelID else {
                throw ModelProviderError(kind: .invalidRequest, message: "Unsupported Apple model identifier.")
            }
            guard request.structuredOutput == nil else {
                throw ModelProviderError(kind: .unsupportedCapability, message: "Structured answer schemas are not supported by this planning adapter.")
            }
            let info = ResponseInfo(id: UUID().uuidString, model: request.model)
            try emit(.responseStarted(info))
            let turn: AppleGeneratedTurn
            do {
                turn = try await generate(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ModelProviderError {
                throw error
            } catch {
                try Task.checkCancellation()
                #if canImport(FoundationModels)
                if #available(macOS 26, iOS 26, *) {
                    turn = AppleGeneratedTurn(plan: try AppleNativeErrors.resolve(error))
                } else {
                    throw ModelProviderError(kind: .unavailable, message: "Apple model generation failed.")
                }
                #else
                throw ModelProviderError(kind: .unavailable, message: "Apple model generation failed.")
                #endif
            }
            let plan = turn.plan
            guard (plan.kind == .tools) == !plan.toolCalls.isEmpty,
                  plan.toolCalls.allSatisfy({ call in
                      request.tools.contains { $0.name.utf8.elementsEqual(call.name.utf8) }
                          && (try? JSONValue.decodeToolArguments(call.argumentsJSON)) != nil
                  }) else {
                throw ModelProviderError(kind: .invalidResponse, message: "The Apple model returned an invalid tool plan.")
            }
            let content: [ModelContent] = plan.text.isEmpty ? [] : [.text(plan.text)]
            if !plan.text.isEmpty { try emit(.textDelta(plan.text)) }
            let calls = plan.toolCalls.map {
                ToolCall(id: .init(rawValue: UUID().uuidString), name: $0.name, argumentsJSON: $0.argumentsJSON, completeness: .complete)
            }
            for call in calls {
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
            }
            let stop: StopReason
            switch plan.kind {
            case .answer: stop = .endTurn
            case .tools: stop = .toolCalls
            case .refusal: stop = .refusal
            }
            if turn.usage != ModelUsage() { try emit(.usage(turn.usage)) }
            try emit(.responseCompleted(.init(info: info, content: content, toolCalls: calls, usage: turn.usage, stopReason: stop)))
        }
    }
}

/// SDK metadata is supplied separately; model-generated JSON cannot declare usage.
struct AppleGeneratedTurn: Sendable {
    let plan: AppleModelPlan
    var usage = ModelUsage()
}

struct AppleModelPlan: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case answer, tools, refusal }
    struct Call: Codable, Sendable { let name: String; let argumentsJSON: String }
    let kind: Kind
    let text: String
    let toolCalls: [Call]
}
