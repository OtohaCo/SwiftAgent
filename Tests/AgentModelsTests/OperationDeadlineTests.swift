import AgentModels
import XCTest

final class OperationDeadlineTests: XCTestCase {
    func testExpiredOperationRunsCompletionHookBeforeThrowing() async {
        let probe = CompletionProbe()

        do {
            _ = try await withOperationDeadline(
                .now,
                timeoutError: DeadlineFixtureError.expired,
                operation: { 1 },
                onOperationFinished: { await probe.mark() }
            )
            XCTFail("An expired operation must fail before starting")
        } catch {
            XCTAssertEqual(error as? DeadlineFixtureError, .expired)
        }

        let completionCount = await probe.count
        XCTAssertEqual(completionCount, 1)
    }
    func testResultSettledBeforeTheDeadlineSurvivesTheDeadlinePassingWhileItIsRecorded() async throws {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .milliseconds(150)))
        let value = try await withOperationDeadline(
            gate.deadline, timeoutError: DeadlineFixtureError.expired, gate: gate,
            operation: {
                XCTAssertTrue(gate.settle())
                try await Task.sleep(for: .milliseconds(400))
                return 7
            }
        )
        XCTAssertEqual(value, 7)
    }

    func testOperationNotSettledByTheDeadlineStillTimesOut() async {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .milliseconds(150)))
        do {
            _ = try await withOperationDeadline(
                gate.deadline, timeoutError: DeadlineFixtureError.expired, gate: gate,
                operation: {
                    try await Task.sleep(for: .milliseconds(400))
                    return 7
                }
            )
            XCTFail("Work still running at the deadline must time out")
        } catch {
            XCTAssertEqual(error as? DeadlineFixtureError, .expired)
        }
    }

    func testCancellationStillEndsASettledOperation() async {
        let gate = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(5)))
        let task = Task {
            try await withOperationDeadline(
                gate.deadline, timeoutError: DeadlineFixtureError.expired, gate: gate,
                operation: {
                    XCTAssertTrue(gate.settle())
                    try await Task.sleep(for: .seconds(5))
                    return 7
                }
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled operation must not complete")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testGateSettlesOnlyBeforeTheDeadlineAndReopens() {
        let past = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(-1)))
        XCTAssertFalse(past.settle())
        XCTAssertFalse(past.settle(now: .now.advanced(by: .seconds(-2))), "Once expired it stays expired")

        let open = OperationDeadlineGate(deadline: .now.advanced(by: .seconds(60)))
        XCTAssertTrue(open.settle())
        XCTAssertFalse(open.expire(), "A settled result is not taken back by the timer")
        open.reopen()
        XCTAssertTrue(open.expire())
        XCTAssertFalse(open.settle())
    }
}

private actor CompletionProbe {
    private(set) var count = 0

    func mark() {
        count += 1
    }
}

private enum DeadlineFixtureError: Error, Equatable {
    case expired
}
