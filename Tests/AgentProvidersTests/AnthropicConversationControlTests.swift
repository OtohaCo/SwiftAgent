import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import AgentProviders
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicConversationControlTests {
    let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    let model = ModelID(provider: "anthropic", name: "fixture")
    let baseline = ModelToolDefinition(name: "baseline", description: "Known client tool", inputSchema: .object(["type": .string("object")]))
    let added = ModelToolDefinition(name: "new_tool", description: "New trusted tool", inputSchema: .object(["type": .string("object")]))
    func provider(_ probe: ProviderRequestProbe, bodies: [Data]) throws -> AnthropicProvider {
        try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(endpoint: endpoint,
            resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: bodies, chunkBytes: 7))
    }
    func digest(_ message: ModelMessage) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ModelImageDigest.sha256Hex(try encoder.encode(message))
    }
    @Test(arguments: [false, true])
    func reminderWaitsForParallelResultGroupAndRealSteering(_ steering: Bool) async throws {
        let probe = ProviderRequestProbe(), gate = ReminderToolGate()
        let frames = [
            #"{"type":"message_start","message":{"id":"parallel","type":"message","role":"assistant","model":"fixture","content":[],"usage":{"input_tokens":5,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"parallel-1","name":"calculator","input":{"a":2,"b":3}}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"parallel-2","name":"calculator","input":{"a":4,"b":5}}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}"#,
            #"{"type":"message_stop"}"#,
        ]
        let provider = try provider(probe, bodies: [providerSSE(frames), anthropicTextFixture])
        let binding = try AgentModelBinding(profileID: "parallel-reminder", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        let session = try Agent(binding: binding, tools: [ReminderParallelTool(gate: gate)]).makeSession()
        let run = try await session.run("real user", contextControls: .init(reminder: "本轮请用中文回答"))
        await gate.waitForBoth()
        #expect(await probe.requests.count == 1)
        if steering { _ = try await run.steer("real correction") }
        await gate.release()
        #expect(try await run.wait().outcome == .completed); try await run.waitForDrain()
        #expect(await gate.executions == 2)
        let requests = await probe.requests
        #expect(requests.count == 2)
        let body = try JSONDecoder().decode(JSONValue.self, from: requests[1].httpBody!)
        guard case .array(let messages) = body["messages"] else { Issue.record("missing messages"); return }
        let reminders = messages.indices.filter { messages[$0]["clear_at"] == .string("next_user_message") }
        // One reminder for the initial real user and one after the complete result group.
        // Adjacent steering user content joins that wire user turn before its reminder.
        #expect(reminders.count == 2)
        let groups = messages.indices.filter { index in
            guard case .array(let content) = messages[index]["content"] else { return false }
            return content.contains { $0["type"] == .string("tool_result") }
        }
        #expect(groups.count == 1)
        let groupIndex = try #require(groups.first)
        guard case .array(let results) = messages[groupIndex]["content"] else { return }
        #expect(results.filter { $0["type"] == .string("tool_result") }.count == 2)
        #expect(reminders.contains(groupIndex + 1))
        if steering {
            #expect(messages.contains { message in
                guard message["role"] == .string("user"), case .array(let content) = message["content"] else { return false }
                return content.contains { $0["type"] == .string("text") && $0["text"] == .string("real correction") }
            })
            #expect(await session.history.contains(.user([.text("real correction")])))
        }
        #expect(await session.history.filter { $0.role == .tool }.count == 2)
    }

    @Test func retryWithoutNewUserReusesExactlyOneBoundaryReminder() async throws {
        let probe = ProviderRequestProbe()
        let adapter = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(endpoint: endpoint,
            resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), runReminders: true),
            transport: ReminderRetryTransport(probe: probe))
        let user = ModelMessage.user([.text("real user")])
        let reminder = try ModelConversationControlEntry(canonicalMessageCount: 1, boundaryDigest: digest(user), control: .reminder("本轮请用中文回答"))
        let controls = ModelConversationControlView(toolBaseline: [], activeTools: [],
            controls: [.init(entry: reminder, afterMessageIndex: 0)], coveredTools: [], coveredToolChanges: false)
        // Adapter-level replay of the frozen view, with distinct attempts. Core/Route
        // deliberately does not automatically retry provenance-qualified operations.
        for attempt in 0..<2 {
            let request = ModelRequest(model: model, messages: [user], invocationID: UUID(), conversationControls: controls)
            do {
                for try await _ in adapter.stream(request: request) {}
                #expect(attempt == 1)
            } catch let error as ModelProviderError { #expect(attempt == 0 && error.kind == .unavailable) }
        }
        let requests = await probe.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpBody == requests[1].httpBody)
        for request in requests {
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
            guard case .array(let messages) = body["messages"] else { Issue.record("missing messages"); return }
            #expect(messages.filter { $0["clear_at"] == .string("next_user_message") }.count == 1)
        }
    }

    @Test(arguments: [false, true])
    func thresholdPauseCannotIntroduceReminderWithoutNewUser(_ pause: Bool) async throws {
        let probe = ProviderRequestProbe()
        do {
            _ = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(endpoint: endpoint,
                resolvedModelNames: ["fixture"], modes: [.anthropicThreshold]),
                automatic: .init(mode: .anthropicThreshold, triggerInputTokens: 50_000, pauseAfterCompaction: pause), runReminders: true),
                transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture]))
            Issue.record("threshold plus required reminder accepted")
        } catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func typedToolAdditionAndReminderEncodeAsSeparateSystemMessages() async throws {
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [anthropicTextFixture])
        let user = ModelMessage.user([.text("real user")])
        let entries = try [ModelConversationControlEntry(canonicalMessageCount: 1, boundaryDigest: digest(user), control: .toolAddition(added)),
            ModelConversationControlEntry(canonicalMessageCount: 1, boundaryDigest: digest(user), control: .reminder("本轮请用中文回答"))]
        let request = ModelRequest(model: model, messages: [.system("fixed root"), user], tools: [baseline],
            conversationControls: .init(toolBaseline: [baseline], activeTools: [baseline, added],
                controls: entries.map { .init(entry: $0, afterMessageIndex: 1) }, coveredTools: [baseline], coveredToolChanges: false))
        for try await _ in provider.stream(request: request) {}
        let sent = try #require(await probe.requests.first), body = try JSONDecoder().decode(JSONValue.self, from: sent.httpBody!)
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == "inline-tools-2026-09-15,mid-conversation-system-clear-at-2026-08-21")
        #expect(body["system"] == .string("fixed root"))
        guard case .array(let messages) = body["messages"] else { Issue.record("missing wire messages"); return }
        #expect(messages.count == 3)
        guard messages.count == 3 else { return }
        #expect(messages[1]["role"] == .string("system"))
        #expect(messages[1]["content"] == .array([.object(["type": .string("tool_addition"), "tool": .object([
            "type": .string("tool_definition"), "definition": .object(["name": .string("new_tool"), "description": .string("New trusted tool"),
                "input_schema": .object(["type": .string("object")])])])])]))
        #expect(messages[2]["clear_at"] == .string("next_user_message"))
        #expect(messages[2]["content"] == .array([.object(["type": .string("text"), "text": .string("本轮请用中文回答")])]))
    }

    @Test(arguments: [false, true]) func byValueToolWithoutBaselineAnchorOnlyRejectsSignedThinking(_ signed: Bool) async throws {
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [signed ? anthropicThinkingToolFixture : anthropicToolFixture, anthropicTextFixture]))
        let user = ModelMessage.user([.text("Compute")])
        let initial = ModelRequest(model: model, messages: [user], tools: [baseline], conversationControls:
            .init(toolBaseline: [baseline], activeTools: [], controls: [], coveredTools: [], coveredToolChanges: false, deferredBaselineToolNames: [baseline.name]))
        var response: ModelResponse?
        for try await event in provider.stream(request: initial) { if case .responseCompleted(let value) = event { response = value } }
        let answer = try #require(response), call = try #require(answer.toolCalls.first)
        let result = ModelMessage.tool(.init(callID: call.id, content: [.text("5")], isError: false))
        let entry = try ModelConversationControlEntry(canonicalMessageCount: 3, boundaryDigest: digest(result), control: .toolAddition(added))
        let next = ModelRequest(model: model, messages: [user, .assistant(content: answer.content, toolCalls: answer.toolCalls), result], tools: [baseline], conversationControls:
            .init(toolBaseline: [baseline], activeTools: [added], controls: [.init(entry: entry, afterMessageIndex: 2)], coveredTools: [], coveredToolChanges: false, deferredBaselineToolNames: [baseline.name]))
        do {
            for try await _ in provider.stream(request: next) {}
            #expect(!signed)
        } catch let error as ModelProviderError {
            #expect(signed)
            #expect(error.kind == .unsupportedCapability)
            #expect(error.message.contains("non-deferred baseline anchor"))
        }
        #expect(await probe.requests.count == (signed ? 1 : 2))
    }

    @Test(arguments: ["single", "combined", "remove", "replace", "repeat"])
    func availableInlineBytesAreBoundedByCurrentDefinitions(_ scenario: String) async throws {
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [anthropicTextFixture])
        let first = ModelMessage.user([.text("first")]), next = ModelMessage.user([.text("next")])
        func definition(_ name: String, _ size: Int) -> ModelToolDefinition {
            .init(name: name, description: String(repeating: "x", count: size), inputSchema: .object(["type": .string("object")]))
        }
        let old = definition("inline", 2_200_000), large = definition("inline", scenario == "single" ? 4_194_305 : 3_000_000)
        var controls: [ModelRequestConversationControl] = []
        var active: [ModelToolDefinition]
        func entry(_ value: ModelConversationControl, _ message: ModelMessage, _ index: Int) throws -> ModelRequestConversationControl {
            .init(entry: try .init(canonicalMessageCount: index + 1, boundaryDigest: digest(message), control: value), afterMessageIndex: index)
        }
        if scenario == "single" {
            controls = [try entry(.toolAddition(large), next, 2)]; active = [baseline, large]
        } else {
            controls = [try entry(.toolAddition(old), first, 0)]
            switch scenario {
            case "combined":
                let other = definition("other", 2_200_000)
                controls.append(try entry(.toolAddition(other), next, 2)); active = [baseline, old, other]
            case "remove":
                let other = definition("other", 3_000_000)
                controls.append(try entry(.toolRemoval(old.name), next, 2))
                controls.append(try entry(.toolAddition(other), next, 2)); active = [baseline, other]
            default:
                controls.append(try entry(.toolAddition(large), next, 2))
                if scenario == "repeat" { controls.append(try entry(.toolAddition(large), next, 2)) }
                active = [baseline, large]
            }
        }
        let request = ModelRequest(model: model, messages: [first, .assistant(content: [.text("ok")], toolCalls: []), next], tools: [baseline],
            conversationControls: .init(toolBaseline: [baseline], activeTools: active, controls: controls, coveredTools: [baseline], coveredToolChanges: false))
        let rejected = scenario == "single" || scenario == "combined"
        do { for try await _ in provider.stream(request: request) {}; #expect(!rejected) }
        catch let error as ModelProviderError {
            #expect(rejected && error.kind == .invalidRequest)
            #expect(error.message.contains("4,194,304"))
        }
        #expect(await probe.requests.count == (rejected ? 0 : 1))
    }

    @Test func trustedDeferredDiscoveryReminderAndFileReopenKeepHistoryAndThinking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trusted-controls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "controls", supportsNativeContext: true)
        let probe = ProviderRequestProbe(), executions = ProviderExecutionProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]),
                inlineToolChanges: true, runReminders: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture, anthropicTextFixture, anthropicTextFixture], chunkBytes: 7))
        let binding = try AgentModelBinding(profileID: "controls", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture-account", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"),
            continuationBindingRevision: "stable-root-1")
        let agent = try Agent(binding: binding)
        let session = try agent.makeSession(journal: journal)
        let capabilities = try await session.bindCapabilities(identity: "registry", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "discover", version: "1", tool: try TrustedDiscovery(probe: executions)),
            .init(id: "new", version: "1", tool: try TrustedNewTool(), exposure: .deferred)])
        let run = try await session.run("real user", contextControls: .init(reminder: "本轮请用中文回答"), capabilities: capabilities)
        #expect(try await run.wait().outcome == .completed)
        try await run.waitForDrain()
        #expect(await executions.count == 1)
        let canonical = await session.history
        #expect(canonical.filter { $0.role == .user }.count == 1)
        #expect(canonical.filter { $0.role == .tool }.count == 1)
        let sent = await probe.requests
        #expect(sent.count == 2)
        let first = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody!)
        let second = try JSONDecoder().decode(JSONValue.self, from: sent[1].httpBody!)
        #expect(first["tools"] == second["tools"])
        guard case .array(let messages) = second["messages"] else { Issue.record("missing messages"); return }
        let reminders = messages.filter { $0["clear_at"] == .string("next_user_message") }
        #expect(reminders.count == 2)
        #expect(messages.contains { $0["content"] == .array([.object(["type": .string("tool_addition"), "tool": .object(["type": .string("tool_reference"), "name": .string("new_tool")])])]) })
        #expect(String(decoding: sent[1].httpBody!, as: UTF8.self).contains("signature-1"))
        // New Run resets deferred availability using an appended removal, without touching old definitions.
        let next = try await session.run("next real user", capabilities: capabilities)
        #expect(try await next.wait().outcome == .completed); try await next.waitForDrain()
        let complete = await session.history
        let id = session.id
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        let freshCapabilities = try await fresh.bindCapabilities(identity: "registry", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "discover", version: "1", tool: try TrustedDiscovery(probe: executions)),
            .init(id: "new", version: "1", tool: try TrustedNewTool(), exposure: .deferred)])
        let resumed = try await fresh.run("after reopen", capabilities: freshCapabilities)
        #expect(try await resumed.wait().outcome == .completed); try await resumed.waitForDrain()
        #expect(Array(await fresh.history.prefix(complete.count)) == complete)
        #expect(await executions.count == 1)
        #expect(await probe.requests.count == 4)
        try await reopened.close()
    }


    @Test func crossRunSchemaUpdateAndRemovalUseTrustedExecutorsOnly() async throws {
        let probe = ProviderRequestProbe(), discoveries = ProviderExecutionProbe(), updatedExecutions = ProviderExecutionProbe()
        func toolFixture(_ name: String, _ id: String) -> Data {
            Data(String(decoding: anthropicToolFixture, as: UTF8.self).replacingOccurrences(of: "calculator", with: name).replacingOccurrences(of: "toolu-1", with: id).utf8)
        }
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture,
                toolFixture("new_tool", "updated-call"), anthropicTextFixture, toolFixture("new_tool", "removed-call"), anthropicTextFixture]))
        func binding(_ revision: String) throws -> AgentModelBinding {
            try .init(profileID: "schema-controls", profileRevision: revision, model: model, provider: provider,
                deployment: .init(serviceInstanceID: "fixture-account", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"), continuationBindingRevision: "stable-root")
        }
        let session = try Agent(binding: binding("1")).makeSession()
        let first = try await session.bindCapabilities(identity: "registry", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "discover", version: "1", tool: try TrustedDiscovery(probe: discoveries)),
            .init(id: "new", version: "1", tool: try TrustedNewTool(), exposure: .deferred)])
        let one = try await session.run("discover", capabilities: first)
        _ = try await one.wait(); try await one.waitForDrain()
        let changed = try await session.bindCapabilities(identity: "registry", version: "2", backendInstanceID: "fixture", backendVersion: "2", allowedResources: [.global], tools: [
            .init(id: "new", version: "2", tool: TrustedNewToolV2(probe: updatedExecutions))])
        let two = try await session.run("updated schema", capabilities: changed, using: binding("2"))
        _ = try await two.wait(); try await two.waitForDrain()
        let removed = try await session.bindCapabilities(identity: "registry", version: "3", backendInstanceID: "fixture", backendVersion: "3", allowedResources: [], tools: [])
        let three = try await session.run("tool removed", capabilities: removed, using: binding("3"))
        do { _ = try await three.wait(); Issue.record("Removed tool was allowed") }
        catch let error as ToolRegistryError { #expect(error == .unknownTool("new_tool")) }
        try await three.waitForDrain()
        #expect(await discoveries.count == 1)
        #expect(await updatedExecutions.count == 1)
        let sent = await probe.requests
        #expect(sent.count == 5)
        let initial = try JSONDecoder().decode(JSONValue.self, from: sent[0].httpBody!)
        let updated = try JSONDecoder().decode(JSONValue.self, from: sent[2].httpBody!)
        let removedBody = try JSONDecoder().decode(JSONValue.self, from: sent[4].httpBody!)
        #expect(initial["tools"] == updated["tools"] && updated["tools"] == removedBody["tools"])
        #expect(String(decoding: sent[2].httpBody!, as: UTF8.self).contains("Updated trusted schema"))
        #expect(String(decoding: sent[2].httpBody!, as: UTF8.self).contains("signature-1"))
        #expect(!(await session.history.contains { message in
            if case .tool(let result) = message { return result.callID.rawValue == "removed-call" }
            return false
        }))
    }

    @Test func drainedIdleCompactThenNewUserReminderSupportsRealToolLoop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("controls-after-compact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "reminder-native", supportsNativeContext: true)
        let block: JSONValue = .object(["type": .string("compaction"), "content": .string("earlier context"), "signature": .string("fixture-not-live"), "tool_changes": .array([])])
        let probe = ProviderRequestProbe(), executions = ProviderExecutionProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicTextFixture,
                try AnthropicNativeContextTests().fixture(block: block, threshold: false), anthropicThinkingToolFixture, anthropicTextFixture], chunkBytes: 7))
        let agent = try Agent(binding: .init(profileID: "compact-reminder", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture-account", endpointScope: endpoint.absoluteString, apiDialect: "anthropic")))
        let session = try agent.makeSession(journal: journal)
        let capability = try await session.bindCapabilities(identity: "registry", version: "1", backendInstanceID: "fixture", backendVersion: "1", allowedResources: [.global], tools: [
            .init(id: "discover", version: "1", tool: try TrustedDiscovery(probe: executions)),
            .init(id: "new", version: "1", tool: try TrustedNewTool(), exposure: .deferred)])
        let earlier = try await session.run("earlier real user", capabilities: capability)
        _ = try await earlier.wait(); try await earlier.waitForDrain()
        let operation = try await session.compact(mode: .anthropicOnDemand)
        #expect(try await operation.wait().checkpoint != nil); try await operation.waitForDrain()
        let run = try await session.run("new real user", contextControls: .init(reminder: "本轮请用中文回答"), capabilities: capability)
        #expect(try await run.wait().outcome == .completed); try await run.waitForDrain()
        #expect(await executions.count == 1)
        let sent = await probe.requests
        #expect(sent.count == 4)
        let body = try JSONDecoder().decode(JSONValue.self, from: sent[3].httpBody!)
        #expect(!String(decoding: sent[3].httpBody!, as: UTF8.self).contains("earlier real user"))
        guard case .array(let messages) = body["messages"] else { Issue.record("missing messages"); return }
        #expect(messages.first?["content"] == .array([block]))
        #expect(messages.filter { $0["clear_at"] == .string("next_user_message") }.count == 2)
        let canonical = await session.history, id = session.id
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(try await reopened.readMessages(sessionID: id).map(\.message) == canonical)
        try await reopened.close()
    }

    @Test func failedTurnWithoutAssistantCannotAdmitANewUserAfterReminder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("controls-failed-turn-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "controls-failure", supportsNativeContext: true)
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: [Data(), anthropicTextFixture])
        let agent = try Agent(binding: .init(profileID: "failed-controls", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture-account", endpointScope: endpoint.absoluteString, apiDialect: "anthropic")))
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("one", contextControls: .init(reminder: "Chinese this turn"))
        do { _ = try await run.wait(); Issue.record("EOF completed") } catch let error as ModelProviderError { #expect(error.kind == .invalidResponse) }
        try await run.waitForDrain()
        let canonical = await session.history
        #expect(canonical == [.user([.text("one")])])
        for actor in [session, try agent.makeSession(id: session.id, journal: journal)] {
            do { _ = try await actor.run("two", contextControls: .init(reminder: "New reminder")); Issue.record("illegal reminder/user boundary admitted") }
            catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        }
        #expect(await probe.requests.count == 1)
        #expect(try await journal.readMessages(sessionID: session.id).map(\.message) == canonical)
        try await journal.close()
    }
    @Test(arguments: [false, true]) func idleCompactRefusesFailedReminderTurnOrPermanentInstruction(_ permanent: Bool) async throws {
        let probe = ProviderRequestProbe(), provider = try provider(probe, bodies: permanent ? [anthropicTextFixture] : [])
        let agent = try Agent(binding: .init(profileID: "protected-control", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture-account", endpointScope: endpoint.absoluteString, apiDialect: "anthropic")))
        let session = try agent.makeSession()
        let controls = try AgentRunContextControls(instructions: permanent ? ["permanent trusted notice"] : [], reminder: permanent ? nil : "turn reminder")
        let run = try await session.run("one", contextControls: controls)
        if permanent { _ = try await run.wait() }
        else {
            do { _ = try await run.wait(); Issue.record("expected provider failure") }
            catch let error as ModelProviderError { #expect(error.kind == .transport) }
        }
        try await run.waitForDrain()
        let before = await session.history
        let operation = try await session.compact(mode: .anthropicOnDemand)
        do { _ = try await operation.wait(); Issue.record("protected control authority erased") }
        catch let error as ModelProviderError { #expect(error.kind == .unsupportedCapability) }
        try await operation.waitForDrain()
        #expect(await session.history == before)
        #expect(await probe.requests.count == 1)
    }

}

private extension JSONValue {
    subscript(key: String) -> JSONValue? { if case .object(let fields) = self { fields[key] } else { nil } }
}

private struct TrustedDiscovery: AgentTool {
    typealias Input = ProviderCalculator.Input
    typealias Output = ProviderCalculator.Output
    static let name = "calculator"
    static let description = ProviderCalculator.description
    static let inputSchema = ProviderCalculator.inputSchema
    static let outputSchema = ProviderCalculator.outputSchema
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    let probe: ProviderExecutionProbe
    init(probe: ProviderExecutionProbe) throws { self.probe = probe }
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record()
        return .init(output: .init(sum: input.a + input.b), declaredTools: ["new_tool"])
    }
}
private struct TrustedNewTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let result: String }
    static let name = "new_tool"
    static let description = "Trusted deferred tool"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.object(properties: ["result": .string], required: ["result"])
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    init() throws {}
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> { .init(output: .init(result: "known")) }
}

private struct TrustedNewToolV2: AgentTool {
    typealias Input = ProviderCalculator.Input
    struct Output: Codable, Sendable { let result: String }
    static let name = "new_tool"
    static let description = "Updated trusted schema"
    static let inputSchema = ToolSchema.object(properties: ["a": .integer, "b": .integer, "label": .string], required: ["a", "b"])
    static let outputSchema = ToolSchema.object(properties: ["result": .string], required: ["result"])
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    let probe: ProviderExecutionProbe
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await probe.record(); return .init(output: .init(result: "version 2"))
    }
}

private actor ReminderToolGate {
    var executions = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var blocked: [CheckedContinuation<Void, Never>] = []
    func waitForBoth() async {
        if executions == 2 { return }
        await withCheckedContinuation { entered = $0 }
    }
    func execute() async {
        executions += 1
        if executions == 2 { entered?.resume(); entered = nil }
        await withCheckedContinuation { blocked.append($0) }
    }
    func release() { blocked.forEach { $0.resume() }; blocked.removeAll() }
}
private struct ReminderParallelTool: AgentTool {
    typealias Input = ProviderCalculator.Input
    typealias Output = ProviderCalculator.Output
    static let name = "calculator"
    static let description = ProviderCalculator.description
    static let inputSchema = ProviderCalculator.inputSchema
    static let outputSchema = ProviderCalculator.outputSchema
    let policy = try! ToolPolicy.readOnly(authorization: .notRequired)
    let gate: ReminderToolGate
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        await gate.execute()
        return .init(output: .init(sum: input.a + input.b))
    }
}
private struct ReminderRetryTransport: ProviderHTTPTransport {
    let probe: ProviderRequestProbe
    func stream(_ request: URLRequest) -> AsyncThrowingStream<ProviderHTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let attempt = await probe.record(request)
                continuation.yield(.response(status: attempt == 1 ? 503 : 200, headers: ["Content-Type": "text/event-stream"]))
                if attempt == 1 { continuation.yield(.data(Data(#"{"error":{"type":"overloaded_error","message":"fixture retry"}}"#.utf8))) }
                else { continuation.yield(.data(anthropicTextFixture)) }
                continuation.finish()
            }
        }
    }
}
