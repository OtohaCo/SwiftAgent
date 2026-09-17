import AgentModels
import Foundation
import XCTest

final class ModelEventTests: XCTestCase {
    private let info = ResponseInfo(id: "response-1", model: .init(provider: "fixture", name: "search"))

    func testReplaysTextFixtureThroughNativeEventEncoding() throws {
        let expected = ModelResponse(info: info, content: [.text("Hello world")], stopReason: .endTurn)
        let events: [ModelEvent] = [
            .responseStarted(info), .textDelta("Hello"), .textDelta(" world"), .responseCompleted(expected),
        ]
        let fixture = try JSONEncoder().encode(events)
        let decoded = try JSONDecoder().decode([ModelEvent].self, from: fixture)
        var accumulator = ModelEventAccumulator()
        for event in decoded { try accumulator.append(event) }
        XCTAssertEqual(try accumulator.finish(), expected)
    }

    func testRequiresExactlyOneStartAndOneTerminalWithMatchingContent() throws {
        let empty = ModelResponse(info: info, stopReason: .endTurn)
        let cases: [[ModelEvent]] = [
            [.textDelta("early")], [.responseCompleted(empty)],
            [.responseStarted(info), .responseStarted(info)],
            [.responseStarted(info), .textDelta("actual"), .responseCompleted(empty)],
            [.responseStarted(info), .responseCompleted(empty), .textDelta("late")],
            [.responseStarted(info), .responseCompleted(empty), .responseCompleted(empty)],
            [.responseStarted(info), .responseCompleted(.init(
                info: .init(id: "wrong-id", model: info.model), stopReason: .endTurn))],
        ]
        for events in cases {
            var accumulator = ModelEventAccumulator()
            XCTAssertThrowsError(try events.forEach { try accumulator.append($0) }, "\(events)")
            XCTAssertThrowsError(try accumulator.finish(), "An invalid stream cannot recover")
        }
    }

    func testMissingTerminalPoisonsStreamEvenWhenTextLooksFinished() throws {
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(info))
        try accumulator.append(.textDelta("Done"))
        XCTAssertThrowsError(try accumulator.finish())
        XCTAssertThrowsError(try accumulator.append(.responseCompleted(
            .init(info: info, content: [.text("Done")], stopReason: .endTurn)
        )))
        XCTAssertThrowsError(try accumulator.finish())
    }

    func testReasoningAndUsageSnapshotsRemainSeparateFromVisibleText() throws {
        let usage = ModelUsage(inputTokens: 10, outputTokens: 4, cachedInputTokens: 2, reasoningTokens: 1)
        let expected = ModelResponse(info: info, content: [
            .reasoning("Check numbers"), .text("5"), .reasoning("Verified"), .text(" total"),
        ], usage: usage, stopReason: .endTurn)
        var accumulator = ModelEventAccumulator()
        let events: [ModelEvent] = [
            .responseStarted(info), .reasoningDelta("Check "), .reasoningDelta("numbers"),
            .usage(.init(inputTokens: 10, cachedInputTokens: 2)), .textDelta("5"),
            .usage(.init(outputTokens: 2)), .reasoningDelta("Verified"), .textDelta(" total"),
            .usage(.init(outputTokens: 4, reasoningTokens: 1)), .responseCompleted(expected),
        ]
        for event in events { try accumulator.append(event) }
        XCTAssertEqual(try accumulator.finish(), expected)
    }

    func testRejectsNegativeUsageAndUnannouncedTerminalUsage() throws {
        for usage in [ModelUsage(inputTokens: -1), .init(outputTokens: -1),
                      .init(cachedInputTokens: -1), .init(cacheWriteInputTokens: -1), .init(reasoningTokens: -1)] {
            var accumulator = ModelEventAccumulator()
            try accumulator.append(.responseStarted(info))
            XCTAssertThrowsError(try accumulator.append(.usage(usage)))
            XCTAssertThrowsError(try accumulator.finish())
        }
        var accumulator = ModelEventAccumulator()
        try accumulator.append(.responseStarted(info))
        XCTAssertThrowsError(try accumulator.append(.responseCompleted(
            .init(info: info, usage: .init(inputTokens: 1), stopReason: .endTurn)
        )))
    }
}
