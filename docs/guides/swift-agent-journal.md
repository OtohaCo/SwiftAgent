# SwiftAgent Journal

## Queued mutation identity (unreleased, Issue #74)

Queued inputs now explicitly select `AgentOperationIdentity.perCall` or
`.operation(String)`. The existing `operationID:` initializer keeps its
operation semantics. `AgentFollowUpInput.operationID` and
`AgentFollowUpRecord.operationID` change from `String` to `String?`: nil means
per-call mode; it is never an empty/synthetic ID. This is a source break for
clients requiring a nonoptional property. Both records expose `identity`.

Per-call dispatch passes no operation ID to the existing Run algorithm; each
new call ID uses that Run's ID/call ID. Duplicate call IDs remain protocol
errors. There is no cross-call/Run deduplication, automatic replay or recovery.
Same input ID retries compare exact text, configuration reference and identity
(including exact operation ID bytes), and return the current durable record.
An identity change conflicts even after admission/withdrawal.

Explicit `supportsPerCallFollowUps: true` creation selects format schema 8,
including schema-7 confirmed-no-effect and audit capabilities. Default and
other creation options retain their formats. Existing schema 3–7 stores stay
in their original format and reject per-call enqueue before publication with
`unsupportedFormat`. Their records decode as `.operation(storedOperationID)`.
There is no in-place migration, new-ledger escape hatch or identity reset.
Schema 8 is needed because schema-7 binaries could otherwise ignore a new
field and erase or misinterpret identity during maintenance. The actual
unmodified `27ceea564740bca8deac841b9e8c0231c2cd13ef` reader is exercised by
`Scripts/verify-per-call-compatibility.sh`: old open/append/maintain reject
schema 8 before and after new-reader maintenance. New readers retain old
operation records and per-call records on reopen. Pending intent,
needs-reconciliation, settlement, confirmed-no-effect, cancellation and drain
contracts remain unchanged; uncertain effects are inspected, never retried.

## RC6 candidate: authorization audit (opt-in)

An explicit `supportsAuthorizationAudit: true` create selects schema 5 and
stores typed proposal/decision/disposition/result-reference facts in the same
CURRENT transaction domain. It includes schema-4 rejection support. Default
creation stays schema 3, rejection-only stays schema 4; neither is upgraded.
Audit-only commits do not advance conversation revision. Incremental indexes
and witnesses retain facts/raw payloads during maintenance; upload is not a
retention policy. `auditRecords` is a throwing, bounded Host query; exporter
checkpoints share the store. See [Audited Authorization](swift-agent-authorization-audit.md)
for explicit directory selection, old-reader rejection, query/export and
recovery. `storageMetrics().encodedBatches` counts batch encodings, excluding
index encodings and Host serialization.

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
Memory mode retains the latest complete checkpoint per Session, including its
steering IDs and record coordinates. Replaced checkpoints and other event
payloads are released; canonical history is not truncated. Session-created and
last-Run markers have one entry per Session. Previously seen Run IDs remain as
identity-only metadata, growing with the number of distinct Runs; this preserves
the existing `hasRun` query without retaining each Run's message arrays. Reads
and normal commits use the affected Session's index, not a scan of old events.
There is no automatic Session/Run identity eviction. This mode still cannot
admit mutations or `requiredAudit`; durable schema 3/4/5 behavior is unchanged.

`swift run -c release MemoryJournalBenchmark 1000` measures the actual memory
Journal (also use 2000 and 4000 in separate processes). It reports retained
checkpoint arrays, message slots, Session/Run metadata and RSS. Message values
and their content can share storage across snapshots; slots are not unique
body allocations. RSS includes allocator/runtime effects and is not a fixed
correctness threshold. See `MemoryJournalRetentionTests` for structural and
real Session/restore assertions.

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

Message pagination keeps its published **inclusive** semantics:
`readMessages(sessionID:after:limit:)` includes the zero-based formal-message
ordinal `after`. Start at 0 and advance by returned count. Follow-up pagination
is **exclusive**: `session.followUps(after:limit:)` includes ordinal 0 for `nil`,
then continues after the last returned ordinal. Audit keeps its existing
exclusive sequence/cursor contract. These APIs are not renamed or silently
changed. Boundary tests cover first, middle, last and empty pages across reopen.

### Optional bounded writer-lock wait

The original sync and async opening APIs still fail fast. Hosts can explicitly
select a finite absolute deadline for short writer-lock contention:

```swift
import AgentCore
import AgentJournalFileStore
import Foundation

func openHostJournal(directory: URL) async throws -> AgentJournal {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    return try await AgentIncrementalJournal.openAsync(at: directory,
        writerLockWait: .until(deadline), deadline: deadline)
}
```

