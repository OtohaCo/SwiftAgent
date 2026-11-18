@testable import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

struct AgentFollowUpStatusUpdatesTests {
    @Test func theStreamStartsWithTheStatusAtTheMomentOfTheCall() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let reader = await fixture.reader()
        let first = await reader.next()
        #expect(first?.mode == .running)
        #expect(first?.currentInputID == nil)
        #expect(first?.physicallyDrained == false)
    }

    @Test func aChangeBetweenSubscribingAndTheFirstReadIsNotMissed() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let reader = await fixture.reader()
        await fixture.dispatcher.pause()
        // Nothing was read before the pause: the first element must already show it.
        let first = await reader.next()
        #expect(first?.mode == .paused, "the pause made after subscribing was lost")
    }

    @Test func aSlowConsumerOnlySeesTheNewestStatus() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let reader = await fixture.reader()
        await fixture.dispatcher.pause()
        try await fixture.dispatcher.resume()
        await fixture.dispatcher.pause()
        #expect(await reader.next()?.mode == .paused)
        await fixture.dispatcher.stop()
        #expect(await reader.next()?.mode == .stopped)
    }

    @Test func anInputInFlightAndItsEndAreAnnounced() async throws {
        let fixture = try await Fixture.make(gated: true)
        defer { Task { await fixture.close() } }
        let reader = await fixture.reader()
        _ = try await fixture.session.enqueueFollowUp(.init(inputID: "one", text: "first",
            operationID: "op-one", configurationRef: "v1"))
        let inFlight = await reader.next(where: { $0.currentInputID == "one" })
        #expect(inFlight?.mode == .running)
        await fixture.dispatcher.pause()
        let paused = await reader.next(where: { $0.mode == .paused && $0.currentInputID == nil })
        #expect(paused != nil)
    }

    @Test func aFailureThatPausesTheDispatcherIsAnnounced() async throws {
        let fixture = try await Fixture.make(failing: true)
        defer { Task { await fixture.close() } }
        let reader = await fixture.reader()
        _ = try await fixture.session.enqueueFollowUp(.init(inputID: "one", text: "first",
            operationID: "op-one", configurationRef: "v1"))
        let failed = await reader.next(where: { $0.mode == .paused })
        // One status for the whole change: paused, with its cause, and no input left in flight.
        #expect(failed?.lastFailureKind == "resolver_or_run")
        #expect(failed?.currentInputID == nil)
    }

    @Test(arguments: 0..<10) func aStatusIsNeverSeenHalfChanged(_ round: Int) async throws {
        let fixture = try await Fixture.make(refusingRun: true)
        defer { Task { await fixture.close() } }
        let reader = await fixture.reader()
        _ = try await fixture.session.enqueueFollowUp(.init(inputID: "first", text: "first",
            operationID: "op-first", configurationRef: "v1"))
        // A run that ends in a refusal leaves one input in flight, then (paused, interrupted) at once:
        // never a running dispatcher with nothing in flight and nothing interrupted in between.
        var seenInFlight = false
        while let status = await reader.next() {
            if status.currentInputID != nil { seenInFlight = true; continue }
            if seenInFlight {
                #expect(status.mode == .paused && status.interruptedInputID == "first", "half-changed status: \(status)")
                return
            }
        }
        Issue.record("the interrupted status never arrived")
    }

    @Test func theStreamEndsAfterTheFinalStatusOnceTheDispatcherHasDrained() async throws {
        let fixture = try await Fixture.make()
        let reader = await fixture.reader()
        await fixture.dispatcher.stop()
        try await fixture.dispatcher.waitForDrain()
        var last: AgentFollowUpDispatchStatus?
        while let status = await reader.next() { last = status }
        #expect(last?.mode == .stopped)
        #expect(last?.physicallyDrained == true)
        await fixture.close()
    }

    @Test func subscribingToAStoppedDispatcherYieldsItsFinalStatusThenFinishes() async throws {
        let fixture = try await Fixture.make()
        await fixture.dispatcher.stop()
        try await fixture.dispatcher.waitForDrain()
        let reader = await fixture.reader()
        var seen: [AgentFollowUpDispatchStatus] = []
        while let status = await reader.next() { seen.append(status) }
        #expect(seen.map(\.mode) == [.stopped])
        #expect(seen.first?.physicallyDrained == true)
        await fixture.close()
    }

    @Test func cancellingOneConsumerEndsItAndRemovesItsSubscription() async throws {
        let fixture = try await Fixture.make()
        defer { Task { await fixture.close() } }
        let cancelledStream = await fixture.dispatcher.statusUpdates()
        let cancelled = Task { () -> Int in
            var count = 0
            for await _ in cancelledStream { count += 1 }
            return count
        }
        let other = await fixture.reader()
        #expect(await fixture.dispatcher.statusSubscriberCount == 2)
        cancelled.cancel()
        _ = await cancelled.value
        // The subscription is dropped when the stream terminates, a moment after the cancellation.
        var remaining = await fixture.dispatcher.statusSubscriberCount
        for _ in 0..<1000 where remaining != 1 {
            try await Task.sleep(for: .milliseconds(5))
            remaining = await fixture.dispatcher.statusSubscriberCount
        }
        #expect(remaining == 1, "a cancelled consumer is still subscribed")
        await fixture.dispatcher.pause()
        #expect(await other.next(where: { $0.mode == .paused }) != nil)
    }

    @Test func everyConsumerSeesTheSameFinalStatus() async throws {
        let fixture = try await Fixture.make()
        let readers = [await fixture.reader(), await fixture.reader()]
        await fixture.dispatcher.pause()
        await fixture.dispatcher.stop()
        try await fixture.dispatcher.waitForDrain()
        for reader in readers {
            var last: AgentFollowUpDispatchStatus?
            while let status = await reader.next() { last = status }
            #expect(last?.mode == .stopped)
        }
        await fixture.close()
    }
}

