import AgentDecisions
import AgentJevProvider
import AgentModels
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import AgentJevProvider

struct JevDecisionProviderTests {
    @Test func encodesVerifiedSystemOneContractAndDecodesTypedAnswers() async throws {
        let probe = JevRequestProbe()
        let transport = FixtureJevTransport(probe: probe, responses: [.success(.init(
            status: 200,
            headers: ["x-typesafe-request-id": "req-1"],
            body: Data(#"""
            {
              "model":"jev-2026-09-15",
              "answers":{
                "billing":{"type":"noul","noul":0.98,"extension":"ignored"},
                "tone":{"type":"choice","choice":"angry","confidence":0.9,"probabilities":{"calm":0.1,"angry":0.9}},
                "urgency":{"type":"score","score":1.7,"confidence":0.8,"legend":{"0":"Can wait","1":"This week","2":"Today"},"probabilities":{"0":0.1,"1":0.1,"2":0.8}}
              },
              "usage":{"input_tokens":120,"output_tokens":12,"future":1},
              "future":"ignored"
            }
            """#.utf8)
        ))])
        let provider = try JevDecisionProvider(apiKey: "secret-key", transport: transport)
        let response = try await provider.decide(try request(scoreCriteria: [
            .string("Can wait"), .string("This week"), .string("Today"),
        ]))

        #expect(response.model == "jev-2026-09-15")
        #expect(response.nouls["billing"]?.probability == 0.98)
        #expect(response.choices["tone"]?.selected == "angry")
        #expect(response.choices["tone"]?.probabilities.map(\.name) == ["calm", "angry"])
        #expect(response.scores["urgency"]?.score == 1.7)
        #expect(response.scores["urgency"]?.probabilities == [0.1, 0.1, 0.8])
        #expect(response.usage == .init(inputTokens: 120, outputTokens: 12))

        let sent = try #require(await probe.requests.first)
        #expect(sent.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer secret-key")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(sent.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "jev-latest")
        let questions = try #require(json["questions"] as? [String: Any])
        #expect(Set(questions.keys) == ["billing", "tone", "urgency"])
    }

    @Test(arguments: invalidResponses)
    func invalidResponseFailsClosed(_ fixture: InvalidResponseFixture) async throws {
        let provider = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: JevRequestProbe(), responses: [.success(.init(status: 200, headers: [:], body: Data(fixture.body.utf8)))]
        ))
        do {
            _ = try await provider.decide(try request())
            Issue.record("Expected invalid response for \(fixture.name)")
        } catch {
            #expect((error as? DecisionProviderError)?.kind == .invalidResponse)
        }
    }

    @Test func mapsHTTPAndTransportFailuresWithoutLeakingSecretsOrBodies() async throws {
        let cases: [(Int, DecisionProviderError.Kind, [String: String])] = [
            (401, .authentication, [:]),
            (403, .permissionDenied, [:]),
            (422, .invalidRequest, [:]),
            (429, .rateLimited, ["Retry-After": "7", "x-typesafe-request-id": "req-rate"]),
            (503, .unavailable, [:]),
        ]
        for (status, kind, headers) in cases {
            let provider = try JevDecisionProvider(apiKey: "secret", transport: FixtureJevTransport(
                probe: JevRequestProbe(), responses: [.success(.init(
                    status: status, headers: headers, body: Data("private payload secret".utf8)
                ))]
            ))
            do { _ = try await provider.decide(try request()); Issue.record("Expected HTTP failure") }
            catch {
                let failure = try #require(error as? DecisionProviderError)
                #expect(failure.kind == kind)
                #expect(!failure.message.contains("private"))
                #expect(!failure.message.contains("secret"))
                if status == 429 {
                    #expect(failure.retryAfter == .seconds(7))
                    #expect(failure.requestID == "req-rate")
                }
            }
        }

        let transport = FixtureJevTransport(
            probe: JevRequestProbe(), responses: [.failure(FixtureSensitiveError())]
        )
        let provider = try JevDecisionProvider(apiKey: "secret", transport: transport)
        do { _ = try await provider.decide(try request()); Issue.record("Expected transport failure") }
        catch {
            let failure = try #require(error as? DecisionProviderError)
            #expect(failure.kind == .transport)
            #expect(!failure.message.contains("fixture-secret"))
        }
    }

    @Test func exposesSafeRetryMetadataWithoutAutomaticallyRetrying() async throws {
        let probe = JevRequestProbe()
        let provider = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: probe,
            responses: [.success(.init(
                status: 429,
                headers: ["retry-after-ms": "1500.5", "x-typesafe-request-id": "req-2"],
                body: Data()
            ))]
        ))
        do {
            _ = try await provider.decide(try request())
            Issue.record("Expected rate limit")
        } catch {
            let failure = try #require(error as? DecisionProviderError)
            #expect(failure.kind == .rateLimited)
            #expect(failure.retryAfter == .milliseconds(1500.5))
            #expect(failure.requestID == "req-2")
        }
        #expect(await probe.requests.count == 1)

        let unsafe = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: JevRequestProbe(),
            responses: [.success(.init(
                status: 503,
                headers: ["x-typesafe-request-id": "forged\nheader"],
                body: Data()
            ))]
        ))
        do {
            _ = try await unsafe.decide(try request())
            Issue.record("Expected service failure")
        } catch {
            #expect((error as? DecisionProviderError)?.requestID == nil)
        }

        let dated = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: JevRequestProbe(),
            responses: [.success(.init(
                status: 429,
                headers: ["Retry-After": "Wed, 21 Oct 2099 07:28:00 GMT"],
                body: Data()
            ))]
        ))
        do {
            _ = try await dated.decide(try request())
            Issue.record("Expected rate limit")
        } catch {
            #expect(try #require((error as? DecisionProviderError)?.retryAfter) > .seconds(0))
        }
    }

    @Test(arguments: [
        ["retry-after-ms": "1e30"],
        ["Retry-After": "1e300"],
        ["Retry-After": "0x1p1000"],
    ])
    func oversizedRetryMetadataIsIgnoredWithoutCrashing(_ headers: [String: String]) async throws {
        let probe = JevRequestProbe()
        let provider = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: probe,
            responses: [.success(.init(status: 429, headers: headers, body: Data()))]
        ))

        do {
            _ = try await provider.decide(try request())
            Issue.record("Expected rate limit")
        } catch {
            let failure = try #require(error as? DecisionProviderError)
            #expect(failure.kind == .rateLimited)
            #expect(failure.retryAfter == nil)
        }
        #expect(await probe.requests.count == 1)
    }

    @Test func invalidConfigurationAndUnsupportedJevStateFailBeforeNetworking() async throws {
        #expect(throws: DecisionProviderError.self) { try JevDecisionProvider(apiKey: "") }
        #expect(throws: DecisionProviderError.self) {
            try JevDecisionProvider(apiKey: "key", endpoint: URL(string: "http://example.com/v1/systemone")!)
        }
        let probe = JevRequestProbe()
        let provider = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: probe, responses: []
        ))
        for state in [JSONValue.null, .bool(true), .number(1)] {
            do {
                _ = try await provider.decide(try .init(state: state, nouls: ["q": .init()]))
                Issue.record("Unsupported state must fail")
            } catch { #expect((error as? DecisionProviderError)?.kind == .invalidRequest) }
        }
        do {
            _ = try await provider.decide(try .init(
                state: .string("state"), nouls: ["q": .init(instructions: .number(1))]
            ))
            Issue.record("Unsupported instructions must fail")
        } catch { #expect((error as? DecisionProviderError)?.kind == .invalidRequest) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func publicDescriptionsAndReflectionDoNotExposeTheAPIKey() throws {
        let provider = try JevDecisionProvider(apiKey: "fixture-super-secret")

        #expect(String(describing: provider) == "JevDecisionProvider")
        #expect(String(reflecting: provider) == "JevDecisionProvider")
        #expect(!provider.customMirror.children.contains { child in
            String(describing: child.value).contains("fixture-super-secret")
        })
    }

    @Test func callerCancellationWinsAndLateTransportCompletionCannotReturnAResult() async throws {
        let gate = JevTransportGate()
        let provider = try JevDecisionProvider(apiKey: "key", transport: GateJevTransport(gate: gate))
        let task = Task { try await provider.decide(try request()) }
        await gate.waitUntilEntered()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await gate.release(.init(status: 200, headers: [:], body: Self.validBody))
        #expect(await gate.callCount == 1)
    }

    @Test func expiredDeadlineDoesNotStartTransport() async throws {
        let probe = JevRequestProbe()
        let provider = try JevDecisionProvider(apiKey: "key", transport: FixtureJevTransport(
            probe: probe, responses: []
        ))
        do {
            _ = try await provider.decide(try request(deadline: .now))
            Issue.record("Expired deadline must fail")
        } catch { #expect((error as? DecisionProviderError)?.kind == .deadlineExceeded) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func activeDeadlineFailsOnceAndLateTransportCompletionCannotReturnAResult() async throws {
        let gate = JevTransportGate()
        let provider = try JevDecisionProvider(apiKey: "key", transport: GateJevTransport(gate: gate))
        let task = Task {
            try await provider.decide(try request(deadline: .now.advanced(by: .milliseconds(50))))
        }
        await gate.waitUntilEntered()

        do {
            _ = try await task.value
            Issue.record("The active transport must not outlive the request deadline")
        } catch {
            #expect((error as? DecisionProviderError)?.kind == .deadlineExceeded)
        }

        await gate.release(.init(status: 200, headers: [:], body: Self.validBody))
        #expect(await gate.callCount == 1)
    }

    private func request(
        deadline: ContinuousClock.Instant? = nil,
        scoreCriteria: [JSONValue] = [.string("Can wait"), .string("Today")]
    ) throws -> DecisionRequest {
        try DecisionRequest(
            state: .object(["message": .string("I was charged twice")]),
            nouls: ["billing": .init(instructions: .string("Is this billing?"))],
            choices: ["tone": try .init(criteria: [
                .init(name: "calm", description: .string("Neutral")),
                .init(name: "angry", description: .string("Upset")),
            ])],
            scores: ["urgency": try .init(criteria: scoreCriteria)],
            deadline: deadline
        )
    }

    private static let validBody = Data(#"""
    {
      "model":"jev-latest",
      "answers":{
        "billing":{"type":"noul","noul":0.8},
        "tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},
        "urgency":{"type":"score","score":1.0,"confidence":0.7,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.2,"1":0.8}}
      },
      "usage":{"input_tokens":1,"output_tokens":1}
    }
    """#.utf8)

    private static let invalidResponses: [InvalidResponseFixture] = [
        .init(name: "missing answer", body: #"{"model":"jev","answers":{},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "unknown answer", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}},"extra":{"type":"noul","noul":1}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "kind mismatch", body: #"{"model":"jev","answers":{"billing":{"type":"choice","choice":"x","confidence":1,"probabilities":{"x":1}},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "unknown choice", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"future","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "missing choice probability", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":1}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "out of range", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":2},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "choice confidence out of range", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":2,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "score out of range", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":2,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "missing score probability", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":1}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "duplicate normalized score index", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","00":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "legend mismatch", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Different","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "unsafe model metadata", body: #"{"model":"jev\nforged","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":1,"output_tokens":1}}"#),
        .init(name: "negative usage", body: #"{"model":"jev","answers":{"billing":{"type":"noul","noul":0.8},"tone":{"type":"choice","choice":"calm","confidence":0.8,"probabilities":{"calm":0.8,"angry":0.2}},"urgency":{"type":"score","score":1,"confidence":1,"legend":{"0":"Can wait","1":"Today"},"probabilities":{"0":0.5,"1":0.5}}},"usage":{"input_tokens":-1,"output_tokens":1}}"#),
        .init(name: "malformed JSON", body: "{")
    ]
}

struct InvalidResponseFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let body: String
    var testDescription: String { name }
}

private struct FixtureSensitiveError: Error, CustomStringConvertible {
    var description: String { "fixture-secret private endpoint" }
}

private actor JevRequestProbe {
    private(set) var requests: [URLRequest] = []
    func record(_ request: URLRequest) { requests.append(request) }
}

private struct FixtureJevTransport: JevHTTPTransport {
    let probe: JevRequestProbe
    let responses: [Result<JevHTTPResponse, Error>]

    func send(_ request: URLRequest) async throws -> JevHTTPResponse {
        await probe.record(request)
        guard let response = responses.first else { throw FixtureSensitiveError() }
        return try response.get()
    }
}

private actor JevTransportGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var response: JevHTTPResponse?
    private var responseWaiters: [CheckedContinuation<JevHTTPResponse, Never>] = []
    private(set) var callCount = 0

    func wait() async -> JevHTTPResponse {
        callCount += 1
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if let response { return response }
        return await withCheckedContinuation { responseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release(_ response: JevHTTPResponse) {
        self.response = response
        let waiters = responseWaiters
        responseWaiters.removeAll()
        waiters.forEach { $0.resume(returning: response) }
    }
}

private struct GateJevTransport: JevHTTPTransport {
    let gate: JevTransportGate
    func send(_ request: URLRequest) async throws -> JevHTTPResponse { await gate.wait() }
}
