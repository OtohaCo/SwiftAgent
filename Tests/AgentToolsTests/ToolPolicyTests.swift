import AgentTools
import Foundation
import Testing

struct ToolPolicyTests {
    @Test func policyPreservesSchedulingAndRequiresExplicitAuthorizationByDefault() throws {
        let policy = try ToolPolicy(effect: .readOnly, execution: .parallel, idempotency: .safe, timeout: .seconds(3))
        #expect(policy.effect == .readOnly)
        #expect(policy.execution == .parallel)
        #expect(policy.idempotency == .safe)
        #expect(policy.timeout == .seconds(3))
        #expect(policy.authorization == .required)
        #expect(policy.recoverableErrors == .failClosed)
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
        #expect(throws: ToolPolicyError.mutationCannotExposeRecoverableErrors) {
            try ToolPolicy(effect: .mutation, execution: .exclusive, idempotency: .requiresReceipt,
                           timeout: .seconds(1), recoverableErrors: .modelVisible)
        }
    }

    @Test func factoriesEncodeTheSafeDefaults() throws {
        let read = try ToolPolicy.readOnly()
        #expect(read.effect == .readOnly)
        #expect(read.execution == .parallel)
        #expect(read.idempotency == .safe)
        #expect(read.authorization == .required)
        #expect(read.evidence == .none)
        #expect(read.recoverableErrors == .failClosed)

        let mutation = try ToolPolicy.mutation()
        #expect(mutation.effect == .mutation)
        #expect(mutation.execution == .exclusive)
        #expect(mutation.idempotency == .requiresReceipt)
        #expect(mutation.authorization == .required)
        #expect(mutation.evidence == .required)
        #expect(mutation.recoverableErrors == .failClosed)
    }

    @Test func legacyCodablePayloadDefaultsToFailClosed() throws {
        let policy = try ToolPolicy.readOnly(recoverableErrors: .modelVisible)
        let encoded = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(ToolPolicy.self, from: encoded)
        #expect(decoded == policy)

        let legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var withoutField = legacy
        withoutField.removeValue(forKey: "recoverableErrors")
        let legacyData = try JSONSerialization.data(withJSONObject: withoutField)
        #expect(try JSONDecoder().decode(ToolPolicy.self, from: legacyData).recoverableErrors == .failClosed)
    }
}
