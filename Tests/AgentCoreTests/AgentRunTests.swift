import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentRunTests {
    @Test func explicitCancelIsObservableAndSessionCanContinue() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Provider entered")
        let late = XCTestExpectation(description: "Old provider returned")
        let provider = ScriptedProvider { request, turn in
            if turn == 1 { entered.fulfill(); await gate.wait(); late.fulfill() }
            return textResponse(request, "Done")
        }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let run = try await session.run("first")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await run.cancel()
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await collectEvents(run.events).last == .runFinished(.cancelled))
        let next = try await session.run("next")
        _ = try await next.wait()
        await gate.open()
        #expect(await XCTWaiter.fulfillment(of: [late], timeout: 1) == .completed)
        #expect(await session.history == [.user([.text("first")]), .user([.text("next")]), .assistant(content: [.text("Done")], toolCalls: [])])
    }

    @Test func cancellingAWaiterDoesNotCancelTheOwnedRun() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Provider entered")
        let waiting = XCTestExpectation(description: "Waiter entered")
        let finished = XCTestExpectation(description: "Waiter finished")
        let provider = ScriptedProvider { request, _ in entered.fulfill(); await gate.wait(); return textResponse(request, "Done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let run = try await session.run("work")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        let waiter = Task {
            defer { finished.fulfill() }
            waiting.fulfill()
            return try await run.wait()
        }
        #expect(await XCTWaiter.fulfillment(of: [waiting], timeout: 1) == .completed)
        waiter.cancel()
        #expect(await XCTWaiter.fulfillment(of: [finished], timeout: 1) == .completed)
        await gate.open()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try await run.wait().outcome == .completed)
        #expect(try await run.wait().outcome == .completed)
    }

    @Test func disconnectingEventObserverDoesNotCancelTheOwnedRun() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Provider entered")
        let provider = ScriptedProvider { request, _ in entered.fulfill(); await gate.wait(); return textResponse(request, "Done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let run = try await session.run("work")
        let observer = Task { await collectEvents(run.events) }
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        observer.cancel()
        _ = await observer.value
        await gate.open()
        #expect(try await run.wait().outcome == .completed)
    }

    @Test func immediateCancellationCannotBeLostBeforeWorkerInstallation() async throws {
        let gate = ManualGate()
        let provider = ScriptedProvider { request, _ in await gate.wait(); return textResponse(request, "Late") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let run = try await session.run("cancel now")
        await run.cancel()
        await #expect(throws: CancellationError.self) { try await run.wait() }
        #expect(await session.activeRunID == nil)
        await gate.open()
        #expect(await session.history == [.user([.text("cancel now")])])
    }

    @Test func cancellingAndRestartingSessionADoesNotSupersedeSessionB() async throws {
        let gateA = ManualGate(), gateB = ManualGate()
        let enteredA = XCTestExpectation(description: "A entered"), enteredB = XCTestExpectation(description: "B entered")
        let provider = ScriptedProvider { request, _ in
            if request.messages.last == .user([.text("A")]) { enteredA.fulfill(); await gateA.wait(); return textResponse(request, "A") }
            if request.messages.last == .user([.text("B")]) { enteredB.fulfill(); await gateB.wait(); return textResponse(request, "B") }
            return textResponse(request, "A2")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let a = agent.makeSession(), b = agent.makeSession()
        let firstA = try await a.run("A"), firstB = try await b.run("B")
        #expect(await XCTWaiter.fulfillment(of: [enteredA, enteredB], timeout: 1) == .completed)
        await firstA.cancel()
        await #expect(throws: CancellationError.self) { try await firstA.wait() }
        let nextA = try await a.run("A2")
        _ = try await nextA.wait()
        await gateB.open()
        #expect(try await firstB.wait().outcome == .completed)
        await gateA.open()
        #expect(await a.history == [.user([.text("A")]), .user([.text("A2")]), .assistant(content: [.text("A2")], toolCalls: [])])
        #expect(await b.history == [.user([.text("B")]), .assistant(content: [.text("B")], toolCalls: [])])
    }

    @Test func multipleWaitersShareOutcomeAndCancellingOneDoesNotAffectOthers() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "Provider entered")
        let waiting = XCTestExpectation(description: "Waiters entered")
        waiting.expectedFulfillmentCount = 3
        let provider = ScriptedProvider { request, _ in entered.fulfill(); await gate.wait(); return textResponse(request, "Done") }
        let run = try await Agent(model: fixtureModel, provider: provider).makeSession().run("work")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        let a = Task { waiting.fulfill(); return try await run.wait() }
        let b = Task { waiting.fulfill(); return try await run.wait() }
        let c = Task { waiting.fulfill(); return try await run.wait() }
        #expect(await XCTWaiter.fulfillment(of: [waiting], timeout: 1) == .completed)
        a.cancel()
        await #expect(throws: CancellationError.self) { try await a.value }
        await gate.open()
        let resultB = try await b.value, resultC = try await c.value
        #expect(resultB == resultC)
        #expect(resultB.outcome == .completed)
        #expect(try await run.wait() == resultB)
    }
}
