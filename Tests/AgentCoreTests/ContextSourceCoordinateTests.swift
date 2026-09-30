import AgentCore
import AgentJournalFileStore
import AgentModels
import Foundation
import Testing

struct ContextSourceCoordinateTests {
    @Test(arguments: [false, true]) func committedToolSourcesUseTheActualSessionRevision(_ durable: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = durable ? try AgentIncrementalJournal.create(at: directory, operationDomain: "coordinates") : AgentJournal()
        let recorder = CoordinateRecorder()
        let provider = ScriptedProvider { request, turn in
            if turn.isMultiple(of: 2) { return textResponse(request, "done") }
            let calls = ["a", "b"].map { name in
                ToolCall(id: .init(rawValue: "\(name)-\(turn)"), name: "add", argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)
            }
            return toolResponse(request, calls)
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: EffectLog())]).makeSession(journal: journal)
        await recorder.attach(session)
        let binding = try AgentModelBinding(profileID: "coordinates", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: recorder)
        for input in ["first", "second"] {
            let run = try await session.run(input, using: binding)
            _ = try await run.wait(); try await run.waitForDrain()
        }
        let rows = await recorder.rows
        #expect(rows.count == 4)
        // The candidate preflight contains an uncommitted user input.
        #expect(rows[0].revision == rows[0].sessionRevision + 1)
        #expect(rows[2].revision == rows[2].sessionRevision + 1)
        for row in [rows[1], rows[3]] {
            #expect(row.messagesMatch)
            #expect(row.revision == row.sessionRevision)
        }
        #expect(rows[1].epoch == rows[0].epoch + 1)
        #expect(rows[1].revision != rows[1].epoch)
        try await journal.close()
    }

    @Test(arguments: ["revision", "digest", "epoch"]) func wrongSourceCoordinatesRemainRejected(_ corrupted: String) async throws {
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(profileID: "invalid", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: InvalidCoordinateProjector(corrupted: corrupted))
        await #expect(throws: AgentModelBindingError.invalidProjection) { try await session.run("not admitted", using: binding) }
        #expect(await provider.log.requests.isEmpty)
        #expect(await session.history.isEmpty)
    }

    @Test func nextCandidateAfterAMixedCompletedFailedBatchUsesItsCommittedPrefix() async throws {
        let recorder = CoordinateRecorder()
        let completed = ToolCall(id: .init(rawValue: "completed"), name: "add",
            argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)
        let failed = ToolCall(id: .init(rawValue: "failed"), name: "add",
            argumentsJSON: "{\"lhs\":\(Int.max),\"rhs\":1}", completeness: .complete)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [completed, failed]) : textResponse(request, "done")
        }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try AddTool(log: EffectLog(), execution: .sequential)]).makeSession()
        await recorder.attach(session)
        let binding = try AgentModelBinding(profileID: "partial", profileRevision: "1", model: fixtureModel,
            provider: provider, deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"), projector: recorder)
        let run = try await session.run("partial", using: binding)
        await #expect(throws: FixtureError.invalidOperation) { try await run.wait() }
        try await run.waitForDrain()
        let committed = try await session.conversationSnapshot()
        #expect(committed.messages.contains(.assistant(content: [], toolCalls: [completed])))
        #expect(!committed.messages.contains { if case .tool(let result) = $0 { return result.callID == failed.id }; return false })
        let next = try await session.run("continue", using: binding)
        _ = try await next.wait(); try await next.waitForDrain()
        let rows = await recorder.rows
        #expect(rows.count == 2)
        #expect(rows[1].sessionRevision == committed.revision)
        #expect(rows[1].revision == committed.revision + 1)
        let request = try #require(await provider.log.requests.last)
        #expect(request.messages == committed.messages + [.user([.text("continue")])])
    }
}

private struct InvalidCoordinateProjector: AgentContextProjector {
    let corrupted: String
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let identity = try await AgentIdentityContextProjector().project(input)
        return .init(messages: identity.messages, plan: .init(projectionID: "invalid", version: "1",
            sourceRevision: input.conversationRevision + (corrupted == "revision" ? 1 : 0),
            sourceDigest: corrupted == "digest" ? "forged" : identity.plan.sourceDigest,
            contextEpoch: input.contextEpoch + (corrupted == "epoch" ? 1 : 0), lossy: false))
    }
}

private actor CoordinateRecorder: AgentContextProjector {
    struct Row: Sendable {
        let revision: UInt64, epoch: UInt64, sessionRevision: UInt64
        let messagesMatch: Bool
    }
    private var session: AgentSession?
    private(set) var rows: [Row] = []
    func attach(_ session: AgentSession) { self.session = session }
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let snapshot = try await session!.conversationSnapshot()
        rows.append(.init(revision: input.conversationRevision, epoch: input.contextEpoch,
            sessionRevision: snapshot.revision, messagesMatch: snapshot.messages == input.canonicalMessages))
        return try await AgentIdentityContextProjector().project(input)
    }
}