/// Reads a status stream one element at a time and cannot hang a run: a read that finds nothing in time
/// is cancelled (which ends the stream) and gives nil.
private final class StatusReader: @unchecked Sendable {
    // One read at a time: the tests only ever await a read before starting the next.
    private var iterator: AsyncStream<AgentFollowUpDispatchStatus>.Iterator
    init(_ stream: AsyncStream<AgentFollowUpDispatchStatus>) { iterator = stream.makeAsyncIterator() }

    func next(where predicate: @escaping @Sendable (AgentFollowUpDispatchStatus) -> Bool = { _ in true },
              within seconds: Int = 10) async -> AgentFollowUpDispatchStatus? {
        let consumer = Task { await self.pull(where: predicate) }
        let watchdog = Task { try await Task.sleep(for: .seconds(seconds)); consumer.cancel() }
        defer { watchdog.cancel() }
        return await consumer.value
    }

    private func pull(where predicate: @Sendable (AgentFollowUpDispatchStatus) -> Bool) async -> AgentFollowUpDispatchStatus? {
        while let status = await iterator.next(), !Task.isCancelled {
            if predicate(status) { return status }
        }
        return nil
    }
}

private struct Fixture {
    let directory: URL
    let journal: AgentJournal
    let session: AgentSession
    let dispatcher: AgentFollowUpDispatcher

    static func make(gated: Bool = false, failing: Bool = false, refusingRun: Bool = false) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("status-updates-\(UUID())")
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "status-updates")
        let provider = StatusFixtureProvider(stop: refusingRun ? .refusal : .endTurn)
        let session = try Agent(model: .init(provider: "status-fixture", name: "fixed"), provider: provider)
            .makeSession(journal: journal)
        let dispatcher = try await session.startFollowUpDispatch(
            policy: .init(runTimeout: .seconds(30)),
            resolver: StatusFixtureResolver(session: session, provider: provider, gated: gated, failing: failing))
        return Fixture(directory: directory, journal: journal, session: session, dispatcher: dispatcher)
    }

    func reader() async -> StatusReader { StatusReader(await dispatcher.statusUpdates()) }

    func close() async {
        await dispatcher.stop()
        try? await dispatcher.waitForDrain()
        try? await journal.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct StatusFixtureProvider: ModelProvider {
    var stop: StopReason = .endTurn
    let descriptor = ModelProviderDescriptor(id: "status-fixture", capabilities: [.streaming, .multiTurn])
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "fixed", model: request.model)
            try emit(.responseStarted(info))
            try emit(.textDelta("done"))
            try emit(.responseCompleted(.init(info: info, content: [.text("done")], stopReason: stop)))
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
