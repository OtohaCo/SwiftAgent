import AgentModels
import Testing
import XCTest

struct ModelEventProducerTests {
    private let info = ResponseInfo(id: "producer", model: .init(provider: "fixture", name: "test"))

    @Test func producerFinishesAndPropagatesClassifiedErrors() async throws {
        let response = ModelResponse(info: info, content: [.text("ready")], stopReason: .endTurn)
        let stream = ModelEventStream.make { emit in
            try emit(.responseStarted(info))
            try emit(.textDelta("ready"))
            try emit(.responseCompleted(response))
        }
        var accumulator = ModelEventAccumulator()
        for try await event in stream { try accumulator.append(event) }
        #expect(try accumulator.finish() == response)
        let failure = ModelProviderError(kind: .transport, message: "Disconnected")
        let failed = ModelEventStream.make { _ in throw failure }
        await #expect(throws: failure) { for try await _ in failed {} }
    }

    @Test func consumerCancellationReachesAndStopsProducer() async throws {
        let started = XCTestExpectation(description: "Producer entered")
        let cancelled = XCTestExpectation(description: "Producer cancelled")
        let stopped = XCTestExpectation(description: "Producer stopped")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let stream = ModelEventStream.make { emit in
            try emit(.responseStarted(info))
            started.fulfill()
            await withTaskCancellationHandler {
                for await _ in gate.stream {}
            } onCancel: {
                cancelled.fulfill()
            }
            stopped.fulfill()
            try Task.checkCancellation()
        }
        let consumer = Task {
            for try await _ in stream {}
            try Task.checkCancellation()
        }
        defer { consumer.cancel() }
        #expect(await XCTWaiter.fulfillment(of: [started], timeout: 2) == .completed)
        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(await XCTWaiter.fulfillment(of: [cancelled, stopped], timeout: 2) == .completed)
    }

    @Test func cancelledCallerCannotStartAProducer() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let builder = Task {
            for await _ in gate.stream {}
            return ModelEventStream.make { _ in }
        }
        builder.cancel()
        let stream = await builder.value
        await #expect(throws: CancellationError.self) { for try await _ in stream {} }
    }

    @Test func producerCancellationIsNotReclassified() async throws {
        let stream = ModelEventStream.make { _ in throw CancellationError() }
        await #expect(throws: CancellationError.self) { for try await _ in stream {} }
    }

    @Test func failureAfterBufferedTerminalStillFailsConsumer() async throws {
        let failure = ModelProviderError(kind: .transport, message: "Stream ended unexpectedly")
        let stream = ModelEventStream.make { emit in
            try emit(.responseStarted(info))
            try emit(.responseCompleted(.init(info: info, stopReason: .endTurn)))
            throw failure
        }
        var count = 0
        await #expect(throws: failure) {
            for try await _ in stream { count += 1 }
        }
        #expect(count == 2)
    }

    @Test func cancellationAfterTerminalCannotBeReportedAsSuccess() async throws {
        let received = XCTestExpectation(description: "Terminal received")
        let stopped = XCTestExpectation(description: "Producer stopped")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let stream = ModelEventStream.make { emit in
            defer { stopped.fulfill() }
            try emit(.responseStarted(info))
            try emit(.responseCompleted(.init(info: info, stopReason: .endTurn)))
            for await _ in gate.stream {}
        }
        let consumer = Task {
            var accumulator = ModelEventAccumulator()
            for try await event in stream {
                try Task.checkCancellation()
                try accumulator.append(event)
                if case .responseCompleted = event { received.fulfill() }
            }
            try Task.checkCancellation()
            return try accumulator.finish()
        }
        defer { consumer.cancel() }
        #expect(await XCTWaiter.fulfillment(of: [received], timeout: 2) == .completed)
        consumer.cancel()
        await #expect(throws: CancellationError.self) { try await consumer.value }
        #expect(await XCTWaiter.fulfillment(of: [stopped], timeout: 2) == .completed)
    }

    @Test func cancellingOneStreamLeavesAnotherUsable() async throws {
        let gateA = AsyncStream<Void>.makeStream()
        let gateB = AsyncStream<Void>.makeStream()
        defer { gateA.continuation.finish(); gateB.continuation.finish() }
        let startedA = XCTestExpectation(description: "A started")
        let startedB = XCTestExpectation(description: "B started")
        let expected = ModelResponse(info: info, content: [.text("B finished")], stopReason: .endTurn)
        let streamA = ModelEventStream.make { _ in
            startedA.fulfill()
            for await _ in gateA.stream {}
        }
        let streamB = ModelEventStream.make { emit in
            try emit(.responseStarted(info))
            startedB.fulfill()
            for await _ in gateB.stream {}
            try emit(.textDelta("B finished"))
            try emit(.responseCompleted(expected))
        }
        let consumerA = Task {
            for try await _ in streamA {}
            try Task.checkCancellation()
        }
        let consumerB = Task {
            var accumulator = ModelEventAccumulator()
            for try await event in streamB { try accumulator.append(event) }
            return try accumulator.finish()
        }
        defer { consumerA.cancel(); consumerB.cancel() }
        #expect(await XCTWaiter.fulfillment(of: [startedA, startedB], timeout: 2) == .completed)
        consumerA.cancel()
        await #expect(throws: CancellationError.self) { try await consumerA.value }
        gateB.continuation.finish()
        #expect(try await consumerB.value == expected)
    }
}
