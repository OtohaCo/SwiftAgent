# SwiftAgent Mutation Recovery

last-verified: 2026-09-27

An operation is admitted before its executor runs. The durable intent binds
its final identity to the tool, semantic arguments, resource targets and
receipt expectation. A successful executor return is not settlement: Core
validates the trusted receipt, then publishes the terminal ledger state,
replayable output and formal assistant/tool conversation in one local batch.
The external effect itself cannot be included in that local transaction.

For a stable nonempty `operationID`, the current final identity combines that
ID, tool name and canonical semantic JSON arguments. It does not use the
Session ID, Run ID or model-generated call ID. Hosts must scope an operation
ID to the intended account/resource authority; Core also checks the saved
resources and expectation before replay. A blank ID is per-call and gives no
cross-run deduplication. If one workflow needs two separately intended effects
with the same tool and arguments, give those steps distinct operation IDs.

After restart, inspect and quarantine without invoking a tool:

```swift
let journal = try AgentIncrementalJournal.open(at: storeDirectory)
let pending = try await journal.recoverPendingMutations(sessionID: sessionID)
for item in pending {
    // Check the external system using trusted Host evidence. Do not replay.
    if let confirmedReceipt = await host.confirmedReceipt(for: item) {
        try await journal.reconcileMutation(
            item, receipt: confirmedReceipt, output: host.canonicalOutput(for: item)
        )
    } else if await host.confirmedNoExternalEffect(for: item) {
        let proof = try AgentNoEffectConfirmation(basis: "verified rejection in external transaction log")
        try await journal.abortMutation(item, confirmedNoEffect: proof)
    } else {
        // Keep needsReconciliation and surface it to the operator.
    }
}
```

The Host example above is pseudocode for its own trusted checks; it is not an
SDK API or permission to infer success from model text. A reconciliation
receipt must match the persisted identity, exact targets and expectation.
Reconciliation commits replay output and a paired assistant/tool result with
the settled ledger entry. It does not restore Evidence or authorize a future
operation. Confirmed no-effect abort keeps the identity and its basis. A
matching retry can create a new intent; a semantically different request with
that same final identity remains a conflict.

An `intent` is an uncertain candidate after process death. `needsReconciliation`
blocks another mutation in that Session and blocks replay of the same identity
across the operation domain. The ledger retains terminal identity, receipt
and promised output without a TTL while that domain exists. The SDK provides
local durable admission, deduplication and settlement, not exactly-once
execution in every external service.

Cancellation is not rollback. Before admission, no executor runs. After a
local commit begins, an error or deadline can have an unknown result; a
startup Run is still owned through drain, and mutation admission uncertainty
never enters the executor. An effect followed by an unconfirmed settlement is
quarantined. Wait for physical drain even when `run.wait()` or its event stream
has ended. An unknown root or damaged published data must be investigated,
not reset to an older snapshot and used to run another mutation.

Queued `.perCall` uses the existing Run/call identity, while `.operation(id)` retains semantic receipt replay. Old inputs stay in operation mode. An interrupted per-call intent still requires reconciliation; a new call never automatically replays it. See [follow-up identity](swift-agent-follow-up-queue.md).

## Run facts do not settle mutations

On schema-9 stores, `runRecord` reports durable admission and logical terminal
independently of mutation recovery. An admitted Run without terminal did occur;
an old format lacking this capability throws rather than guesses. Completed,
cancelled or failed logical terminal does not attest drain or mutation settlement.
Use the existing trusted mutation queries/reconciliation rules. A failed terminal
write never authorizes repeating an already settled modification. Host may use
its own trusted evidence to decide new work, with a new Run and current binding;
query does not revive the old Run or restore permission. No automatic recovery
is enabled. See [Session query contract](swift-agent-sessions.md#durable-admission-and-logical-termination).
