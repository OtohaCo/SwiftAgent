import AgentJournalFileStore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentCore

/// Images returned by tools (ADR 0012): what the model is sent, what the Run refuses, what the journal keeps.
struct ImageContentRunTests {
    static func png(width: Int = 64, height: Int = 48, padding: Int = 0, seed: UInt8 = 0) throws -> ModelImage {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13])
        data.append(contentsOf: Array("IHDR".utf8))
        for value in [width, height] { data.append(contentsOf: [0, 0, UInt8(value >> 8), UInt8(value & 0xFF)]) }
        data.append(contentsOf: [8, 2, 0, 0, 0, seed, 0, 0, 0])
        data.append(Data((0..<padding).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }))
        return try ModelImage(data: data, description: "Frame \(seed) of the exported video")
    }

    private static let call = ToolCall(id: .init(rawValue: "shot-1"), name: ScreenshotTool.name,
                                       argumentsJSON: "{}", completeness: .complete)

    private static func provider(images: Bool = true, failSecondTurn: Bool = false) -> ScriptedProvider {
        var capabilities: ModelCapabilities = [.streaming, .multiTurn, .tools]
        if images { capabilities.insert(.imageInput) }
        return ScriptedProvider(descriptor: .init(id: "fixture", capabilities: capabilities)) { request, turn in
            if turn == 1 { return toolResponse(request, [call]) }
            if failSecondTurn { throw ModelProviderError(kind: .unavailable, message: "fixture outage") }
            return textResponse(request, "The frame shows the settings window.")
        }
    }

    private static func binding(_ provider: ScriptedProvider, _ policy: AgentImageInputPolicy,
                                budget: AgentContextTokenBudget? = nil) throws -> AgentModelBinding {
        try AgentModelBinding(profileID: "vision", profileRevision: "1", model: fixtureModel, provider: provider,
                              deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
                              tokenBudget: budget, imageInput: policy)
    }

    private static func toolMessage(_ request: ModelRequest?) -> ToolResultMessage? {
        request?.messages.lazy.compactMap { if case .tool(let result) = $0 { result } else { nil } }.first
    }

    @Test func aModelThatSeesImagesIsSentTheToolsImageAfterItsOutput() async throws {
        let image = try Self.png()
        let provider = Self.provider()
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [image])]).makeSession()
        let result = try await session.run("Look", using: Self.binding(provider, .native())).wait()
        #expect(result.response.content == [.text("The frame shows the settings window.")])
        let sent = try #require(Self.toolMessage(await provider.log.requests.last))
        #expect(sent.content == [.json(.object(["window": .string("Settings")])), .image(image)])
        guard case .image(let back) = sent.content.last else { Issue.record("No image"); return }
        #expect(back.data == image.data)
    }

    @Test func aModelThatDoesNotSeeImagesReadsTheirTextAndTheReplySucceeds() async throws {
        let image = try Self.png()
        let provider = Self.provider(images: false)
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [image])]).makeSession()
        let result = try await session.run("Look", using: Self.binding(provider, .describe)).wait()
        #expect(result.response.content == [.text("The frame shows the settings window.")])
        let sent = try #require(Self.toolMessage(await provider.log.requests.last))
        #expect(sent.content == [.json(.object(["window": .string("Settings")])), .text(image.textSubstitute)])
        // The conversation keeps the image itself; only the request was described.
        #expect(result.history.contains { $0.images == [image] })
    }

    @Test func withoutAnImageChoiceTheRunFailsBeforeSendingTheImage() async throws {
        let provider = Self.provider()
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [try Self.png()])]).makeSession()
        await #expect(throws: AgentLoopError.unsupportedCapabilities(.imageInput)) {
            _ = try await session.run("Look").wait()
        }
        #expect(await provider.log.requests.count == 1)
    }

    @Test func sendingImagesThroughAnAdapterThatCannotFailsBeforeDispatch() async throws {
        let provider = Self.provider(images: false)
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [try Self.png()])]).makeSession()
        await #expect(throws: AgentLoopError.unsupportedCapabilities(.imageInput)) {
            _ = try await session.run("Look", using: Self.binding(provider, .native())).wait()
        }
        #expect(await provider.log.requests.count == 1)
    }

    @Test func onlyTheNewestImagesUpToTheRequestLimitAreSent() async throws {
        let images = try (1...3).map { try Self.png(seed: UInt8($0)) }
        let provider = Self.provider()
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: images)]).makeSession()
        _ = try await session.run("Look", using: Self.binding(provider, .native(maximumImagesPerRequest: 2))).wait()
        let sent = try #require(Self.toolMessage(await provider.log.requests.last))
        #expect(sent.content == [.json(.object(["window": .string("Settings")])),
                                 .text(images[0].textSubstitute), .image(images[1]), .image(images[2])])
    }

    @Test func theImageLimitPerRequestIsBounded() {
        #expect(throws: AgentModelBindingError.self) { try AgentImageInputPolicy.native(maximumImagesPerRequest: 0) }
        #expect(throws: AgentModelBindingError.self) { try AgentImageInputPolicy.native(maximumImagesPerRequest: 101) }
    }

    @Test func aToolReturningTooManyImagesFails() async throws {
        let images = try (0...ModelImage.maximumImagesPerMessage).map { try Self.png(seed: UInt8($0)) }
        let provider = Self.provider()
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: images)]).makeSession()
        await #expect(throws: ModelImageError.tooManyImages(count: images.count, limit: ModelImage.maximumImagesPerMessage)) {
            _ = try await session.run("Look", using: Self.binding(provider, .native())).wait()
        }
        #expect(await provider.log.requests.count == 1)
    }

    @Test func tokenEstimationCountsImagesAndRequestBytesCountThemByReference() async throws {
        let image = try Self.png(width: 1920, height: 1080, padding: 200_000)
        let provider = Self.provider()
        let estimator = ImageEstimateLog()
        let budget = try AgentContextTokenBudget(maximumContextTokens: 100_000, reservedOutputTokens: 1_000, estimator: estimator)
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [image])],
                              configuration: .init(contextPolicy: .init(maxModelContextUTF8Bytes: 64 * 1024)))
        _ = try await agent.makeSession().run("Look", using: Self.binding(provider, .native(), budget: budget)).wait()
        #expect(await estimator.imageTokens.last == image.estimatedInputTokens)
        #expect(image.estimatedInputTokens > 1_000)

        let tight = try AgentContextTokenBudget(maximumContextTokens: image.estimatedInputTokens + 1_000,
                                                reservedOutputTokens: 1_000, estimator: estimator)
        let again = Self.provider()
        let failing = try Agent(model: fixtureModel, provider: again, tools: [ScreenshotTool(images: [image])]).makeSession()
        await #expect(throws: AgentModelBindingError.self) {
            _ = try await failing.run("Look", using: Self.binding(again, .native(), budget: tight)).wait()
        }
        #expect(await again.log.requests.count == 1)
    }

    @Test func aDurableJournalKeepsImagesByDigestAndAResumedConversationGetsThemBack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftAgent-image-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try Self.png(padding: 4_096)
        let sessionID = UUID()
        do {
            let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "images", supportsImageContent: true)
            #expect(journal.supportsImageContent)
            let failing = Self.provider(failSecondTurn: true)
            let session = try Agent(model: fixtureModel, provider: failing, tools: [ScreenshotTool(images: [image])])
                .makeSession(id: sessionID, journal: journal)
            // The Run stops after the tool's result is kept: it is unfinished from the model's view.
            let run = try await session.run("Look", using: Self.binding(failing, .native()))
            await #expect(throws: ModelProviderError.self) { _ = try await run.wait() }
            try await run.waitForDrain()
            try await journal.close()
        }

        // Bytes live once, by digest, outside the journal's records.
        let files = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath })
        let imageFiles = files.filter { $0.path.contains("/images/") }
        #expect(imageFiles.count == 1)
        #expect(imageFiles.first?.lastPathComponent.contains(image.digest) == true)
        let marker = image.data.suffix(64)
        let base64 = image.data.base64EncodedString()
        for file in files where !file.path.contains("/images/") {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.range(of: marker) == nil, "image bytes inside \(file.lastPathComponent)")
            #expect(String(decoding: bytes, as: UTF8.self).range(of: String(base64.prefix(256))) == nil,
                    "base64 image inside \(file.lastPathComponent)")
        }

        let reopened = try AgentIncrementalJournal.open(at: directory)
        let stored = try await reopened.readMessages(sessionID: sessionID)
        #expect(stored.flatMap(\.message.images).map(\.data) == [image.data])
        let resumedProvider = ScriptedProvider(descriptor: Self.provider().descriptor) { request, _ in
            textResponse(request, "Seen")
        }
        let resumed = try Agent(model: fixtureModel, provider: resumedProvider, tools: [ScreenshotTool(images: [image])])
            .makeSession(id: sessionID, journal: reopened)
        let next = try await resumed.run("Go on", using: Self.binding(resumedProvider, .native()))
        _ = try await next.wait()
        try await next.waitForDrain()
        let sent = try #require(Self.toolMessage(await resumedProvider.log.requests.first))
        guard case .image(let back) = sent.content.last else { Issue.record("No image after resume"); return }
        #expect(back.data == image.data)
        #expect(back.digest == image.digest)
        try await reopened.close()
    }

    @Test func aJournalCreatedWithoutImageSupportRefusesImagesExplicitly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftAgent-image-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "images", supportsRunRecords: true)
        #expect(!journal.supportsImageContent)
        #expect(AgentJournal().supportsImageContent)
        let provider = Self.provider()
        let session = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [try Self.png()])])
            .makeSession(journal: journal)
        let run = try await session.run("Look", using: Self.binding(provider, .native()))
        await #expect(throws: AgentJournalError.unsupportedFormat) { _ = try await run.wait() }
        try await run.waitForDrain()
        try await journal.close()
    }

    @Test func auditExportCarriesImageDigestsOnly() async throws {
        let directory = auditTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try Self.png(padding: 2_048)
        let journal = try AgentIncrementalJournal.create(at: directory, operationDomain: "images", supportsImageContent: true)
        let provider = Self.provider()
        let agent = try Agent(model: fixtureModel, provider: provider, tools: [ScreenshotTool(images: [image])],
                              configuration: .init(authorization: auditTestConfiguration()))
        let run = try await agent.makeSession(journal: journal).run("Look", using: Self.binding(provider, .native()))
        _ = try await run.wait()
        try await run.waitForDrain()
        let sink = ExportTestSink()
        let exporter = try await journal.startAuditExporter(configuration: .init(id: "images", destinationID: "fixture",
            contentVersion: "1", redactionVersion: "1"), sink: sink)
        try await exporter.waitForDrain()
        let exported = await sink.jsonl.joined(separator: "\n")
        #expect(exported.contains(image.digest))
        #expect(!exported.contains(String(image.data.base64EncodedString().prefix(64))))
        try await journal.close()
    }
}

struct ScreenshotTool: AgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let window: String }
    static let name = "screenshot"
    static let description = "Take a screenshot"
    static let inputSchema = ToolSchema.object(properties: [:])
    static let outputSchema = ToolSchema.object(properties: ["window": .string], required: ["window"])
    let images: [ModelImage]
    let policy = try! ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe,
                                 timeout: .seconds(2), authorization: .notRequired)
    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(window: "Settings"), images: images)
    }
}

private actor ImageEstimateLog: AgentContextTokenEstimator {
    private(set) var imageTokens: [Int] = []
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        imageTokens.append(input.imageInputTokens)
        let encoder = JSONEncoder()
        encoder.userInfo[ModelImage.referenceOnlyEncoding] = true
        let text = try encoder.encode(input.messages).count / 4
        return .init(inputTokens: text + input.imageInputTokens, accuracy: .estimated)
    }
}
