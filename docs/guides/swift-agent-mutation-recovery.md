# SwiftAgent Mutation Recovery

last-verified: 2026-09-18

Mutations have two durable phases: an intent before the host executor is called,
and a validated receipt after it returns. The model can propose a call, but it
cannot create either phase.

## Execution Order

For a mutation in an `AgentSession` backed by `AgentJournal`, the scheduler
serializes mutation/exclusive work while allowing independent read-only parallel
work. The order is:

1. Decode and validate the typed input and JSON Schema.
2. Revalidate evidence and authorization.
3. Acquire the scheduler's exclusive resource lease.
4. Append the complete intent durably, including raw arguments and receipt expectation.
5. Call the host executor.
6. Validate the returned receipt against the durable operation and targets.
7. Settle the intent durably, then commit the tool result to canonical history.

If any step after admission cannot establish a matching receipt, the scheduler
reports failure and the intent is marked `needsReconciliation`. Its operation
deadline has a drain callback, so timeout or cancellation returns control to the
caller without pretending that an uncooperative host executor has already
stopped. The late executor cannot publish a successful tool result after
cancellation or timeout. A cancelled waiter that never acquired a lease does
not admit a mutation intent and does not call the executor. If the executor
already produced a side effect, restart recovery still does not replay it.

## Restart

On startup, call `recoverPendingMutations()`. Unsettled `intent` records become
`needsReconciliation`; no provider request or tool executor is replayed. New
mutations in that session are rejected until an operator or trusted host service
supplies a receipt through `reconcileMutation`, or closes the intent with
`abortMutation`. A reconciliation receipt must satisfy the
original `ToolReceiptExpectation`, including exact operation identity and target
set. Abort does not invoke the original tool.

Read-only tools do not require this mutation journal path. A different Session
can continue independently when one Session has a quarantined mutation.

For a host process that recreates its Engine objects after a crash, the owner must
reopen the same durable journal and provide the same stable Session identity. The
Otoha adapter does this per production owner (`conversation`, `queue-planning`,
and `observation`). A random replacement Session ID would hide an outstanding
intent from the recovery gate. Stable identity does not authorize replay: the
pending intent still requires an explicit trusted receipt, reconciliation, or abort.

The host boundary also records a conservative in-process signal when a mutation
tool reaches the Engine execution path. If the run then fails without a trusted
receipt, the host must surface reconciliation rather than invoke a local fallback
that could repeat the same mutation. A cancelled, deadline-exceeded or failed
conversation action follows the same rule; it does not silently degrade into a
second local playback attempt.
