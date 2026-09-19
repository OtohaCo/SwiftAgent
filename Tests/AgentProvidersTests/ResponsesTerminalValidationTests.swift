import AgentCore
import AgentModels
import AgentTools
import Foundation
import Testing
@testable import AgentProviders

struct ResponsesTerminalValidationTests {
    @Test(arguments: terminalStatusCases)
    func terminalItemStatusMatrix(testCase: TerminalStatusCase) async throws {
        let body = try terminalFixture(testCase)
        do {
            var accumulator = ModelEventAccumulator()
            for try await event in try provider(for: testCase.vendor, body: body).stream(
                request: request(for: testCase.vendor)
            ) {
                try accumulator.append(event)
            }
            _ = try accumulator.finish()
            #expect(testCase.expectedAccepted)
        } catch let error as ModelProviderError {
            #expect(!testCase.expectedAccepted)
            #expect(error.kind == .invalidResponse)
        }
    }

    @Test(arguments: [TerminalVendor.openAI, .deepSeek])
    func invalidFunctionTerminalNeverReachesAgentExecutor(vendor: TerminalVendor) async throws {
        let testCase = TerminalStatusCase(
            vendor: vendor,
            itemKind: .functionCall,
            stage: .responseFinal,
            status: .unknown,
            expectedAccepted: false
        )
        let execution = ProviderExecutionProbe()
        let agent = try Agent(
            model: request(for: vendor).model,
            provider: try provider(for: vendor, body: terminalFixture(testCase)),
            tools: [try ProviderCalculator(probe: execution)]
        )

        await #expect(throws: (any Error).self) {
            _ = try await agent.makeSession().run("Add 2 and 3").wait()
        }
        #expect(await execution.count == 0)
    }

    @Test(arguments: [TerminalVendor.openAI, .deepSeek])
    func completedFunctionTerminalExecutesExactlyOnce(vendor: TerminalVendor) async throws {
        let execution = ProviderExecutionProbe()
        let provider = try provider(
            for: vendor,
            bodies: [
                terminalFixture(.init(
                    vendor: vendor,
                    itemKind: .functionCall,
                    stage: .responseFinal,
                    status: .legal,
                    expectedAccepted: true
                )),
                terminalTextFixture(vendor),
            ]
        )
        let result = try await Agent(
            model: request(for: vendor).model,
            provider: provider,
            tools: [try ProviderCalculator(probe: execution)]
        ).makeSession().run("Add 2 and 3").wait()

        #expect(result.outcome == .completed)
        #expect(await execution.count == 1)
    }
}

enum TerminalVendor: String, Sendable {
    case openAI
    case deepSeek
}

enum TerminalItemKind: String, Sendable {
    case message
    case reasoning
    case functionCall
}

enum TerminalStage: String, Sendable {
    case itemAdded
    case itemDone
    case responseFinal
}

enum TerminalStatus: String, Sendable {
    case legal
    case missing
    case null
    case unknown
}

struct TerminalStatusCase: Sendable, CustomStringConvertible {
    let vendor: TerminalVendor
    let itemKind: TerminalItemKind
    let stage: TerminalStage
    let status: TerminalStatus
    let expectedAccepted: Bool

    var description: String {
        "\(vendor.rawValue)-\(itemKind.rawValue)-\(stage.rawValue)-\(status.rawValue)"
    }
}

private let terminalStatusCases: [TerminalStatusCase] = {
    var result: [TerminalStatusCase] = []
    for vendor in [TerminalVendor.openAI, .deepSeek] {
        for kind in [TerminalItemKind.message, .reasoning, .functionCall] {
            for stage in [TerminalStage.itemAdded, .itemDone, .responseFinal] {
                for status in [TerminalStatus.legal, .missing, .null, .unknown] {
                    let missingAccepted = vendor == .deepSeek || kind != .message
                    let nullAccepted = vendor == .openAI && kind != .message
                    let accepted: Bool
                    switch status {
                    case .legal: accepted = true
                    case .missing: accepted = missingAccepted
                    case .null: accepted = nullAccepted
                    case .unknown: accepted = false
                    }
                    result.append(.init(
                        vendor: vendor,
                        itemKind: kind,
                        stage: stage,
                        status: status,
                        expectedAccepted: accepted
                    ))
                }
            }
        }
    }
    return result
}()

