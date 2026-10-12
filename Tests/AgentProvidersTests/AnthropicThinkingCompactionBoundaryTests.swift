import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import Foundation
import Testing

struct AnthropicThinkingCompactionBoundaryTests {
    @Test(arguments: [AnthropicThinkingPrefixMismatch.error, .dropBlock])
    func managedProofDoesNotInheritServerMismatchFallback(_ policy: AnthropicThinkingPrefixMismatch) async throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let probe = ProviderRequestProbe()
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]),
                thinkingPrefixMismatch: policy, preservedThinking: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture]))
        let model = ModelID(provider: "anthropic", name: "fixture")
        var accumulator = ModelEventAccumulator()
        for try await event in provider.stream(request: .init(model: model, messages: [.user([.text("original")])])) {
            try accumulator.append(event)
        }
        let response = try accumulator.finish()
        let changed = ModelRequest(model: model, messages: [.user([.text("tampered")]),
            .assistant(content: response.content, toolCalls: response.toolCalls),
            .tool(.init(callID: response.toolCalls[0].id, content: [.text("5")], isError: false))])
        // An explicit server policy may handle ordinary replay, but it cannot
        // establish the original proof needed for a managed replacement.
        try provider.validate(request: changed)
        #expect(throws: ModelProviderError.self) { try provider.validatePreservedThinkingTail(request: changed) }
        #expect(await probe.requests.count == 1)
    }

    @Test func cancelledReplacementValidationRetainsWriterUntilEstimatorDrains() async throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thinking-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "thinking-cancel", supportsNativeContext: true)
        let probe = ProviderRequestProbe(), gate = ReplacementEstimatorGate()
        let block: JSONValue = .object(["type": .string("compaction"), "content": .string("summary"), "signature": .string("fixture-only"), "tool_changes": .array([])])
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), preservedThinking: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture,
                try AnthropicNativeContextTests().fixture(block: block, threshold: false), anthropicTextFixture]))
        let binding = try AgentModelBinding(profileID: "tail", profileRevision: "1", model: .init(provider: "anthropic", name: "fixture"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        let agent = try Agent(binding: binding, tools: [ProviderCalculator()])
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("source"); _ = try await run.wait(); try await run.waitForDrain()
        let before = await session.history
        let boundary = try #require(try await session.compactionBoundaries().first)
        let validationBinding = try AgentModelBinding(profileID: binding.profileID, profileRevision: binding.profileRevision,
            model: binding.model, provider: provider, deployment: binding.deployment,
            tokenBudget: .init(maximumContextTokens: 1000, reservedOutputTokens: 0, estimator: gate))
        let operation = try await session.compact(mode: .anthropicOnDemand, through: boundary, using: validationBinding)
        await gate.waitEntered()
        await operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.wait() }
        await #expect(throws: AgentSessionError.runInProgress) { try await session.run("blocked") }
        let fresh = try agent.makeSession(id: session.id, journal: journal)
        await #expect(throws: AgentSessionError.runInProgress) { try await fresh.run("also blocked") }
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == nil)
        #expect(await session.history == before)
        #expect(await probe.requests.count == 3)
        await gate.release(); try await operation.waitForDrain()
        #expect(try await journal.nativeContextCheckpoint(sessionID: session.id) == nil)
        let next = try await session.run("after drain"); _ = try await next.wait(); try await next.waitForDrain()
        #expect(await probe.requests.count == 4)
        try await journal.close()
    }

    @Test(arguments: [false, true]) func actualRequestBoundaryKeepsSignedTailAndReopens(bounded: Bool) async throws {
        let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thinking-tail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "thinking-tail", supportsNativeContext: true)
        let probe = ProviderRequestProbe()
        let block: JSONValue = .object(["type": .string("compaction"), "content": .string("summarized request"), "signature": .string("fixture-not-live"), "tool_changes": .array([])])
        let provider = try AnthropicProvider(apiKey: "fixture", thinking: .adaptive,
            nativeContext: .init(qualification: .init(endpoint: endpoint, resolvedModelNames: ["fixture"], modes: [.anthropicOnDemand]), preservedThinking: true),
            transport: FixtureHTTPTransport(probe: probe, bodies: [anthropicThinkingToolFixture, anthropicTextFixture,
                try AnthropicNativeContextTests().fixture(block: block, threshold: false), Data(String(decoding: anthropicThinkingToolFixture, as: UTF8.self).replacingOccurrences(of: "toolu-1", with: "toolu-2").replacingOccurrences(of: "signature-1", with: "signature-2").utf8), anthropicTextFixture,
                try AnthropicNativeContextTests().fixture(block: block, threshold: false), anthropicTextFixture], chunkBytes: 7))
        let model = ModelID(provider: "anthropic", name: "fixture")
        let binding = try AgentModelBinding(profileID: "tail", profileRevision: "1", model: model, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: endpoint.absoluteString, apiDialect: "anthropic"))
        let agent = try Agent(binding: binding, tools: [ProviderCalculator()])
        let session = try agent.makeSession(journal: journal)
        let run = try await session.run("actual request")
        #expect(try await run.wait().outcome == .completed); try await run.waitForDrain()
        let before = await session.history
        let boundary = try #require(try await session.compactionBoundaries().first)
        #expect(boundary.canonicalMessageCount == 1)
        let compactBinding = try AgentModelBinding(profileID: "tail", profileRevision: "1", model: model, provider: provider,
            deployment: binding.deployment, tokenBudget: bounded ? .init(maximumContextTokens: 350, reservedOutputTokens: 0, estimator: TailEstimator()) : nil)
        let operation = try await session.compact(mode: .anthropicOnDemand, through: boundary, using: compactBinding)
        #expect(try await operation.wait().checkpoint != nil); try await operation.waitForDrain()
        #expect(await session.history == before)
        if !bounded {
            let rewriting = try AgentModelBinding(profileID: "tail", profileRevision: "1", model: model, provider: provider,
                deployment: binding.deployment, projector: RewriteProtectedTail())
            do {
                let forbidden = try await session.run("forbidden", using: rewriting)
                _ = try await forbidden.wait(); try await forbidden.waitForDrain()
                Issue.record("A projector changed the protected kept tail and dispatched a request")
                return
            } catch AgentModelBindingError.invalidProjection { }
            #expect(await session.history == before)
            #expect(await probe.requests.count == 3)
        }
        let reused = try await session.compact(mode: .anthropicOnDemand, through: boundary)
        await #expect(throws: AgentModelBindingError.incompatibleContinuation) { try await reused.wait() }
        try await reused.waitForDrain()
        #expect(await probe.requests.count == 3)
        let next = try await session.run("next")
        #expect(try await next.wait().outcome == .completed); try await next.waitForDrain()
        let sent = await probe.requests
        #expect(sent.count == 5)
        #expect(String(decoding: sent[3].httpBody!, as: UTF8.self).contains("signature-1"))
        #expect(!String(decoding: sent[3].httpBody!, as: UTF8.self).contains("actual request"))
        let nextBoundary = try #require(try await session.compactionBoundaries().first)
        #expect(nextBoundary.canonicalMessageCount > boundary.canonicalMessageCount)
        let second = try await session.compact(mode: .anthropicOnDemand, through: nextBoundary)
        #expect(try await second.wait().checkpoint?.generation == 2); try await second.waitForDrain()
        #expect(await probe.requests.count == 6)
        let complete = await session.history, id = session.id
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        let fresh = try agent.makeSession(id: id, journal: reopened)
        let resumed = try await fresh.run("after reopen")
        #expect(try await resumed.wait().outcome == .completed); try await resumed.waitForDrain()
        #expect(Array(await fresh.history.prefix(complete.count)) == complete)
        #expect(await probe.requests.count == 7)
        try await reopened.close()
    }
}

private struct TailEstimator: AgentNativeContextTokenEstimator {
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        .init(inputTokens: input.messages.count * 100 + (input.nativeContext == nil ? 0 : 10), accuracy: .exact)
    }
}

private struct RewriteProtectedTail: AgentContextProjector {
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        var messages = input.canonicalMessages
        messages.remove(at: 2)
        return .init(messages: messages, plan: .init(projectionID: "tail-rewrite", version: "1",
            sourceRevision: input.conversationRevision, sourceDigest: try input.sourceDigest(),
            contextEpoch: input.contextEpoch, lossy: true))
    }
}

private actor ReplacementEstimatorGate: AgentNativeContextTokenEstimator {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        if input.nativeContext != nil {
            entered = true; enteredWaiters.forEach { $0.resume() }; enteredWaiters.removeAll()
            await withCheckedContinuation { waiter = $0 }
        }
        return .init(inputTokens: 100, accuracy: .exact)
    }
    func waitEntered() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func release() { waiter?.resume(); waiter = nil }
}
