import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
import XCTest

struct AgentSessionTests {
    @Test func sequentialRunsReuseSessionHistoryAndAgentInstructions() async throws {
        let provider = ScriptedProvider { request, turn in textResponse(request, "answer \(turn)") }
        let agent = try Agent(model: fixtureModel, provider: provider, instructions: "Be precise.")
        let session = agent.makeSession()
        let first = try await session.run("first")
        let result = try await first.wait()
        #expect(result.history == [.system("Be precise."), .user([.text("first")]), .assistant(content: [.text("answer 1")], toolCalls: [])])
        #expect(await session.history == result.history)
        let second = try await session.run("second")
        _ = try await second.wait()
        #expect(first.id != second.id)
        #expect(first.sessionID == second.sessionID)
        let requests = await provider.log.requests
        try #require(requests.count == 2)
        #expect(requests[1].messages == result.history + [.user([.text("second")])])
        let events = await collectEvents(first.events)
        guard case .runFinished(.result(let observed)) = events.last else { Issue.record("Missing terminal"); return }
        #expect(observed == result)
    }

    @Test func sameSessionRejectsConflictWhileOtherSessionsContinue() async throws {
        let gate = ManualGate()
        let entered = XCTestExpectation(description: "A entered")
        let provider = ScriptedProvider { request, _ in
            if request.messages == [.user([.text("A")])] { entered.fulfill(); await gate.wait() }
            return textResponse(request, "Done")
        }
        let agent = try Agent(model: fixtureModel, provider: provider)
        let a = agent.makeSession(), b = agent.makeSession()
        let first = try await a.run("A")
        #expect(await XCTWaiter.fulfillment(of: [entered], timeout: 1) == .completed)
        await #expect(throws: AgentSessionError.runInProgress) { try await a.run("conflict") }
        #expect(await a.history == [.user([.text("A")])])
        let other = try await b.run("B")
        #expect(try await other.wait().history == [.user([.text("B")]), .assistant(content: [.text("Done")], toolCalls: [])])
        await gate.open()
        _ = try await first.wait()
        #expect(a.id != b.id)
    }

    @Test func emptyInputDoesNotCreateARunOrPolluteHistory() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Unexpected") }
        let agent = try Agent(model: fixtureModel, provider: provider, instructions: "System")
        for text in ["", " \n"] {
            let session = agent.makeSession()
            await #expect(throws: AgentSessionError.emptyInput) { try await session.run(text) }
            #expect(await session.history == [.system("System")])
        }
    }

    @Test func terminalEventMeansHistoryCommittedAndSessionReleased() async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "Done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let run = try await session.run("first")
        for await event in run.events {
            if case .runFinished(.result(let result)) = event {
                #expect(await session.history == result.history)
                #expect(await session.activeRunID == nil)
                let next = try await session.run("next")
                _ = try await next.wait()
            }
        }
    }

    @Test func failedSecondToolPreservesCompletedPairWithoutDanglingProposals() async throws {
        let good = addition("good")
        let bad = ToolCall(id: .init(rawValue: "overflow"), name: "add",
                           argumentsJSON: "{\"lhs\":\(Int.max),\"rhs\":1}", completeness: .complete)
        let provider = ScriptedProvider { request, _ in toolResponse(request, [good, bad]) }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [AddTool(log: EffectLog())]).makeSession()
        let run = try await session.run("compute")
        await #expect(throws: FixtureError.self) { try await run.wait() }
        #expect(await session.history == [.user([.text("compute")]), .assistant(content: [], toolCalls: [good]),
            .tool(.init(callID: good.id, content: [.json(.object(["sum": .number(5)]))], isError: false))])
        #expect(await session.activeRunID == nil)
    }
}
