import AgentCatalog
import AgentCore
import AgentDecisions
import AgentJevProvider
import AgentModels
import AgentTools
import AgentUsage
import Foundation
import Testing

/// Deferred tools through the published API only: a binding offers the model its declared tools, a
/// "find tools" result declares a deferred one for the next request, and an undeclared call fails as
/// an unknown tool does.
struct DeferredToolPublicAPITests {
    @Test func aFoundToolIsDeclaredForTheNextRequestOfTheRun() async throws {
        let provider = DeferredProvider(calls: [
            ToolCall(id: .init(rawValue: "find"), name: "find_tools", argumentsJSON: #"{"text":"read a page"}"#, completeness: .complete),
            ToolCall(id: .init(rawValue: "fetch"), name: "web_fetch", argumentsJSON: #"{"text":"example.com"}"#, completeness: .complete),
        ])
        let session = try Agent(model: deferredModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "project", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
                AgentCapabilityTool(id: "find_tools", version: "1", tool: try DeferredEchoTool(name: "find_tools", declares: ["web_fetch"])),
                AgentCapabilityTool(id: "web_fetch", version: "1", tool: try DeferredEchoTool(name: "web_fetch"), exposure: .deferred),
            ])
        #expect(binding.info.tools.map(\.exposure) == [.declared, .deferred])

        let result = try await session.run("Read example.com", capabilities: binding).wait()

        #expect(result.outcome == .completed)
        #expect(await provider.offered() == [["find_tools"], ["find_tools", "web_fetch"], ["find_tools", "web_fetch"]])
    }

    @Test func anUndeclaredCallFailsAsAnUnknownTool() async throws {
        let provider = DeferredProvider(calls: [
            ToolCall(id: .init(rawValue: "fetch"), name: "web_fetch", argumentsJSON: #"{"text":"example.com"}"#, completeness: .complete),
        ])
        let session = try Agent(model: deferredModel, provider: provider).makeSession()
        let binding = try await session.bindCapabilities(identity: "project", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
                AgentCapabilityTool(id: "web_fetch", version: "1", tool: try DeferredEchoTool(name: "web_fetch"), exposure: .deferred),
            ])
        let run = try await session.run("Read example.com", capabilities: binding)
        await #expect(throws: ToolRegistryError.unknownTool("web_fetch")) { _ = try await run.wait() }
        #expect(await provider.offered() == [[]])
    }
}

private let deferredModel = ModelID(provider: "deferred-fixture", name: "test")

/// Proposes its calls one per turn, then answers.
private actor DeferredProvider: ModelProvider {
    nonisolated let descriptor = ModelProviderDescriptor(id: "deferred-fixture", capabilities: [.multiTurn, .tools])
    private let calls: [ToolCall]
    private var requests: [ModelRequest] = []

    init(calls: [ToolCall]) { self.calls = calls }

    func offered() -> [[String]] { requests.map { $0.tools.map(\.name) } }

    private func next(_ request: ModelRequest) -> ToolCall? {
        requests.append(request)
        return requests.count <= calls.count ? calls[requests.count - 1] : nil
    }

    nonisolated func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "response", model: request.model)
            try emit(.responseStarted(info))
            if let call = await self.next(request) {
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("done"))
                try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
            }
        }
    }
}

private struct DeferredEchoTool: RuntimeAgentTool {
    let runtimeDefinition: ModelToolDefinition
    let policy: ToolPolicy
    let declares: [String]

    init(name: String, declares: [String] = []) throws {
        runtimeDefinition = ModelToolDefinition(
            name: name, description: "Echo",
            inputSchema: ToolSchema.object(properties: ["text": .string], required: ["text"]).json,
            outputSchema: ToolSchema.object(properties: ["echo": .string], required: ["echo"]).json)
        policy = try .readOnly(authorization: .notRequired)
        self.declares = declares
    }

    func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolResult<JSONValue> {
        guard case .object(let fields) = input, let text = fields["text"] else { throw ToolInvocationError.invalidArguments }
        return ToolResult(output: .object(["echo": text]), declaredTools: declares)
    }
}
