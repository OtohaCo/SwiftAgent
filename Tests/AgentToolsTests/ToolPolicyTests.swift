import AgentTools
import Testing

struct ToolPolicyTests {
    @Test func policyPreservesSchedulingAndRequiresExplicitAuthorizationByDefault() throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(3))
        #expect(policy.effect == .readOnly)
        #expect(policy.execution == .parallel)
        #expect(policy.idempotency == .safe)
        #expect(policy.timeout == .seconds(3))
        #expect(policy.authorization == .required)
        let mutation = try ToolPolicy(effect: .mutation, execution: .exclusive,
                                      idempotency: .requiresReceipt, timeout: .seconds(2))
        #expect(mutation.effect == .mutation)
    }

    @Test func invalidPolicyThrowsWithoutCrashingTheHost() {
        for timeout in [Duration.zero, .seconds(-1)] {
            #expect(throws: ToolPolicyError.invalidTimeout) {
                try ToolPolicy(effect: .readOnly, execution: .sequential, idempotency: .safe, timeout: timeout)
            }
        }
        for execution in [ToolPolicy.Execution.parallel, .sequential] {
            #expect(throws: ToolPolicyError.mutationRequiresExclusiveExecution) {
                try ToolPolicy(effect: .mutation, execution: execution, idempotency: .keyed, timeout: .seconds(1))
            }
        }
    }
}
