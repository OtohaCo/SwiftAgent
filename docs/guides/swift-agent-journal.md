# SwiftAgent Journal

last-verified: 2026-09-20

`AgentJournal` is the Core-owned typed lifecycle log. It records provider-neutral
messages, model attempts, tool proposals/results, checkpoints, compaction summaries
and run outcomes. Journal events are not a UI timeline and contain no host-domain
other application-domain payloads.

Read-only Agents may omit a journal. Any mutation tool requires a **durable**
journal at `makeSession`. `AgentJournal()` is memory-only (`storage ==
.memory`) and fails for mutation Agents with
`AgentSessionError.durableJournalRequired`. Crash recovery and mutation
Sessions use `AgentJournal(persistenceURL:)` (`storage == .durable`).
`persist(to:)` upgrades a memory journal to durable storage after a successful
snapshot bind. Do not infer this from a file URL; `AgentJournalStorage` is the
capability.

`.durable` is the configured persistence mode. It is not a promise that every
later write will succeed. Mutation admission still has to write the durable
intent, and `persistenceUnavailable` / `concurrentWriter` remain fail-closed
errors. Hosts must handle those errors; they must not treat `makeSession`
success as proof that the next append landed on disk.

## Host API

Hosts do not append lifecycle frames. The runtime writes them. Public operations
are load, inspect, recover, reconcile and abort:

```swift
let journal = try AgentJournal(persistenceURL: journalURL)
let session = try agent.makeSession(id: sessionID, journal: journal)
let run = try await session.run("Update the listing")
_ = try await run.wait()
try await run.waitForDrain()

let restarted = try AgentJournal.load(from: journalURL)
let pending = try await restarted.recoverPendingMutations(sessionID: sessionID)
for item in pending where item.state == .needsReconciliation {
    try await restarted.abortMutation(item)
}
```

`snapshot()` is readable history for diagnostics. `latestCheckpoint(sessionID:)`
is the only payload used to reconstruct Session history after a restart.

There is no public API to mark an intent `settled` with arbitrary JSON. Executor
settlement stays inside the runtime after `ToolReceiptValidator` succeeds.
`reconcileMutation` requires a quarantined intent and a receipt that matches the
durable operation identity and targets.

## Durable Checkpoints

The runtime stores each checkpoint in one length-delimited, checksummed frame. A
frame is visible only after its complete payload has been written and synced.

Durable writes use a regular `.lock` file with an OS advisory `flock`; the lock
file is reusable after a crash, so an old file cannot become a permanent busy
marker. The writer verifies that the on-disk prefix still matches the instance
snapshot, synchronizes the file before publishing memory, and fails closed on
write or concurrency errors. A failed durable write does not publish its records
in memory. The intentional exception is an uncertain first directory sync: if
the frame bytes and file sync completed but the directory sync result is
unknown, the journal adopts the written records and reports the persistence
error so recovery cannot duplicate or discard a committed prefix.

Session startup checks cancellation and deadline before appending its durable
startup frame. Once that atomic append begins, it is the admission boundary:
the runtime creates the corresponding Run for the durable user event rather
than leaving an orphaned history entry if the deadline expires during the I/O.

Each durable Session identity also has a separate open-file lease. The descriptor
stays open for the lifetime of the Session and is unlocked on drain; a crashed
process releases it through the operating system instead of leaving a stale
marker that blocks recovery.

## Restart Behavior

`AgentJournal.load(from:)` validates the header, frame checksum, schema version and
strict sequence. Recovery is one of:

| State | Meaning | Prefix | Next durable write |
| --- | --- | --- | --- |
| `clean` | Every frame validated | Complete file | Append |
| `truncatedTail` | Final length header or payload was not written completely | Valid prefix kept | Truncate the incomplete tail, then append |
| `corruptTail` | The last complete frame has an invalid length, checksum, JSON, or sequence | Valid prefix kept; pending mutations stay inspectable | Throws `repairRequired` until `discardCorruptTail()` |

A checksum, sequence, or JSON error in a **middle** frame still fails the load.
Core does not skip a hole and keep reading. Crash-tail recovery never replays
tools or infers external success from model text.

Schema v3 is the current write format. Readers accept v1 and v2. Canonical
rollover preserves each retained record's legacy schema semantics rather than
relabeling it as v3. A v2 journal may contain the same idempotency key in
different Sessions because that schema predated journal-wide identity scope;
the v3 reader keeps those records and chooses the most conservative unresolved
state for new admission. It never re-executes a legacy collision.

After a safe runtime checkpoint, a durable journal larger than the internal
rollover threshold is rewritten to a canonical recovery snapshot. The snapshot
keeps one Session creation marker and the latest checkpoint per Session, plus
the lifecycle needed to reconstruct every mutation identity. Settled and
aborted mutations remain as tombstones so the current idempotency-conflict
contract survives restart; rollover does not redefine settled retry semantics.

Rollover writes and synchronizes a same-directory temporary file, atomically
renames it over the journal, then synchronizes the parent directory. The same
OS lock and full-record stale-writer comparison used by append protect the
rewrite. A truncated tail may be replaced from its validated prefix. A corrupt
tail still throws `repairRequired` until `discardCorruptTail()` is called.
Journal size is proportional to canonical recovery state rather than
checkpoint/audit history; it is not a permanent event warehouse.
Core also requires a meaningful reclaim window before rewriting, so a large
canonical mutation tombstone set does not cause a full-file rewrite after every
small checkpoint.

## Mutation Recovery

`AgentJournal` implements `ToolMutationAdmission` for durable sessions. Admission
stores the exact complete tool call, resource identities, idempotency key and
receipt expectation before an executor is reached:

```swift
let run = try await agent.makeSession(journal: journal).run("Update the listing")
```

`pendingMutations()` exposes only unsettled intents. `recoverPendingMutations()`
changes an `intent` to `needsReconciliation` after restart without invoking the
tool. `reconcileMutation` is the explicit trusted path for a quarantined intent.
`abortMutation` closes that intent without executing the original tool. A pending
mutation blocks another mutation in the same session until it is settled or
aborted, while other sessions remain independent.
