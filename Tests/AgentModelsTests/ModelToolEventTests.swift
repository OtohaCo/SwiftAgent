import AgentModels
import Foundation
import XCTest

final class ModelToolEventTests: XCTestCase {
    private let info = ResponseInfo(id: "tool-response", model: .init(provider: "fixture", name: "planner"))
    private let first = ToolCall(id: .init(rawValue: "search-1"), name: "search",
                                 argumentsJSON: #"{"query":"resources"}"#, completeness: .complete)
    private let second = ToolCall(id: .init(rawValue: "calc-2"), name: "calculator",
                                  argumentsJSON: #"{"a":2,"b":3}"#, completeness: .complete)

    func testInterleavedCallsRetainStartOrderInsteadOfCompletionOrder() throws {
        let expected = ModelResponse(info: info, content: [.text("Checking")],
                                     toolCalls: [first, second], stopReason: .toolCalls)
        let events: [ModelEvent] = [
            .responseStarted(info), .textDelta("Checking"),
            .toolCallStarted(first.id, name: first.name),
            .toolCallArgumentsDelta(first.id, #"{"query":"#),
            .toolCallStarted(second.id, name: second.name),
            .toolCallArgumentsDelta(second.id, second.argumentsJSON), .toolCallCompleted(second),
            .toolCallArgumentsDelta(first.id, #""resources"}"#), .toolCallCompleted(first),
            .responseCompleted(expected),
        ]
        let decoded = try JSONDecoder().decode([ModelEvent].self, from: JSONEncoder().encode(events))
        var accumulator = ModelEventAccumulator()
        for event in decoded { try accumulator.append(event) }
        let response = try accumulator.finish()
        XCTAssertEqual(response, expected)
        XCTAssertEqual(response.toolCalls.map(\.id.rawValue), ["search-1", "calc-2"])
    }

    func testRejectsContradictoryToolLifecycleAndIdentity() throws {
        let start = ModelEvent.toolCallStarted(first.id, name: first.name)
        let delta = ModelEvent.toolCallArgumentsDelta(first.id, first.argumentsJSON)
        let complete = ModelEvent.toolCallCompleted(first)
        let cases: [[ModelEvent]] = [
            [complete], [.toolCallArgumentsDelta(first.id, "{}")], [start, start],
            [start, delta, complete, complete], [start, delta, complete, delta],
            [start, delta, .toolCallCompleted(.init(id: first.id, name: "different", argumentsJSON: first.argumentsJSON, completeness: .complete))],
            [start, delta, .toolCallCompleted(.init(id: first.id, name: first.name, argumentsJSON: "{}", completeness: .complete))],
            [start, delta, .toolCallCompleted(.init(id: first.id, name: first.name, argumentsJSON: first.argumentsJSON))],
            [.toolCallStarted(.init(rawValue: " "), name: "search")],
            [.toolCallStarted(first.id, name: "\n")],
        ]
        for events in cases {
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            XCTAssertThrowsError(try events.forEach { try accumulator.append($0) }, "\(events)")
            XCTAssertThrowsError(try accumulator.finish())
        }
    }

    func testCompleteEventDoesNotBlessMalformedOrNonObjectArguments() throws {
        for raw in [#"{"query":"oops"#, "", "[]", "null", "12", #""string""#,
                    #"{"a":1,}"#, #"{"a":[1,]}"#, #"{"a":{"b":2, }}"#,
                    #"{"a":01}"#, #"{"a":+1}"#, #"{/*comment*/"a":1}"#] {
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            try accumulator.append(.toolCallStarted(first.id, name: first.name))
            try accumulator.append(.toolCallArgumentsDelta(first.id, raw))
            XCTAssertThrowsError(try accumulator.append(.toolCallCompleted(.init(
                id: first.id, name: first.name, argumentsJSON: raw, completeness: .complete
            ))), raw)
        }
    }

    func testToolStopRequiresNonemptyFullyCompletedBatch() throws {
        for raw in [#"{"query":"#, "{}"] {
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            try accumulator.append(.toolCallStarted(first.id, name: first.name))
            try accumulator.append(.toolCallArgumentsDelta(first.id, raw))
            let partial = ToolCall(id: first.id, name: first.name, argumentsJSON: raw)
            XCTAssertThrowsError(try accumulator.append(.responseCompleted(.init(
                info: info, toolCalls: [partial], stopReason: .toolCalls
            ))))
        }
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(info))
        XCTAssertThrowsError(try accumulator.append(.responseCompleted(.init(info: info, stopReason: .toolCalls))))
    }

    func testNormalTextStopCannotHideToolCalls() throws {
        for reason in [StopReason.endTurn, .stopSequence] {
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            try accumulator.append(.toolCallStarted(first.id, name: first.name))
            XCTAssertThrowsError(try accumulator.append(.responseCompleted(.init(
                info: info, toolCalls: [.init(id: first.id, name: first.name, argumentsJSON: "")], stopReason: reason
            ))))
        }
    }

    func testInterruptedResponsesPreservePartialCallWithoutPromotingCompleteness() throws {
        for reason in [StopReason.maxOutputTokens, .refusal, .cancelled, .unknown("interrupted")] {
            let partial = ToolCall(id: first.id, name: first.name, argumentsJSON: #"{"query":"#)
            let response = ModelResponse(info: info, toolCalls: [partial], stopReason: reason)
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            try accumulator.append(.toolCallStarted(first.id, name: first.name))
            try accumulator.append(.toolCallArgumentsDelta(first.id, partial.argumentsJSON))
            try accumulator.append(.responseCompleted(response))
            XCTAssertEqual(try accumulator.finish().toolCalls.first?.completeness, .incomplete)
            XCTAssertEqual(try accumulator.finish().stopReason, reason)
        }
    }

    func testInterruptedBatchRetainsCompletedAndIncompleteCalls() throws {
        let partial = ToolCall(id: second.id, name: second.name, argumentsJSON: "{")
        let response = ModelResponse(info: info, toolCalls: [first, partial], stopReason: .maxOutputTokens)
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(info))
        try accumulator.append(.toolCallStarted(first.id, name: first.name))
        try accumulator.append(.toolCallArgumentsDelta(first.id, first.argumentsJSON))
        try accumulator.append(.toolCallCompleted(first))
        try accumulator.append(.toolCallStarted(second.id, name: second.name))
        try accumulator.append(.toolCallArgumentsDelta(second.id, "{"))
        try accumulator.append(.responseCompleted(response))
        XCTAssertEqual(try accumulator.finish(), response)
    }

    func testTerminalCannotOmitReorderOrPromoteCalls() throws {
        let partial = ToolCall(id: second.id, name: second.name, argumentsJSON: second.argumentsJSON)
        for terminalCalls in [[first], [partial, first], [first, second]] {
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            try accumulator.append(.toolCallStarted(first.id, name: first.name))
            try accumulator.append(.toolCallArgumentsDelta(first.id, first.argumentsJSON))
            try accumulator.append(.toolCallCompleted(first))
            try accumulator.append(.toolCallStarted(second.id, name: second.name))
            try accumulator.append(.toolCallArgumentsDelta(second.id, second.argumentsJSON))
            XCTAssertThrowsError(try accumulator.append(.responseCompleted(.init(
                info: info, toolCalls: terminalCalls, stopReason: .maxOutputTokens
            )))) { error in
                XCTAssertEqual(error as? ModelStreamError, .responseMismatch)
            }
        }
    }

    func testCommaBracketsAndEscapesInsideStringsRemainValidArguments() throws {
        for text in [",}", ",]", "\\", "\"", "quoted \\\" ,} text", "\u{1F600}"] {
            let data = try JSONEncoder().encode(["text": text])
            let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
            let call = ToolCall(id: first.id, name: first.name, argumentsJSON: raw, completeness: .complete)
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            try accumulator.append(.toolCallStarted(call.id, name: call.name))
            try accumulator.append(.toolCallArgumentsDelta(call.id, raw))
            try accumulator.append(.toolCallCompleted(call))
            try accumulator.append(.responseCompleted(.init(info: info, toolCalls: [call], stopReason: .toolCalls)))
            XCTAssertEqual(try accumulator.finish().toolCalls.first?.argumentsJSON, raw)
        }
    }
}
