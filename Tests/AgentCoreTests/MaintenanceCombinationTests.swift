import AgentCore
import AgentModels
import Foundation
import Testing

// Validation-only integration candidate: no additional SDK behavior.
struct MaintenanceCombinationTests {
    @Test func latestMemoryStateCommittedRevisionEpochAndTrustedCacheCoexist() async throws {
        let journal = AgentJournal()
        let provider = ScriptedProvider { request, turn in
            if turn.isMultiple(of: 2) { return textResponse(request, "done") }
            return toolResponse(request, ["a", "b"].map {
                ToolCall(id: .init(rawValue: "\($0)-\(turn)"), name: "add",
                         argumentsJSON: #"{"lhs":1,"rhs":2}"#, completeness: .complete)
            })
        }
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [try AddTool(log: EffectLog())])
        var sessions: [AgentSession] = []
        var recorders: [CombinationSourceRecorder] = []
        for _ in 0..<2 {
            let session = try agent.makeSession(journal: journal)
            sessions.append(session); recorders.append(CombinationSourceRecorder(session: session))
        }
        for text in ["first", "second"] {
            for (session, recorder) in zip(sessions, recorders) {
                let binding = try AgentModelBinding(profileID: "combined", profileRevision: "1",
                    model: fixtureModel, provider: provider,
                    deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
                    projector: recorder)
                let run = try await session.run(text, using: binding)
                _ = try await run.wait(); try await run.waitForDrain()
            }
        }
        for (session, recorder) in zip(sessions, recorders) {
            let rows = await recorder.rows
            #expect(rows.count == 4)
            for index in [0, 2] { #expect(rows[index].revision == rows[index].sessionRevision + 1) }
            for index in [1, 3] {
                #expect(rows[index].revision == rows[index].sessionRevision)
                #expect(rows[index].messagesMatch)
                #expect(rows[index].epoch == rows[index-1].epoch + 1)
            }
            #expect(rows[1].revision != rows[1].epoch)
            #expect(rows.allSatisfy { $0.getterEncodes == 0 })
            let snapshot = try await session.conversationSnapshot()
            #expect(try await journal.latestCheckpoint(sessionID: session.id)?.history == snapshot.messages)
            let restored = try agent.makeSession(id: session.id, journal: journal)
            #expect(try await restored.conversationSnapshot().messages == snapshot.messages)
        }
        let retained = await journal.memoryRetentionStatistics()
        #expect(retained.checkpointArrays == 2)
        #expect(retained.runIdentities == 4)
        #expect(retained.messageSlots == 20)
        print("COMBINATION_SOURCE memoryArrays=2 messageSlots=20 runIdentities=4 exactRevision=true independentEpoch=true cachedGetterEncodes=0 restoredHistory=true")
    }
}

private actor CombinationSourceRecorder: AgentContextProjector {
    struct Row: Sendable {
        let revision: UInt64, epoch: UInt64, sessionRevision: UInt64
        let messagesMatch: Bool
        let getterEncodes: Int
    }
    let session: AgentSession
    private(set) var rows: [Row] = []
    init(session: AgentSession) { self.session = session }
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        let snapshot = try await session.conversationSnapshot()
        let counter = CombinationCounter()
        let digest = try AgentContextEncodingObservation.$didEncode.withValue({ _, _ in counter.record() }) {
            let first = try input.sourceDigest()
            #expect(try input.sourceDigest() == first)
            return first
        }
        rows.append(.init(revision: input.conversationRevision, epoch: input.contextEpoch,
            sessionRevision: snapshot.revision, messagesMatch: snapshot.messages == input.canonicalMessages,
            getterEncodes: counter.count))
        return .init(messages: input.canonicalMessages, plan: .init(projectionID: "combined", version: "1",
            sourceRevision: input.conversationRevision, sourceDigest: digest, contextEpoch: input.contextEpoch, lossy: false))
    }
}
private final class CombinationCounter: @unchecked Sendable {
    let lock = NSLock()
    private var value = 0
    func record() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
