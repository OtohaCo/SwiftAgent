# SwiftAgent Receipts

last-verified: 2026-09-18

`ToolResult.receipt` is a separate executor-supplied confirmation channel. Ordinary
output, model text and canonical history never create a trusted receipt. The host
executor must derive confirmation from its actual service result; validation
checks consistency, not whether an untrusted executor is telling the truth.

## Binding and Validation

A tool declares expected resources and revision rules through
`receiptExpectation(for:)`, using its typed input. The runtime binds the receipt's
operation ID to `ToolContext.idempotencyKey`, not a model-supplied operation ID.
Resolvers should be pure and must not execute the operation.

```swift
import AgentTools

func validateConfirmation(_ receipt: ToolReceipt?, operationID: String,
                          target: EvidenceReference, previousRevision: String) throws {
    let expected = try ToolReceiptExpectation(
        targets: [target], revision: .changed(from: previousRevision)
    )
    try ToolReceiptValidator.validate(receipt, operationID: operationID, expectation: expected)
}
```

Targets must form exactly the expected nonempty set, without duplicates. Their
order does not matter. Operation IDs, target identities and revisions use exact
matching without Unicode normalization. Revision rules support optional, present,
exact and changed-from values; a supplied blank revision is always invalid.

Only `succeeded` without failure metadata can pass. Missing, failed, indeterminate,
mismatched or malformed confirmations throw typed `ToolReceiptError` values.
An undeclared receipt is rejected. A declared expectation requires a receipt even
when the tool declares safe idempotency. A read-only `requiresReceipt` tool needs
an expectation and a nonblank runtime operation key before execution.

## Accepted Results

Receipt checks do not replace authorization, evidence requirements, output schema
validation or deadlines. Failed output cannot publish evidence or a receipt event.
Timeout and cancellation prevent late confirmations from becoming success.

After all result checks, Core emits `toolReceiptValidated` before `toolCompleted`.
Its immutable `AgentToolReceipt` includes call ID and tool effect; a read-only
confirmation does not represent a mutation. `AgentLoopResult.receipts` retains
only confirmations accepted during that run. Receipt failures are classified as
`AgentFailure.receipt` in events.

## Mutation Admission

Mutation execution is admitted only when the Core supplies a
`ToolMutationAdmission` implementation. `AgentSession` supplies its durable
`AgentJournal`; after authorization and evidence revalidation, the exact raw
arguments, resource set, operation key and receipt expectation are written as a
pending intent before the host executor is called. A successful executor receipt
is validated again and then settles that intent durably.

If the executor is reached but the run is cancelled, times out, fails, or cannot
produce a matching receipt, the intent becomes `needsReconciliation`. Restart
recovery only records that quarantine state. It never calls the original tool,
replays the provider request or treats model text as proof. A separate trusted
reconciliation result must pass the original receipt expectation before the
intent can settle. A valid receipt declaration alone cannot open the gate, and a
failed run does not prove that an external operation was undone.