private func provider(for vendor: TerminalVendor, body: Data) throws -> any ModelProvider {
    try provider(for: vendor, bodies: [body])
}

private func provider(for vendor: TerminalVendor, bodies: [Data]) throws -> any ModelProvider {
    let transport = FixtureHTTPTransport(probe: ProviderRequestProbe(), bodies: bodies)
    switch vendor {
    case .openAI:
        return try OpenAIResponsesProvider(apiKey: "fixture-key", transport: transport)
    case .deepSeek:
        return try DeepSeekResponsesProvider(
            apiKey: "fixture-key",
            reasoningEffort: .none,
            transport: transport
        )
    }
}

private func request(for vendor: TerminalVendor) -> ModelRequest {
    let model: ModelID = switch vendor {
    case .openAI: .init(provider: "openai", name: "fixture")
    case .deepSeek: .init(provider: "deepseek", name: "deepseek-flash")
    }
    return .init(model: model, messages: [.user([.text("Test")])])
}

private func terminalFixture(_ testCase: TerminalStatusCase) throws -> Data {
    let responseID = "resp-terminal"
    let model = testCase.vendor == .openAI ? "fixture" : "deepseek-flash"
    let itemID = switch testCase.itemKind {
    case .message: "msg-1"
    case .reasoning: "rs-1"
    case .functionCall: "fc-1"
    }
    var frames: [(String, String)] = [
        ("response.created", try encoded([
            "type": .string("response.created"),
            "response": .object([
                "id": .string(responseID), "model": .string(model), "status": .string("in_progress"),
            ]),
        ])),
    ]

    var added = initialItem(vendor: testCase.vendor, kind: testCase.itemKind, id: itemID)
    applyStatus(
        testCase.stage == .itemAdded ? testCase.status : .legal,
        expected: "in_progress",
        to: &added
    )
    frames.append(("response.output_item.added", try encoded([
        "type": .string("response.output_item.added"),
        "output_index": .number(0),
        "item": .object(added),
    ])))

    switch testCase.itemKind {
    case .message:
        frames.append(("response.content_part.added", try encoded([
            "type": .string("response.content_part.added"), "item_id": .string(itemID),
            "output_index": .number(0), "content_index": .number(0),
            "part": .object(["type": .string("output_text"), "text": .string(""), "annotations": .array([])]),
        ])))
        frames.append(("response.output_text.delta", try encoded([
            "type": .string("response.output_text.delta"), "item_id": .string(itemID),
            "output_index": .number(0), "content_index": .number(0), "delta": .string("Hello"),
        ])))
    case .reasoning:
        if testCase.vendor == .openAI {
            frames.append(("response.reasoning_summary_part.added", try encoded([
                "type": .string("response.reasoning_summary_part.added"), "item_id": .string(itemID),
                "output_index": .number(0), "summary_index": .number(0),
                "part": .object(["type": .string("summary_text"), "text": .string("")]),
            ])))
            frames.append(("response.reasoning_summary_text.delta", try encoded([
                "type": .string("response.reasoning_summary_text.delta"), "item_id": .string(itemID),
                "output_index": .number(0), "summary_index": .number(0), "delta": .string("Considered."),
            ])))
        } else {
            frames.append(("response.content_part.added", try encoded([
                "type": .string("response.content_part.added"), "item_id": .string(itemID),
                "output_index": .number(0), "content_index": .number(0),
                "part": .object(["type": .string("reasoning_text"), "text": .string("")]),
            ])))
            frames.append(("response.reasoning_text.delta", try encoded([
                "type": .string("response.reasoning_text.delta"), "item_id": .string(itemID),
                "output_index": .number(0), "content_index": .number(0), "delta": .string("Considered."),
            ])))
        }
    case .functionCall:
        frames.append(("response.function_call_arguments.delta", try encoded([
            "type": .string("response.function_call_arguments.delta"), "item_id": .string(itemID),
            "output_index": .number(0), "delta": .string(#"{"a":2,"b":3}"#),
        ])))
        frames.append(("response.function_call_arguments.done", try encoded([
            "type": .string("response.function_call_arguments.done"), "item_id": .string(itemID),
            "output_index": .number(0), "arguments": .string(#"{"a":2,"b":3}"#),
        ])))
    }

    var done = terminalItem(vendor: testCase.vendor, kind: testCase.itemKind, id: itemID)
    applyStatus(
        testCase.stage == .itemDone ? testCase.status : .legal,
        expected: "completed",
        to: &done
    )
    frames.append(("response.output_item.done", try encoded([
        "type": .string("response.output_item.done"),
        "output_index": .number(0),
        "item": .object(done),
    ])))

    var final = terminalItem(vendor: testCase.vendor, kind: testCase.itemKind, id: itemID)
    applyStatus(
        testCase.stage == .responseFinal ? testCase.status : .legal,
        expected: "completed",
        to: &final
    )
    frames.append(("response.completed", try encoded([
        "type": .string("response.completed"),
        "response": .object([
            "id": .string(responseID), "model": .string(model), "status": .string("completed"),
            "output": .array([.object(final)]),
            "usage": .object(["input_tokens": .number(1), "output_tokens": .number(1)]),
        ]),
    ])))
    return providerNamedSSE(frames)
}

private func initialItem(
    vendor: TerminalVendor,
    kind: TerminalItemKind,
    id: String
) -> [String: JSONValue] {
    switch kind {
    case .message:
        return [
            "id": .string(id), "type": .string("message"), "role": .string("assistant"),
            "status": .string("in_progress"), "content": .array([]),
        ]
    case .reasoning:
        if vendor == .openAI {
            return ["id": .string(id), "type": .string("reasoning"), "summary": .array([])]
        }
        return [
            "id": .string(id), "type": .string("reasoning"), "status": .string("in_progress"),
            "content": .array([]),
        ]
    case .functionCall:
        return [
            "id": .string(id), "type": .string("function_call"),
            "call_id": .string("call-1"), "name": .string("calculator"),
            "arguments": .string(""), "status": .string("in_progress"),
        ]
    }
}

private func terminalItem(
    vendor: TerminalVendor,
    kind: TerminalItemKind,
    id: String
) -> [String: JSONValue] {
    switch kind {
    case .message:
        return [
            "id": .string(id), "type": .string("message"), "role": .string("assistant"),
            "content": .array([.object([
                "type": .string("output_text"), "text": .string("Hello"), "annotations": .array([]),
            ])]),
        ]
    case .reasoning:
        if vendor == .openAI {
            return [
                "id": .string(id), "type": .string("reasoning"),
                "summary": .array([.object(["type": .string("summary_text"), "text": .string("Considered.")])]),
            ]
        }
        return [
            "id": .string(id), "type": .string("reasoning"),
            "content": .array([.object(["type": .string("reasoning_text"), "text": .string("Considered.")])]),
        ]
    case .functionCall:
        return [
            "id": .string(id), "type": .string("function_call"),
            "call_id": .string("call-1"), "name": .string("calculator"),
            "arguments": .string(#"{"a":2,"b":3}"#),
        ]
    }
}

private func applyStatus(
    _ status: TerminalStatus,
    expected: String,
    to item: inout [String: JSONValue]
) {
    switch status {
    case .legal: item["status"] = .string(expected)
    case .missing: item.removeValue(forKey: "status")
    case .null: item["status"] = .null
    case .unknown: item["status"] = .string("finalized")
    }
}

private func terminalTextFixture(_ vendor: TerminalVendor) -> Data {
    switch vendor {
    case .openAI:
        return openAITextFixture
    case .deepSeek:
        return providerNamedSSE([
            ("response.created", #"{"type":"response.created","response":{"id":"resp-text","model":"deepseek-flash","status":"in_progress"}}"#),
            ("response.output_item.added", #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"in_progress","content":[]}}"#),
            ("response.content_part.added", #"{"type":"response.content_part.added","item_id":"msg-1","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}"#),
            ("response.output_text.delta", #"{"type":"response.output_text.delta","item_id":"msg-1","output_index":0,"content_index":0,"delta":"Done"}"#),
            ("response.output_item.done", #"{"type":"response.output_item.done","output_index":0,"item":{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Done","annotations":[]}]}}"#),
            ("response.completed", #"{"type":"response.completed","response":{"id":"resp-text","model":"deepseek-flash","status":"completed","output":[{"id":"msg-1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Done","annotations":[]}]}],"usage":{"input_tokens":1,"output_tokens":1}}}"#),
        ])
    }
}

private func encoded(_ object: [String: JSONValue]) throws -> String {
    String(decoding: try JSONEncoder().encode(JSONValue.object(object)), as: UTF8.self)
}
