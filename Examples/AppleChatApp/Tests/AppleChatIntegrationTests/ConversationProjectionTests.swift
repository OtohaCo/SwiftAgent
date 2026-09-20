@testable import AppleChatIntegration
import AgentCore
import AgentModels
import AgentUsage
import Foundation
import Testing

struct ConversationProjectionTests {
    @Test func completedResponseDoesNotDuplicateStreamedText() throws {
        let conversationID = UUID()
        let runID = UUID()
        let model = ModelID(provider: "apple-chat-fixture", name: "streaming")
        let info = ResponseInfo(id: "response-1", model: model)
        var projection = ConversationProjection(conversationID: conversationID)

        projection.beginUserTurn("Hello", generation: 1)
        projection.apply(.runStarted(.init(sessionID: conversationID, runID: runID, model: model)))
        projection.apply(.turnStarted(1))
        projection.apply(.model(.responseStarted(info)))
        projection.apply(.model(.textDelta("Hello")))
        projection.apply(.model(.textDelta(" from SwiftAgent")))
        projection.apply(.model(.responseCompleted(.init(
            info: info,
            content: [.text("Hello from SwiftAgent")],
            usage: .init(inputTokens: 4, outputTokens: 3),
            stopReason: .endTurn
        ))))
        projection.setTerminal(.completed)

        let snapshot = projection.snapshot
        let assistant = try #require(snapshot.items.compactMap(\.assistant).first)
        #expect(assistant.text == "Hello from SwiftAgent")
        #expect(assistant.responseID == "response-1")
        #expect(assistant.usage == .init(inputTokens: 4, outputTokens: 3))
        #expect(snapshot.terminal == .completed)
    }

    @Test func sparseUsageSnapshotsDoNotErasePreviouslyReportedFields() throws {
        let conversationID = UUID()
        let model = ModelID(provider: "apple-chat-fixture", name: "streaming")
        var projection = ConversationProjection(conversationID: conversationID)

        projection.beginUserTurn("Hello", generation: 1)
        projection.apply(.runStarted(.init(sessionID: conversationID, runID: UUID(), model: model)))
        projection.apply(.turnStarted(1))
        projection.apply(.model(.usage(.init(inputTokens: 10, outputTokens: 2))))
        projection.apply(.model(.usage(.init(outputTokens: 5))))

        let assistant = try #require(projection.snapshot.items.compactMap(\.assistant).first)
        #expect(assistant.usage.inputTokens == 10)
        #expect(assistant.usage.outputTokens == 5)
    }

    @Test func toolCallsStayKeyedByCallIdentityAndExposeRecoverableErrors() throws {
        let conversationID = UUID()
        let model = ModelID(provider: "apple-chat-fixture", name: "streaming")
        let info = ResponseInfo(id: "response-tools", model: model)
        let firstID = ToolCallID(rawValue: "call-first")
        let secondID = ToolCallID(rawValue: "call-second")
        var projection = ConversationProjection(conversationID: conversationID)

        projection.beginUserTurn("Look up both accounts", generation: 1)
        projection.apply(.runStarted(.init(sessionID: conversationID, runID: UUID(), model: model)))
        projection.apply(.turnStarted(1))
        projection.apply(.model(.responseStarted(info)))
        projection.apply(.model(.toolCallStarted(firstID, name: "lookup_account")))
        projection.apply(.model(.toolCallStarted(secondID, name: "lookup_account")))
        projection.apply(.toolStarted(.init(
            id: secondID, name: "lookup_account", argumentsJSON: #"{"id":"missing"}"#, completeness: .complete
        )))
        projection.apply(.toolStarted(.init(
            id: firstID, name: "lookup_account", argumentsJSON: #"{"id":"A-100"}"#, completeness: .complete
        )))
        projection.apply(.toolCompleted(.init(
            callID: secondID,
            content: [.json(.object(["code": .string("not_found")]))],
            isError: true
        )))
        projection.apply(.toolCompleted(.init(
            callID: firstID,
            content: [.json(.object(["status": .string("active")]))],
            isError: false
        )))

        let tools = projection.snapshot.items.compactMap(\.tool)
        #expect(tools.map(\.id) == [firstID, secondID])
        #expect(tools.first(where: { $0.id == firstID })?.state == .completed)
        #expect(tools.first(where: { $0.id == firstID })?.isError == false)
        #expect(tools.first(where: { $0.id == secondID })?.state == .completed)
        #expect(tools.first(where: { $0.id == secondID })?.isError == true)
    }

    @Test func terminalOutcomesRemainDistinct() {
        let conversationID = UUID()
        let model = ModelID(provider: "apple-chat-fixture", name: "streaming")
        var projection = ConversationProjection(conversationID: conversationID)

        projection.beginUserTurn("Continue", generation: 1)
        projection.apply(.runStarted(.init(sessionID: conversationID, runID: UUID(), model: model)))
        projection.setTerminal(.incomplete(.maxOutputTokens))

        #expect(projection.snapshot.terminal == .incomplete(.maxOutputTokens))

        projection.apply(.runFinished(.failed(.provider(.init(
            kind: .invalidResponse,
            message: "sanitized"
        )))))
        #expect(projection.snapshot.terminal == .failed(.provider(.init(
            kind: .invalidResponse,
            message: "sanitized"
        ))))

        projection.apply(.runFinished(.cancelled))
        #expect(projection.snapshot.terminal == .cancelled)
    }

    @Test func boundedSnapshotMailboxKeepsTheNewestCompleteSnapshot() async throws {
        let conversationID = UUID()
        let mailbox = ConversationSnapshotMailbox(
            initial: .init(conversationID: conversationID),
            bufferingLimit: 1
        )

        mailbox.send(.init(conversationID: conversationID, generation: 1, phase: .starting))
        mailbox.send(.init(conversationID: conversationID, generation: 2, phase: .running))
        mailbox.send(.init(conversationID: conversationID, generation: 3, phase: .draining))

        var iterator = mailbox.snapshots.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.generation == 3)
        #expect(received?.phase == .draining)
    }
}

private extension ConversationItem {
    var assistant: DisplayAssistantTurn? {
        guard case .assistant(let value) = self else { return nil }
        return value
    }

    var tool: DisplayToolCall? {
        guard case .tool(let value) = self else { return nil }
        return value
    }
}
