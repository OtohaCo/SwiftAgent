@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

struct AgentFollowUpStatusUpdatesTests {
    @Test func theStreamStartsWithTheStatusAtTheMomentOfTheCall() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        var iterator = await fixture.dispatcher.statusUpdates().makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.mode == .running)
        #expect(first?.currentInputID == nil)
        #expect(first?.physicallyDrained == false)
    }

    @Test func aChangeBetweenSubscribingAndTheFirstReadIsNotMissed() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let updates = await fixture.dispatcher.statusUpdates()
        await fixture.dispatcher.pause()
        // Nothing was read before the pause: the first element must already show it.
        var iterator = updates.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.mode == .paused)
    }

    @Test func aSlowConsumerOnlySeesTheNewestStatus() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let updates = await fixture.dispatcher.statusUpdates()
        await fixture.dispatcher.pause()
        try await fixture.dispatcher.resume()
        await fixture.dispatcher.pause()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next()?.mode == .paused)
        await fixture.dispatcher.stop()
        #expect(await iterator.next()?.mode == .stopped)
    }

    @Test func anInputInFlightAndItsEndAreAnnounced() async throws {
        let fixture = try await Fixture.make(gated: true)
        defer { Task { await fixture.close() } }
        let updates = await fixture.dispatcher.statusUpdates()
        _ = try await fixture.session.enqueueFollowUp(.init(inputID: "one", text: "first",
            operationID: "op-one", configurationRef: "v1"))
        var iterator = updates.makeAsyncIterator()
        var seen: AgentFollowUpDispatchStatus?
        while let status = await iterator.next() {
            if status.currentInputID == "one" { seen = status; break }
        }
        #expect(seen?.mode == .running)
        await fixture.dispatcher.pause()
        var paused: AgentFollowUpDispatchStatus?
        while let status = await iterator.next() {
            if status.mode == .paused && status.currentInputID == nil { paused = status; break }
        }
        #expect(paused != nil)
    }

    @Test func aFailureThatPausesTheDispatcherIsAnnounced() async throws {
        let fixture = try await Fixture.make(failing: true)
        defer { Task { await fixture.close() } }
        let updates = await fixture.dispatcher.statusUpdates()
        _ = try await fixture.session.enqueueFollowUp(.init(inputID: "one", text: "first",
            operationID: "op-one", configurationRef: "v1"))
        var failed: AgentFollowUpDispatchStatus?
        for await status in updates where status.mode == .paused && status.lastFailureKind != nil {
            failed = status; break
        }
        #expect(failed?.lastFailureKind == "resolver_or_run")
        #expect(failed?.currentInputID == nil)
    }

    @Test func theStreamEndsAfterTheFinalStatusOnceTheDispatcherHasDrained() async throws {
        let fixture = try await Fixture.make()
        let updates = await fixture.dispatcher.statusUpdates()
        await fixture.dispatcher.stop()
        try await fixture.dispatcher.waitForDrain()
        var last: AgentFollowUpDispatchStatus?
        for await status in updates { last = status }
        #expect(last?.mode == .stopped)
        #expect(last?.physicallyDrained == true)
        await fixture.close()
    }

    @Test func subscribingToAStoppedDispatcherYieldsItsFinalStatusThenFinishes() async throws {
        let fixture = try await Fixture.make()
        await fixture.dispatcher.stop()
        try await fixture.dispatcher.waitForDrain()
        var seen: [AgentFollowUpDispatchStatus] = []
        for await status in await fixture.dispatcher.statusUpdates() { seen.append(status) }
        #expect(seen.map(\.mode) == [.stopped])
        #expect(seen.first?.physicallyDrained == true)
        await fixture.close()
    }

    @Test func cancellingOneConsumerEndsItWithoutAffectingAnother() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let cancelled = Task { () -> Int in
            var count = 0
            for await _ in await fixture.dispatcher.statusUpdates() { count += 1 }
            return count
        }
        let other = await fixture.dispatcher.statusUpdates()
        cancelled.cancel()
        _ = await cancelled.value
        await fixture.dispatcher.pause()
        var iterator = other.makeAsyncIterator()
        var mode: AgentFollowUpDispatchStatus.Mode?
        while let status = await iterator.next() {
            mode = status.mode
            if status.mode == .paused { break }
        }
        #expect(mode == .paused)
    }

    @Test func everyConsumerSeesTheSameFinalStatus() async throws {
        let fixture = try await Fixture.make()
        let streams = [await fixture.dispatcher.statusUpdates(), await fixture.dispatcher.statusUpdates()]
        await fixture.dispatcher.pause()
        await fixture.dispatcher.stop()
        try await fixture.dispatcher.waitForDrain()
        for stream in streams {
            var last: AgentFollowUpDispatchStatus?
            for await status in stream { last = status }
            #expect(last?.mode == .stopped)
        }
        await fixture.close()
    }
}

private struct Fixture {
    let directory: URL
    let journal: AgentJournal
    let session: AgentSession
    let dispatcher: AgentFollowUpDispatcher

    static func make(gated: Bool = false, failing: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("status-updates-\(UUID())")
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "status-updates")
        let provider = StatusFixtureProvider()
        let session = try Agent(model: .init(provider: "status-fixture", name: "fixed"), provider: provider)
            .makeSession(journal: journal)
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(30)),
            resolver: StatusFixtureResolver(session: session, provider: provider, gated: gated, failing: failing))
        return Fixture(directory: directory, journal: journal, session: session, dispatcher: dispatcher)
    }

    func close() async {
        await dispatcher.stop()
        try? await dispatcher.waitForDrain()
        try? await journal.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct StatusFixtureProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "status-fixture", capabilities: [.streaming, .multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: .endTurn)))
        }
    }
}

private struct StatusFixtureError: Error {}

private struct StatusFixtureResolver: AgentFollowUpResolver {
    let session: AgentSession
    let provider: StatusFixtureProvider
    let gated: Bool
    let failing: Bool
    func resolve(_ request: AgentFollowUpResolution) async throws -> AgentFollowUpConfiguration {
        if failing { throw StatusFixtureError() }
        // Holds the input in flight until the dispatcher pauses and cancels it.
        if gated { try await Task.sleep(for: .seconds(600)) }
        let scope = try await session.bindCapabilities(identity: "explicit-empty", version: "1",
            backendInstanceID: "fixture", backendVersion: "1", allowedResources: [], tools: [])
        return .init(model: try AgentModelBinding(profileID: "status-fixture", profileRevision: "1",
            model: .init(provider: "status-fixture", name: "fixed"), provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture")),
            capabilities: scope, expectedConversationRevision: nil)
    }
}
