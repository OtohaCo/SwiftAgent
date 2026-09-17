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
