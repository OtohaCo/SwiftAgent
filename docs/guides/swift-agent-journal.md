# SwiftAgent Journal

last-verified: 2026-09-18

`AgentJournal` is the Core-owned typed lifecycle log. It records provider-neutral
messages, model attempts, tool proposals/results, checkpoints, compaction summaries
and run outcomes. Journal events are not a UI timeline and contain no Otoha or
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
_ = try await session.run("Update the listing").wait()

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
in memory.

Each durable Session identity also has a separate open-file lease. The descriptor
stays open for the lifetime of the Session and is unlocked on drain; a crashed
process releases it through the operating system instead of leaving a stale
marker that blocks recovery.

## Restart Behavior

`AgentJournal.load(from:)` validates the header, frame checksum, schema version and
strict sequence. A partial final frame is treated as an uncommitted crash tail and
is excluded from the snapshot; a later durable append truncates that tail before
writing. A checksum or schema error in a complete frame is not ignored. The journal
does not replay tools or infer external success from model text.

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
