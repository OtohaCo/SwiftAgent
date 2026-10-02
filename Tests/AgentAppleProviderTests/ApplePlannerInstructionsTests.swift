import AgentAppleProvider
import Testing

/// A host budgeting the on-device model's small context counts the fixed planner instructions the adapter
/// puts before its own, through the public API.
struct ApplePlannerInstructionsTests {
    @Test func thePlannerInstructionsArePublic() {
        #expect(AppleFoundationProvider.plannerInstructions.contains("You are the planner for an external tool runtime."))
        #expect(AppleFoundationProvider.plannerInstructions.count > 200)
    }
}
