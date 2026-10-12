# Context handoff storage preparation

Status: unreleased storage prerequisite for issue #105. The Session-level
native→ordinary handoff and queued reminder API are dependent implementation in the same PR/candidate;
creating or upgrading a store alone does not retire any native checkpoint,
thinking payload or trusted control.

## Explicit store capability

The old `AgentIncrementalJournal.create` overloads retain their exact signatures.
Default creation still writes schema 3. `supportsNativeContext: true` still
writes schema 11. The new required-label overload opts into schema 12:

```swift
let journal = try AgentIncrementalJournal.create(
    at: directory, operationDomain: "my-host", supportsContextHandoff: true)
```

Schema 12 includes the existing native-context capability. The read-only
`journal.supportsContextHandoff` reports the store capability; it is not proof
that an individual Session has completed a handoff. Memory Journals support the
capability without an on-disk schema.

## Offline schema-11 upgrade

This format upgrade is a whole-store operation. Drain all Runs, compaction
operations and queue dispatchers, then close the shared Journal. Do not keep an
old handle or old Session for further use. Upgrade explicitly and reconstruct
Sessions with the returned handle:

```swift
try await journal.close() // only after every owner's physical drain
let upgraded = try AgentIncrementalJournal.upgradeForContextHandoff(at: directory)
// Reconstruct Sessions with their original IDs and the new handle.
```

An owned store returns `storeInUse`; default ownership remains fail-fast. Only
schema 11 can be upgraded by this API. Schema 3–10 and already-schema-12 stores
are not implicitly migrated. Opening a store never opts an ordinary old store
into schema 12.

The operation preserves store identity, operation domain, canonical message
IDs/content, native checkpoints, controls, queue state, mutation evidence and
Run records. It creates an identical-content root bound to the new format,
publishes the schema-12 reader gate, then publishes `CURRENT`, under the existing
whole-store writer lock. Normal opening still validates/truncates unpublished
physical tails before the separate upgrade begins.

A failure before the format gate leaves schema 11 authoritative; an unused
prepared root may remain. Once format replacement may have occurred, failure
returns `commitUnknown`. Reopen with the new reader to inspect/recover the actual
durable state. Do not retry an uncertain upgrade as if it definitely failed.
The new reader can finish only the exact old→prepared-root transition recorded
in the format gate. It validates the old root, identical prepared root and
shared committed layout/frame evidence before changing `CURRENT` or truncating.
Missing/altered evidence fails closed. Later ordinary publications and
maintenance do not depend on retained ancestor root files.

## Reader compatibility

| Store | New reader | Prior schema-11 reader |
| --- | --- | --- |
| Default schema 3 | Existing read/append behavior, no handoff capability | Existing behavior |
| Native schema 11 | Existing behavior, no handoff capability | Existing behavior |
| Explicit schema 12 | Read/append/maintenance; handoff storage capability | `unsupportedFormat` before writes |
| Explicitly upgraded schema 12 | Same, preserving existing identity/facts | `unsupportedFormat` before writes |

The compatibility gate compiles the fixed pre-handoff schema-11 reader at
`8b896eae05b5fd838e61e67a6cb69ca7c0e78458` and checks inspect, append and
maintenance against empty, populated and upgraded stores, both before and after
new-reader maintenance. Rejection must leave all bytes unchanged. This is
reader compatibility evidence, not live Provider qualification.

Reconciliation on an unchanged supported Journal remains a different operation:
after physical drain and verified reconciliation, create a fresh Session on the
same handle. It does not require this offline format upgrade or closing the
shared Journal. See [mutation recovery](swift-agent-mutation-recovery.md).
