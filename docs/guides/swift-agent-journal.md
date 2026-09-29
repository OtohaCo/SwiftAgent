# SwiftAgent Journal

last-verified: 2026-09-29

`AgentJournal` owns trusted mutation transitions and Session restoration. The
optional `AgentJournalFileStore` product supplies the local durable format.
Default new stores use segmented format schema 3 with the bounded `BatchV2` payload
and committed index witnesses. Schema-1 and unreleased schema-2 directories
are rejected intact, with no implicit migration or reset. A queue
admission, Run ID and formal user input share one `CURRENT` root publication;
queue-only writes do not advance conversation revision. See the
[follow-up guide](swift-agent-follow-up-queue.md) and [ADR 0007](../adr/0007-durable-follow-up-queue.md).
Read-only Agents can omit a Journal or use `AgentJournal()` in memory. An Agent
with mutation tools requires a durable Journal at `makeSession`.
For bounded pre-admission Evidence feedback, create a **new** store with
`supportsAdmissionRejections: true`; it reserves schema 4, a typed rejection
marker and a bounded operation-pending index. An opt-in Run on schema 3 fails
before the Provider request. The RC4 reader rejects schema 4 even before a
rejection occurs; schema 3 remains compatible with RC4. No store is migrated
or silently reset. See [ADR 0008](../adr/0008-bounded-pre-admission-replanning.md).

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
independent same-process open gets `storeInUse`. An out-of-band change to the
active `CURRENT` root is rejected as `concurrentWriter`; it cannot be accepted
as equivalent maintenance. The owner can run multiple
Sessions and provider/tool calls concurrently; only short commits are
serialized. `close()` rejects an active Session lease, waits for accepted
maintenance, then unlocks. From the moment it starts, new work (Session leases,
checkpoints, mutation admission, follow-up enqueue or withdrawal) fails with
`storeClosed`; work already accepted still completes. Wait for `run.waitForDrain()` before closing.
After `commitUnknown`, the handle remains poisoned for all reads and writes.
Once every Run, resolver, observer and accepted I/O has drained, `close()` may
release its OS lock without publishing or rolling back anything. Keep the old
Session and Journal objects from starting further work; reopen the same
directory to inspect its verified root. A failed close retains ownership for
a retry of close, never for another mutation. The lock descriptor is
close-on-exec, so a child process started while the store is open does not keep
it locked after close. Until such a child starts its new program it still
shares the descriptor: an open right after `close()`, while the same process is
spawning, can briefly get `storeInUse` and succeeds once the spawn completes
([#47](https://github.com/OtohaCo/SwiftAgent/issues/47)).

## Committed state and queries

Formal Session messages retain stable IDs and order. Read them with the
throwing, paginated `readMessages(sessionID:after:limit:)`; its cursor is a
zero-based ordinal. `latestCheckpoint(sessionID:)` restores the model-ready
conversation for one Session and current instructions are supplied by the new
Agent. `pendingMutations(sessionID:)` and `recoverPendingMutations(sessionID:)`
are throwing scoped queries. `mutationStatus(identity:)` inspects the
indexed state, trusted receipt, replay output and no-effect confirmation for
one operation. There is no nonthrowing full-record snapshot API.
The schema-3 store also keeps a small per-key first-publication witness for
Session, queue-head, queue-ID and operation indexes. A missing published index
or witness fails explicitly; an absent key with no published witness remains
a legitimate first use. These checks read the queried key and at most its
first commit position, not all Sessions or history. Witnesses retain key
identity for the store lifetime, so space still grows with real identities.

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
open; a damaged published batch or root fails explicitly. The root also binds
the persisted store identity and operation domain. Managed directories and
file descriptors reject symbolic links before any repair or GC. Checksums detect
accidental damage, not malicious tampering.

The SDK rotates segments and incrementally packs sealed ones. It retains
formal messages, pending/reconciliation facts, terminal identities, receipts
and replay outputs; it drops obsolete process records and deletes an old
segment only after the replacement root is reliable. Physical maintenance
never changes a logical operation identity or Session message ID. It does not
promise fixed disk use while actual conversation and operations grow. The
policy can be configured with `JournalMaintenancePolicy`. A segment rotates
after the append that reaches `segmentBytes`, so it can end one inline frame
past it. `maxWorkBytes` must cover such a segment: `segmentBytes` plus at most
about 4/3 of it, or about 683 KiB once `segmentBytes` reaches 512 KiB. The
initializer rejects a smaller budget. Opening a store whose sealed segments,
packs or active segment exceed the handle's `maxWorkBytes` fails with
`maintenanceBudgetTooSmall(requiredWorkBytes:)` and leaves the store unchanged;
a budget of at least that size opens it. `storeStatus()`, `maintenanceStatus()`,
`storageMetrics()`, and `requestMaintenance()` support
observation and explicit low-load work. `requestMaintenance()` joins a pass
that is already running and reports that pass's result. Normal operation
schedules maintenance without a Host pre-turn compaction call. If maintenance
cannot keep up, new mutation admission can fail with `maintenanceRequired`; an
in-flight settlement still has its ordinary persistence path.

A segment rotation that fails before publishing leaves the active segment past
`segmentBytes`, but never past `maxWorkBytes`. Until a maintenance pass retries
the rotation successfully, new Run input, mutation admission and follow-up
enqueue fail with `maintenanceRequired`, and work already admitted settles
within the remaining room. A rotation whose `CURRENT` replacement may or may
not be durable poisons the handle like any other uncertain publication; the
batch it followed stays committed.

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
