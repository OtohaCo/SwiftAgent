import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentProviders
import AgentTools
import Foundation
import Testing

struct AnthropicIncompleteHandoffTests {
    @Test(arguments: ["truncated", "error", "cancel"])
    func nativeReminderTurnRetiresAfterTruncationCancellationOrAdmissionError(_ mode: String) async throws {
        let helper = AnthropicHostCompactionTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("anthropic-incomplete-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        var journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "incomplete-http", supportsContextHandoff: true)
        let oldProbe = ProviderRequestProbe()
        let gate = HostSummaryGate()
        let truncated = Data(String(decoding: helper.fixture(anthropicTextFixture), as: UTF8.self)
            .replacingOccurrences(of: "end_turn", with: "max_tokens").utf8)
        let bodies = [helper.fixture(anthropicTextFixture), helper.fixture(try helper.summary())] + (mode == "error" ? [] : [truncated])
        let oldProvider = mode == "cancel" ? try AnthropicProvider(apiKey: "fixture", thinking: .serviceDefault,
            nativeContext: .init(qualification: .init(endpoint: helper.endpoint, resolvedModelNames: [helper.model.name], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true),
            transport: HostSummaryTransport(probe: oldProbe, bodies: bodies, gate: gate)) : try helper.provider(oldProbe, bodies: bodies)
        let oldBinding = try helper.binding(oldProvider), oldAgent = try Agent(binding: oldBinding)
        var session = try oldAgent.makeSession(journal: journal)
        let id = session.id
        let initial = try await session.run("important constraint", contextControls: .init(reminder: "initial reminder"))
        _ = try await initial.wait(); try await initial.waitForDrain()
        let compact = try await session.compact(mode: .anthropicOnDemand)
        _ = try await compact.wait(); try await compact.waitForDrain()
        let native = try #require(try await journal.nativeContextCheckpoint(sessionID: id))
        let failed = try await session.run("unfinished question", contextControls: .init(reminder: "unfinished reminder"))
        if mode == "cancel" {
            await gate.waitEntered(); await failed.cancel()
            await #expect(throws: CancellationError.self) { try await failed.wait() }
            await gate.release()
        } else if mode == "error" { await #expect(throws: ModelProviderError.self) { try await failed.wait() } }
        else { #expect(try await failed.wait().outcome == .incomplete(.maxOutputTokens)) }
        try await failed.waitForDrain()
        let before = try await journal.readMessages(sessionID: id), terminal = try await journal.runRecord(sessionID: id, runID: failed.id)
        let controls = try await journal.conversationControlState(sessionID: id)
        #expect(before.last?.message.role == (mode == "truncated" ? .assistant : .user))
        try await journal.close()
        journal = try AgentIncrementalJournal.upgradeForIncompleteContextHandoff(at: directory)
        #expect(try await journal.nativeContextCheckpoint(sessionID: id) == native)
        #expect(try await journal.conversationControlState(sessionID: id) == controls)
        session = try oldAgent.makeSession(id: id, journal: journal)

        let targetProbe = ProviderRequestProbe(), targetName = "claude-opus-5-5"
        let targetBody = Data(String(decoding: anthropicTextFixture, as: UTF8.self).replacingOccurrences(of: "fixture", with: targetName).utf8)
        let targetProvider = try AnthropicProvider(apiKey: "fixture", nativeContext: .init(qualification: .init(
            endpoint: helper.endpoint, resolvedModelNames: [targetName], modes: [.anthropicOnDemand]), inlineToolChanges: true, runReminders: true),
            transport: FixtureHTTPTransport(probe: targetProbe, bodies: [targetBody, targetBody], chunkBytes: 7))
        let target = try AgentModelBinding(profileID: "target", profileRevision: "1", model: .init(provider: "anthropic", name: targetName), provider: targetProvider,
            deployment: .init(serviceInstanceID: "target", endpointScope: helper.endpoint.absoluteString, apiDialect: "anthropic"))
        let scope = try await session.bindCapabilities(identity: "target", version: "1", backendInstanceID: "fixture", backendVersion: "1",
            allowedResources: [.global], tools: [.init(id: "calculator", version: "1", tool: ProviderCalculator())])
        let exit = try await session.handoffToOrdinary(using: target, capabilities: scope, discardingRetiredProviderContinuations: true, allowingIncompleteTurn: true)
        let retirement = try await exit.wait(); try await exit.waitForDrain()
        #expect(retirement.retiredNativeCheckpointID == native.id)
        #expect(retirement.completedRunID == nil)
        #expect(retirement.closedTurnProof?.terminal == (mode == "cancel" ? .cancelled : mode == "error" ? .failed(.provider) : .incomplete(.maxOutputTokens)))
        #expect(try await journal.readMessages(sessionID: id) == before)
        #expect(try await journal.runRecord(sessionID: id, runID: failed.id) == terminal)
        #expect(await oldProbe.requests.count == 3)
        #expect(await targetProbe.requests.isEmpty)
        let next = try await session.run("real new user", contextControls: .init(reminder: "new reminder"), using: target, capabilities: scope)
        #expect(try await next.wait().outcome == .completed); try await next.waitForDrain()
        let requests = await targetProbe.requests
        let body = String(decoding: try #require(requests.first?.httpBody), as: UTF8.self)
        #expect(body.contains("important constraint") && body.contains("unfinished question") && body.contains("new reminder"))
        #expect(body.contains("calculator") && !body.contains("unfinished reminder") && !body.contains("compaction"))
        let final = try await journal.readMessages(sessionID: id)
        try await journal.close()
        journal = try AgentIncrementalJournal.open(at: directory)
        let fresh = try Agent(binding: target, tools: [ProviderCalculator()]).makeSession(id: id, journal: journal)
        let again = try await fresh.run("reopened real user", contextControls: .init(reminder: "latest reminder"))
        _ = try await again.wait(); try await again.waitForDrain()
        #expect(Array(try await journal.readMessages(sessionID: id).prefix(final.count)) == final)
        #expect(try await journal.runRecord(sessionID: id, runID: failed.id) == terminal)
        #expect(await targetProbe.requests.count == 2)
        try await journal.close()
    }
}
