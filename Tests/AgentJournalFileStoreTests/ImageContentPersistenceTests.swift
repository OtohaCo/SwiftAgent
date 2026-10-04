import AgentCore
import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing

/// Format schema 10: images kept once by digest beside the journal's records (ADR 0012).
struct ImageContentPersistenceTests {
    private static func image(_ seed: UInt8, padding: Int = 3_000) throws -> ModelImage {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data.append(contentsOf: Array("IHDR".utf8))
        data.append(contentsOf: [0, 0, 0, 32, 0, 0, 0, 24, 8, 2, 0, 0, 0, seed, 0, 0, 0])
        data.append(Data((0..<padding).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) }))
        return try ModelImage(data: data, description: "Frame \(seed)")
    }

    private static func run(_ journal: AgentJournal, session: UUID, images: [ModelImage]) async throws {
        let provider = ImageProvider()
        let binding = try AgentModelBinding(profileID: "p", profileRevision: "1", model: .init(provider: "fixture", name: "m"),
            provider: provider, deployment: .init(serviceInstanceID: "s", endpointScope: "e", apiDialect: "d"),
            imageInput: .native())
        let agent = try Agent(model: .init(provider: "fixture", name: "m"), provider: provider, tools: [FrameTool(images: images)])
        let run = try await agent.makeSession(id: session, journal: journal).run("Look", using: binding)
        _ = try await run.wait()
        try await run.waitForDrain()
    }

    private static func imageFiles(_ directory: URL) -> [URL] {
        (FileManager.default.enumerator(at: directory.appendingPathComponent("images"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }) ?? []
    }

    @Test func anImageStoreIsSchemaTenAndImpliesRunRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "format", supportsImageContent: true)
        let format = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("format.json"))) as! [String: Any]
        #expect(format["schema"] as? Int == 10)
        #expect(journal.supportsImageContent && journal.supportsRunRecords && journal.supportsPerCallFollowUps)
        try await journal.close()
        let reopened = try AgentIncrementalJournal.open(at: directory)
        #expect(reopened.supportsImageContent)
        try await reopened.close()
    }

    @Test func theSameImageIsKeptOnceAndSurvivesMaintenance() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-maintain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = try JournalMaintenancePolicy(segmentBytes: 1024, maxWorkBytes: 8192, maxUnreclaimedBytes: 32768)
        let first = try Self.image(1), second = try Self.image(2)
        let session = UUID()
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "images", policy: policy, supportsImageContent: true)
        try await Self.run(journal, session: session, images: [first, second])
        try await Self.run(journal, session: session, images: [first])
        for _ in 0..<8 { _ = try await journal.requestMaintenance() }
        try await journal.close()
        #expect(Self.imageFiles(directory).count == 2)

        let reopened = try AgentIncrementalJournal.open(at: directory, policy: policy)
        let images = try await reopened.readMessages(sessionID: session).flatMap(\.message.images)
        #expect(images.map(\.digest) == [first.digest, second.digest, first.digest])
        #expect(images.map(\.data) == [first.data, second.data, first.data])
        try await reopened.close()
    }

    @Test func aChangedImageFileIsNotReadAsTheImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("image-damage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID()
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "images", supportsImageContent: true)
        try await Self.run(journal, session: session, images: [try Self.image(3)])
        try await journal.close()
        let file = try #require(Self.imageFiles(directory).first)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: file)
        let reopened = try AgentIncrementalJournal.open(at: directory)
        await #expect(throws: AgentJournalError.checksumMismatch) {
            _ = try await reopened.readMessages(sessionID: session)
        }
        try await reopened.close()
    }
}

private struct FrameTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let frames: Int }
    static let name = "frames"
    static let description = "Video frames"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.object(properties: ["frames": .integer], required: ["frames"])
    let images: [ModelImage]
    let policy = try! ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                 timeout: .seconds(2), authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(frames: images.count), images: images)
    }
}

private actor TurnCounter {
    private var turns = 0
    func next() -> Int { turns += 1; return turns }
}

private struct ImageProvider: ModelProvider {
    let descriptor = ModelProviderDescriptor(id: "fixture", capabilities: [.streaming, .multiTurn, .tools, .imageInput])
    let counter = TurnCounter()
    func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        ModelEventStream.make { emit in
            let info = ResponseInfo(id: "r", model: request.model)
            try emit(.responseStarted(info))
            if await counter.next() == 1 {
                let call = ToolCall(id: .init(rawValue: "frames-\(UUID().uuidString.prefix(8))"), name: FrameTool.name,
                                    argumentsJSON: "{}", completeness: .complete)
                try emit(.toolCallStarted(call.id, name: call.name))
                try emit(.toolCallArgumentsDelta(call.id, call.argumentsJSON))
                try emit(.toolCallCompleted(call))
                try emit(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            } else {
                try emit(.textDelta("ok"))
                try emit(.responseCompleted(.init(info: info, content: [.text("ok")], stopReason: .endTurn)))
            }
        }
    }
}
