import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

/// OAI-1521: a tool result larger than its tool's limit is cut before it is committed, with a notice the
/// model can read, so one oversized result can no longer make every later request too large.
@Suite(.manualClock) struct AgentToolResultLimitTests {
    @Test func anOversizedResultIsCutAndTheConversationGoesOn() async throws {
        let text = String(repeating: "a", count: 3 * 1024 * 1024)
        let provider = ScriptedProvider { request, turn in
            if case .tool = request.messages.last { return textResponse(request, "read it") }
            return toolResponse(request, [.init(id: .init(rawValue: "big-\(turn)"), name: LargeOutputTool.name,
                                                argumentsJSON: "{}", completeness: .complete)])
        }
        let session = try Agent(model: fixtureModel, provider: provider, tools: [try LargeOutputTool(text: text)],
            configuration: .init(contextPolicy: .init(maxModelContextUTF8Bytes: 2 * 1024 * 1024))).makeSession()
        #expect(try await session.run("Read").wait().outcome == .completed)
        let second = try #require(await provider.log.requests.last)
        let result = try #require(lastToolResult(second.messages))
        let notice = try #require(cutNotice(result))
        #expect(notice.originalBytes == text.utf8.count + 2)
        let bytes = try encodedBytes(result)
        #expect(bytes <= AgentToolResultLimit.defaultBytes)
        #expect(notice.notice.contains("\(AgentToolResultLimit.defaultBytes)"))
        #expect(notice.partial.hasPrefix("\"aaaa"))
        #expect(!result.isError)
        // A later Run of the same conversation is not stopped by the earlier result.
        #expect(try await session.run("Again").wait().outcome == .completed)
    }

    @Test func aToolCanSetASmallerLimit() async throws {
        let text = String(repeating: "\"", count: 20_000)
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [.init(id: .init(rawValue: "quotes"), name: LargeOutputTool.name,
                                                     argumentsJSON: "{}", completeness: .complete)])
                : textResponse(request, "ok")
        }
        _ = try await Agent(model: fixtureModel, provider: provider,
                            tools: [try LargeOutputTool(text: text, limit: 8192)]).makeSession().run("Read").wait()
        let result = try #require(lastToolResult(await provider.log.requests.last?.messages ?? []))
        let notice = try #require(cutNotice(result))
        // Every quote needs escaping twice once cut text is wrapped; the whole result still fits.
        let bytes = try encodedBytes(result)
        #expect(bytes <= 8192)
        #expect(notice.keptBytes > 0 && notice.keptBytes < 8192)
        #expect(notice.notice.contains("8192"))
    }

    @Test func aResultWithinTheLimitIsUnchanged() async throws {
        let provider = ScriptedProvider { request, turn in
            turn == 1 ? toolResponse(request, [.init(id: .init(rawValue: "small"), name: LargeOutputTool.name,
                                                     argumentsJSON: "{}", completeness: .complete)])
                : textResponse(request, "ok")
        }
        _ = try await Agent(model: fixtureModel, provider: provider,
                            tools: [try LargeOutputTool(text: "small", limit: 8192)]).makeSession().run("Read").wait()
        let result = try #require(lastToolResult(await provider.log.requests.last?.messages ?? []))
        #expect(result.content == [.json(.string("small"))])
    }

    @Test func aLimitTooSmallForTheNoticeIsRejected() throws {
        #expect(throws: ToolInvocationError.invalidDefinition) {
            _ = try Agent(model: fixtureModel, provider: ScriptedProvider { request, _ in textResponse(request, "") },
                          tools: [try LargeOutputTool(text: "", limit: 100)])
        }
    }

    @Test func anOversizedMutationResultSettlesWithTheCutOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swift-agent-result-limit-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(atPath: url.path + ".lock")
        }
        let journal = try makeTestJournal(at: url)
        let provider = ScriptedProvider { request, turn in
            request.messages.last?.role != .tool ? toolResponse(request, [.init(id: .init(rawValue: "write-\(turn)"), name: LargeOutputTool.name,
                                                     argumentsJSON: "{}", completeness: .complete)])
                : textResponse(request, "ok")
        }
        let session = try Agent(model: fixtureModel, provider: provider,
            tools: [try LargeOutputTool(text: String(repeating: "b", count: 50_000), limit: 8192, mutation: true)])
            .makeSession(journal: journal)
        let run = try await session.run("Write", operationID: "big-write")
        let result = try await run.wait()
        try await run.waitForDrain()
        #expect(result.receipts.count == 1)
        #expect(try await journal.pendingMutations().isEmpty)
        let checkpoint = try await journal.latestCheckpoint(sessionID: session.id)
        let committed = try #require(lastToolResult(checkpoint?.history ?? []))
        let committedBytes = try encodedBytes(committed)
        #expect(cutNotice(committed) != nil && committedBytes <= 8192)
        let retry = try await session.run("Retry", operationID: "big-write")
        let replay = try await retry.wait()
        try await retry.waitForDrain()
        #expect(replay.outcome == .completed)
        #expect(replay.receipts.count == 1)
        let replayed = try #require(lastToolResult(await session.history))
        #expect(replayed.content == committed.content)
        try await journal.close()
    }
}

private struct LargeOutputTool: AgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    static let name = "large_output"
    static let description = "Returns a large text"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.string
    let text: String
    let policy: ToolPolicy
    let maximumResultBytes: Int

    init(text: String, limit: Int = AgentToolResultLimit.defaultBytes, mutation: Bool = false) throws {
        self.text = text
        maximumResultBytes = limit
        policy = mutation
            ? try .mutation(idempotency: .requiresReceipt, timeout: .seconds(5), authorization: .notRequired, evidence: .none)
            : try .readOnly(timeout: .seconds(5), authorization: .notRequired)
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        policy.effect == .mutation ? try .init(targets: [.init(namespace: "fixture", id: "doc")], revision: .present) : nil
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<String> {
        guard policy.effect == .mutation else { return ToolResult(output: text) }
        return ToolResult(output: text, receipt: ToolReceipt(operationID: context.idempotencyKey ?? "missing", status: .succeeded,
            confirmedTargets: [.init(namespace: "fixture", id: "doc")], revision: "1"))
    }
}

private func lastToolResult(_ messages: [ModelMessage]) -> ToolResultMessage? {
    messages.reversed().lazy.compactMap { message -> ToolResultMessage? in
        if case .tool(let result) = message { return result }
        return nil
    }.first
}

private struct CutNotice { let originalBytes: Int; let keptBytes: Int; let notice: String; let partial: String }

private func cutNotice(_ result: ToolResultMessage) -> CutNotice? {
    guard case .json(.object(let fields))? = result.content.first, fields["truncated"] == .bool(true),
          case .number(let original)? = fields["original_bytes"], case .number(let kept)? = fields["kept_bytes"],
          case .string(let notice)? = fields["notice"], case .string(let partial)? = fields["partial_json"] else { return nil }
    return CutNotice(originalBytes: NSDecimalNumber(decimal: original).intValue, keptBytes: NSDecimalNumber(decimal: kept).intValue, notice: notice, partial: partial)
}

private func encodedBytes(_ result: ToolResultMessage) throws -> Int {
    guard case .json(let value)? = result.content.first else { return 0 }
    return try JSONEncoder().encode(value).count
}
