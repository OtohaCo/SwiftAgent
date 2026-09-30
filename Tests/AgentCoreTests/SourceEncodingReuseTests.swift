import AgentCore
import AgentModels
import Foundation
import Testing

struct SourceEncodingReuseTests {
    @Test func identityRequestEncodesItsSourceOnceWithoutSkippingIndependentValidation() async throws {
        let counts = MessageEncodingCounts()
        try await AgentContextEncodingObservation.$didEncode.withValue({ kind, bytes in counts.record(kind, bytes) }) {
            let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
            let session = try Agent(model: fixtureModel, provider: provider).makeSession()
            let run = try await session.run("source")
            _ = try await run.wait(); try await run.waitForDrain()
            #expect(await provider.log.requests.first?.messages == [.user([.text("source")])])
        }
        #expect(counts.snapshot.sourceEncodes == 1)
        #expect(counts.snapshot.projectionEncodes == 0)
    }

    @Test(arguments: ["forward", "legacy-digest", "rebuilt", "shorten", "enlarge"])
    func differentProjectorPathsCountActualBuffersAndMeasureTheirOutput(_ kind: String) async throws {
        let counts = MessageEncodingCounts()
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let input = kind == "shorten" ? String(repeating: "source", count: 100) : "source"
        let output = kind == "shorten" ? "short" : String(repeating: "large", count: 100)
        let projected = kind == "shorten" || kind == "enlarge"
        let estimator = SourceTokenEstimator()
        let session = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(contextPolicy: .init(maxModelContextUTF8Bytes: 128))).makeSession()
        let binding = try AgentModelBinding(profileID: kind, profileRevision: "1", model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: SourceVariantProjector(kind: kind, output: output),
            tokenBudget: .init(maximumContextTokens: 1_000, reservedOutputTokens: 10, estimator: estimator))
        try await AgentContextEncodingObservation.$didEncode.withValue({ kind, bytes in counts.record(kind, bytes) }) {
            if kind == "enlarge" {
                await #expect(throws: AgentContextError.self) { try await session.run(input, using: binding) }
            } else {
                let run = try await session.run(input, using: binding)
                _ = try await run.wait(); try await run.waitForDrain()
            }
        }
        #expect(counts.snapshot.sourceEncodes == (kind == "legacy-digest" ? 2 : 1))
        #expect(counts.snapshot.projectionEncodes == (projected || kind == "rebuilt" ? 1 : 0))
        if kind == "enlarge" {
            #expect(await provider.log.requests.isEmpty)
            #expect(await session.history.isEmpty)
            #expect(await estimator.inputs.isEmpty)
        } else {
            let expected: [ModelMessage] = [.user([.text(kind == "shorten" ? output : input)])]
            #expect(await provider.log.requests.first?.messages == expected)
            #expect(await estimator.inputs.first == expected)
            #expect(await session.history.first == .user([.text(input)]))
        }
    }

    @Test func canonicallyEqualUnicodeProjectionStillUsesItsActualEncodedSize() async throws {
        let source: [ModelMessage] = [.user([.text("é")])]
        let changed: [ModelMessage] = [.user([.text("e\u{301}")])]
        #expect(source == changed) // Swift String equality is canonically equivalent.
        let sourceBytes = try JSONEncoder().encode(source).count
        let changedBytes = try JSONEncoder().encode(changed).count
        #expect(changedBytes > sourceBytes)
        let provider = ScriptedProvider { request, _ in textResponse(request, "unused") }
        let session = try Agent(model: fixtureModel, provider: provider,
            configuration: .init(contextPolicy: .init(maxModelContextUTF8Bytes: sourceBytes))).makeSession()
        let binding = try AgentModelBinding(profileID: "unicode", profileRevision: "1", model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"),
            projector: SourceVariantProjector(kind: "shorten", output: "e\u{301}"))
        await #expect(throws: AgentContextError.historyTooLarge(bytes: changedBytes, limit: sourceBytes)) {
            try await session.run("é", using: binding)
        }
        #expect(await provider.log.requests.isEmpty)
    }

    @Test func cachedInputHasTheSameCodableAndHashIdentityAndDecodingDoesNotRestoreTheCache() async throws {
        let capture = SourceCaptureProjector()
        let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
        let session = try Agent(model: fixtureModel, provider: provider).makeSession()
        let binding = try AgentModelBinding(profileID: "capture", profileRevision: "1", model: fixtureModel, provider: provider,
            deployment: .init(serviceInstanceID: "fixture", endpointScope: "local", apiDialect: "fixture"), projector: capture)
        let run = try await session.run("source", using: binding)
        _ = try await run.wait(); try await run.waitForDrain()
        let input = try #require(await capture.input)
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(AgentContextProjectionInput.self, from: data)
        #expect(input == decoded)
        #expect(Set([input, decoded]).count == 1)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(keys.count == 9)
        #expect(keys["sourceEncoding"] == nil)
        let counts = MessageEncodingCounts()
        try AgentContextEncodingObservation.$didEncode.withValue({ kind, bytes in counts.record(kind, bytes) }) {
            let original = try input.sourceDigest(), reconstructed = try decoded.sourceDigest()
            #expect(original == reconstructed)
        }
        #expect(counts.snapshot.sourceEncodes == 1) // Only the decoded input recomputes.
    }

    @Test func eachRunAndSessionOwnsANewSourceSnapshot() async throws {
        let counts = MessageEncodingCounts()
        try await AgentContextEncodingObservation.$didEncode.withValue({ kind, bytes in counts.record(kind, bytes) }) {
            let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
            let sessions = try ["instructions-a", "instructions-b"].map {
                try Agent(model: fixtureModel, provider: provider, instructions: $0).makeSession()
            }
            for text in ["first", "second"] {
                for session in sessions {
                    let run = try await session.run(text)
                    _ = try await run.wait(); try await run.waitForDrain()
                }
            }
            let requests = await provider.log.requests
            #expect(requests.count == 4)
            #expect(requests[0].messages.first == .system("instructions-a"))
            #expect(requests[1].messages.first == .system("instructions-b"))
            #expect(requests[2].messages.last == .user([.text("second")]))
            #expect(requests[2].messages.contains(.user([.text("first")])))
        }
        #expect(counts.snapshot.sourceEncodes == 4)
        #expect(counts.snapshot.projectionEncodes == 0)
    }

    @Test func measureActualSourcePreparation() async throws {
        guard ProcessInfo.processInfo.environment["SWIFTAGENT_SOURCE_MEASUREMENT"] == "1" else { return }
        for count in [500, 1_000, 2_000] {
            for sample in 0..<5 {
                let history: [ModelMessage] = (0..<count).map { index in
                    let text = "message-\(index) " + String(repeating: "h", count: 2_000)
                    return index.isMultiple(of: 2) ? .user([.text(text)]) : .assistant(content: [.text(text)], toolCalls: [])
                }
                let journal = AgentJournal()
                let sessionID = UUID()
                _ = try await journal.appendCheckpoint([.checkpoint(history: history, steeringIDs: [])], sessionID: sessionID)
                let counts = MessageEncodingCounts()
                let start = ContinuousClock.now
                try await AgentContextEncodingObservation.$didEncode.withValue({ kind, bytes in counts.record(kind, bytes) }) {
                    let provider = ScriptedProvider { request, _ in textResponse(request, "done") }
                    let session = try Agent(model: fixtureModel, provider: provider).makeSession(id: sessionID, journal: journal)
                    let run = try await session.run("next")
                    _ = try await run.wait(); try await run.waitForDrain()
                    #expect(await provider.log.requests.first?.messages == history + [.user([.text("next")])])
                }
                let duration = start.duration(to: .now).components
                let elapsed = Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
                let row = counts.snapshot
                print("SOURCE_MEASUREMENT " + String(decoding: try JSONSerialization.data(withJSONObject: [
                    "historyMessages": count, "sample": sample, "sourceEncodes": row.sourceEncodes,
                    "projectionEncodes": row.projectionEncodes, "allocatedEncodingBuffers": row.sourceEncodes + row.projectionEncodes,
                    "encodedBufferBytes": row.bytes, "maxBufferBytes": row.maxBytes, "elapsedMilliseconds": elapsed,
                    "note": "Actual Session/request preparation + fixture Provider + physical drain; buffer allocations, not total malloc; OS cache uncontrolled"
                ], options: [.sortedKeys]), as: UTF8.self))
            }
        }
    }
}