The Host supplies its existing durable directory; there is no default production
path, new ledger, migration or business retry. Waiting repeats only nonblocking
`flock` on one owned descriptor after format validation, not the whole open.
The earlier of the wait deadline and the original I/O deadline applies.
Cancellation wakes the monotonic wait; the owned utility-queue operation finishes
and closes any newly acquired handle before reporting cancellation. This waits
on a dedicated I/O worker, not a Swift cooperative thread. Hosts should bound
their concurrent opens. A real writer never grants concurrent write permission.
Other lock I/O errors, invalid format or damaged roots are not retried.

This optionally mitigates short lock competition. A forked child can still hold
the actual Journal descriptor before exec; CLOEXEC releases it when exec succeeds.
The controlled fork helper gates that window using raw POSIX child code (no Swift
or Foundation after fork), launched via Foundation Process. It is an integration
mechanism test, not a measurement of Foundation's internal spawn window duration.
Separate real Foundation Process/posix_spawn tests verify the existing long-child
noninheritance behavior. These tests run on macOS/Linux, not iOS. No OS lock
primitive has been replaced, no other descriptor unlocked or lock file deleted.

## Executor no-effect on main (unreleased)

[Explicit schema-7 creation (v1 schema 6 remains readable)](swift-agent-confirmed-no-effect.md) stores bounded
typed executor proof and abort/error/checkpoint/audit associations together.
Schema 3/4/5 defaults remain and no existing store is migrated. Per-call Host
queries restore facts, never permission or automatic replay. PR #62 implemented
this capability on main; RC6 remains unreleased.

## Run record storage and query contract

`supportsRunRecords: true` creation selects schema 9; default creation and
existing stores retain their formats. Schema 9 includes schema-8 identity,
audit and confirmed-no-effect capabilities. It adds explicit disk DTOs and
three witnessed indexes (admission, exact correlation, terminal) in the same
batch/index/CURRENT transaction. A Run association and its formal user message
publish atomically. The actual owner publishes its final checkpoint and typed
logical terminal atomically after retained steering and started writes resolve.
No second ledger is introduced. Run records retain only association/fingerprint
and bounded terminal metadata, not a full history array for every Run. Queries
read indexes and the linked formal message; they do not scan historical Runs.

| Query result | Meaning |
| --- | --- |
| `notAdmitted` | A valid supported store has no admission for this exact scope. |
| `admitted(record)` | Admission exists; no logical terminal fact was published. |
| `terminal(record, terminal)` | Both admission and logical terminal exist. |
| Thrown error | Storage cannot answer reliably; not evidence of absence. |

Memory-only or schema-3–8 stores return `unsupportedFormat`, even for old Runs
that have existing checkpoints. Closed storage returns `storeClosed`; poisoned
unknown storage returns `commitUnknown`; missing published index/message data
returns `invalidRecord`. Never interpret these as `notAdmitted`. A crash after
startup publication but before Host sees the Run ID still leaves the key
queryable. A crash after a model checkpoint but before the terminal transaction
leaves `admitted`; after terminal root publication, reopening returns terminal.

Association keys and terminal metadata are retained for the entire store
lifetime through packing/maintenance/reopen. No key deletion or expiry API is
provided. Future body deletion must preserve identity tombstones or explicitly
report insufficient capability, never convert past admission into absence.
Old binaries reject schema 9 before writes, including empty stores. The actual
schema-8 reader at `d3a8ef964aecd440934d51b7cd00f6552fe22002` is built by
`Scripts/verify-run-record-compatibility.sh`; its open/append/maintenance all
reject before and after new-reader maintenance without changing file bytes.
No migration or new ledger may bypass prior operation/unsettled facts.
See [ADR 0014](../adr/0014-durable-run-association.md).

## Images (format schema 10, ADR 0012)

`supportsImageContent: true` creation selects schema 10, which includes schema
9. A message's image record holds media type, SHA-256 digest, byte count and
text alternative only. The bytes are written once per digest to
`images/<2>/<storeID>_<digest>.image` (atomic write and directory sync) before
the batch that names them is published; an unreferenced file left by a failed
commit is harmless. Reading a message loads the file and checks its size and
digest; a changed file fails the read (`checksumMismatch`) and never yields a
different image. Reopened Sessions and unfinished Runs therefore get their
images back from the digest.

Schema 3–9 stores are never migrated: with them a read-only tool result
carrying images fails with `unsupportedFormat` before commit, and a mutation's
settlement is committed with text substitutes instead (the store itself refuses
any image with `unsupportedFormat`); `AgentJournal.supportsImageContent`
tells a Host which kind it holds (memory journals: always). Image files are kept
for the store's lifetime; maintenance does not collect them. Schema-9 readers
reject schema 10 before writes (`Scripts/verify-image-content-compatibility.sh`
against `3ad52332e71290abde108007a7ce34e7054b7bde`). Audit result records list
`imageDigests` only. See [ADR 0012](../adr/0012-image-content.md).
