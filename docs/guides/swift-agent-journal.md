# SwiftAgent Journal

last-verified: 2026-09-27

`AgentJournal` owns trusted mutation transitions and Session restoration. The
optional `AgentJournalFileStore` product supplies the local durable format.
Read-only Agents can omit a Journal or use `AgentJournal()` in memory. An Agent
with mutation tools requires a durable Journal at `makeSession`.

```swift
import AgentCore
import AgentJournalFileStore

let journal = try AgentIncrementalJournal.create(
    at: storeDirectory, operationDomain: "account:123"
)
let session = try agent.makeSession(id: stableSessionID, journal: journal)
let run = try await session.run("Update the listing", operationID: stableOperationID)
_ = try await run.wait()
try await run.waitForDrain()
try await journal.close()

let reopened = try AgentIncrementalJournal.open(at: storeDirectory)
let pending = try await reopened.recoverPendingMutations(sessionID: stableSessionID)
```

Use `create` only for a new directory and `open` only for an existing new-format
store. They never turn a missing, old, corrupt, or unknown store into an empty
ledger. A framed `SWIFTAGENT-JOURNAL-1` file is rejected with
`unsupportedLegacyFormat` and its bytes are unchanged. There is no migration
or old-format reader. Stop the old workflow and resolve its outstanding
operations outside this SDK before beginning a new operation domain. Do not
point a new empty store at the old task and assume its effects were deduplicated.

The store has a persisted random `storeID` and one `operationDomain`. All
Sessions that must share deduplication must share **the same open Journal
handle** and directory. Another directory with the same domain text has a
separate ledger. `storeIdentity()` reports both values. The handle holds an
OS exclusive writer lock until safe `close()`. A second process or an
independent same-process open gets `storeInUse`. The owner can run multiple
Sessions and provider/tool calls concurrently; only short commits are
serialized. `close()` rejects an active Session lease, waits for accepted
maintenance, then unlocks. Wait for `run.waitForDrain()` before closing.

## Committed state and queries

Formal Session messages retain stable IDs and order. Read them with the
throwing, paginated `readMessages(sessionID:after:limit:)`; its cursor is a
zero-based ordinal. `latestCheckpoint(sessionID:)` restores the model-ready
conversation for one Session and current instructions are supplied by the new
Agent. `pendingMutations(sessionID:)` and `recoverPendingMutations(sessionID:)`
are throwing scoped queries. `mutationStatus(identity:)` inspects the
indexed state, trusted receipt, replay output and no-effect confirmation for
one operation. There is no nonthrowing full-record snapshot API.

`AgentContextProjector` affects only the next model request. Request summaries
or shortened views do not delete formal messages, restore Evidence, or grant
permission. The old lossy history-compactor path has been removed. When the
projected request exceeds `AgentContextPolicy.maxModelContextUTF8Bytes`, the
request fails without rewriting the conversation. Per-input size is enforced
separately. See [context policy](swift-agent-context.md).

## Commits and maintenance

One versioned, checksummed batch appends only new messages and necessary
state transitions to an active segment. A trusted mutation receipt, replay
output, terminal state, and its formal assistant/tool result publish together.
Large batches use a synced managed blob before the batch refers to it. A new
root and its indexes are synced before an atomic `CURRENT` replacement and
parent-directory sync. A complete unpublished tail is truncated on exclusive
open; a damaged published batch or root fails explicitly. Checksums detect
accidental damage, not malicious tampering.

The SDK rotates segments and incrementally packs sealed ones. It retains
formal messages, pending/reconciliation facts, terminal identities, receipts
and replay outputs; it drops obsolete process records and deletes an old
segment only after the replacement root is reliable. Physical maintenance
never changes a logical operation identity or Session message ID. It does not
promise fixed disk use while actual conversation and operations grow. The
policy can be configured with `JournalMaintenancePolicy`, while
`storeStatus()`, `maintenanceStatus()`, `storageMetrics()`, and
`requestMaintenance()` support
observation and explicit low-load work. Normal operation schedules maintenance
without a Host pre-turn compaction call. If maintenance cannot keep up, new
mutation admission can fail with `maintenanceRequired`; an in-flight
settlement still has its ordinary persistence path.

Only one same-host writer is supported. Do not copy an open directory as a
backup or run an external compactor against it. Close it, then copy the whole
directory including format, roots, segments, indexes and managed blobs. The
lock file is stable and is never garbage-collected. Network filesystems,
online copying, cross-device replication and power-loss simulation are outside
the tested contract. The commit protocol and tested crash cases are in
[ADR 0004](../adr/0004-journal-storage.md).

## Uncertain effects

Intent admission must finish durably before the executor starts. A commit
reported as `commitUnknown` keeps the store unavailable to further writes
until it is reopened and inspected. A startup commit with an unknown result
returns an owned Run that fails with `commitUnknown` and drains without calling
the model or tools. The Host must not treat a timeout, cancellation or unknown
commit as proof that an effect did not occur.

After an executor may have acted, restart changes an unsettled intent to
`needsReconciliation`; it never calls the tool again automatically. A trusted
receipt and canonical output can be supplied through `reconcileMutation`.
`abortMutation(_:confirmedNoEffect:)` requires a nonempty Host confirmation
that **no external effect happened**. It cannot abort a mere in-flight intent
or convert uncertainty into safety. The original identity, parameters and
no-effect confirmation remain available after physical maintenance. The
[recovery guide](swift-agent-mutation-recovery.md) describes the operator path.