private struct SourceVariantProjector: AgentContextProjector {
    let kind: String, output: String
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        if kind == "forward" { return try await AgentIdentityContextProjector().project(input) }
        let digest = kind == "legacy-digest" ? try AgentContextProjectionSource.digest(messages: input.canonicalMessages) : try input.sourceDigest()
        let messages = kind == "shorten" || kind == "enlarge" ? [.user([.text(output)])]
            : kind == "rebuilt" ? input.canonicalMessages.map { $0 } : input.canonicalMessages
        return .init(messages: messages, plan: .init(projectionID: kind, version: "1",
            sourceRevision: input.conversationRevision, sourceDigest: digest,
            contextEpoch: input.contextEpoch, lossy: kind == "shorten" || kind == "enlarge"))
    }
}

private actor SourceCaptureProjector: AgentContextProjector {
    private(set) var input: AgentContextProjectionInput?
    func project(_ input: AgentContextProjectionInput) async throws -> AgentContextProjection {
        self.input = input
        return try await AgentIdentityContextProjector().project(input)
    }
}

private actor SourceTokenEstimator: AgentContextTokenEstimator {
    private(set) var inputs: [[ModelMessage]] = []
    func estimate(_ input: AgentContextTokenEstimationInput) async throws -> AgentContextTokenEstimate {
        inputs.append(input.messages)
        return .init(inputTokens: 1, accuracy: .estimated)
    }
}

private final class MessageEncodingCounts: @unchecked Sendable {
    struct Snapshot { var sourceEncodes = 0, projectionEncodes = 0, bytes = 0, maxBytes = 0 }
    private let lock = NSLock()
    private var value = Snapshot()
    func record(_ kind: String, _ bytes: Int) {
        lock.withLock {
            if kind == "source" { value.sourceEncodes += 1 } else { value.projectionEncodes += 1 }
            value.bytes += bytes; value.maxBytes = max(value.maxBytes, bytes)
        }
    }
    var snapshot: Snapshot { lock.withLock { value } }
}
