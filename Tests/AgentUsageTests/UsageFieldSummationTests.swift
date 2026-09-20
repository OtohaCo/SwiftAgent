@testable import AgentUsage
import Testing

struct UsageFieldSummationTests {
    @Test func fieldSummationStaysIncompleteAfterOverflow() {
        let field = summarizeUsageField([Int.max, Int.max, 5])

        #expect(field.reportedSubtotal == nil)
        #expect(field.reportedCount == 3)
        #expect(field.missingCount == 0)
        #expect(!field.complete)
    }
}
