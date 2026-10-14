# Explicit native-to-ordinary context handoff

Issue #105 completed-turn handoff shipped in RC6. The explicit incomplete-turn
extension (#108) is a subsequent SDK increment. Storage and retirement-aware
runtime ship together; no automatic fallback, live qualification or Host
integration is implied.

## Host call order

Finish the current Run and call `waitForDrain()`. Stop and physically drain any
follow-up dispatcher; pausing retains its ownership. Use an explicitly capable
Journal (or perform the offline upgrade below). Prepare a frozen target binding,
its tools/capability scope, projector, token/byte budgets and deployment identity.
Then explicitly authorize omission of the retired provider continuation prefix:

```swift
let operation = try await session.handoffToOrdinary(
    using: targetBinding,
    discardingRetiredProviderContinuations: true)
let retirement = try await operation.wait()
try await operation.waitForDrain()
let nextRun = try await session.run("next real input", using: targetBinding)
```

If a target capability binding selects the tools, pass it to both handoff and the
later Run. Handoff does not replace the Session's default model binding. After
reopen, reconstruct the same Session ID with the target deployment/root binding;
use its persisted retirement rather than reconstructing authority from summaries.
The public fixture in `Examples/ExternalClient/Sources/NativeContextFixtureSupport`
shows the exact callable API, a deterministic source-bound summary, changed
registry/model, target thinking and a new native chain followed by reopen.

Handoff makes no HTTP request, admits no input and executes no tool. It preserves
canonical messages/IDs, opaque signed bytes, mutation identity and receipts,
pending state, Run terminals and usage. Only the request view omits continuation
blocks in the retired prefix. Future target continuations remain subject to their
normal compatibility checks; arbitrary/reencoded reinjection is refused. The new
control epoch uses the explicitly selected registry and does not replay old trusted
control entries. A later native checkpoint starts a new chain, not an ancestral
checkpoint. Host summary correctness is still the Host's responsibility.

Core verifies original Journal source IDs/digests before applying the authorized
ordinary view, then verifies projection pairing, continuation constraints and
final budgets. Cache prepared source material by original span digest, binding and
generator/configuration version; an ordinary view digest is not a replacement
for original source proof. Built-in summaries remain prepared transformations of
supported historical ranges; this feature does not enable arbitrary current-Run
tool-result excerpts or recover historical read-only proof from today's registry.

## Refusal and recovery

The original overload requires an idle, physically drained, provably completed closed
turn, no pending/quarantined mutation and matching durable history/native/control
witnesses. It refuses persistent trusted instructions, unanswered/incomplete turns,
unsupported stores, stale actors, queue ownership, invalid sources and incompatible
or over-budget target views. Existing Run-local compaction with required reminders
remains refused. No whole-Run retry or tool replay is performed.

Cancellation/deadline apply through asynchronous projection and the publication
seal. Capability scope is checked again after projection; that check authorizes
the wire baseline, not tool execution. Publication after sealing has the normal
definite-failure/commitUnknown semantics; late cancellation cannot undo committed
facts. `wait()` is logical completion; `waitForDrain()` also waits for late projector
work and releases writer/capability ownership. A cancelled waiter does not by
itself cancel the operation: call `operation.cancel()` explicitly.

A definite publication failure keeps old authority. `commitUnknown` blocks use of
the old actor: drain, inspect through a fresh Session/reopen and follow the actual
durable record. Do not assume completion or retry a mutation. Reconciliation still
uses verified receipt/output and a fresh same-ID Session on the same handle.

## Explicit incomplete-turn exit (#108)

A terminal Run can be incomplete without being unsafe to retire. After physical
`waitForDrain()`, explicitly choose this path for output truncation, cancellation,
refusal or a failed admitted Run:

```swift
let operation = try await freshSession.handoffToOrdinary(
    using: targetBinding, capabilities: targetScope,
    discardingRetiredProviderContinuations: true,
    allowingIncompleteTurn: true)
let retirement = try await operation.wait()
try await operation.waitForDrain()
// retirement.closedTurnProof records the real old terminal, not success.
let next = try await freshSession.run("new real input", using: targetBinding,
                                      capabilities: targetScope)
```

This requires a durable schema 14 store. Create one explicitly with
`AgentIncrementalJournal.createForIncompleteContextHandoff(at:operationDomain:)`
(or its `Async` variant). Default schema 3, the exact old creation function
references and the original completed-only handoff overload remain unchanged.
`journal.supportsIncompleteContextHandoff` reports format capability; it is false
for memory Journals and existing schema 12/13 stores.

To upgrade an existing schema 12/13 store, stop/drain **all** Runs, maintenance
operations and dispatchers, close every shared Journal owner, then call:

```swift
let upgraded = try AgentIncrementalJournal.upgradeForIncompleteContextHandoff(
    at: directory)
// Reconstruct same-ID Sessions on the returned handle; discard old actors.
```

The upgrade preserves store/session identity and all existing state, including
schema 13 file references. It uses the durable reader gate and bounded recovery
bridge. An uncertain format publication throws `commitUnknown`; reopen to recover
and inspect the actual format. Schema 11 needs the existing 11→12 upgrade first.
There is no automatic upgrade, downgrade, or schema 3–10→14 migration. Actual RC6
schema 13 readers reject schema 14 before inspect, append or maintenance writes.

The independent closed-turn proof binds the real user admission, original terminal,
store/session/Run identity and canonical history head/anchor. Publication rechecks
it, empty pending state and native/control/handoff identities in the same store
transaction. Ownership excludes physically active work. User-only, partial
assistant and fully settled tool-result tails are supported. Unmatched tool calls,
missing durable terminal (including crash-after-admission), pending/quarantined
mutations, persistent trusted instructions and stale actors remain refused.

Drain does not settle mutations. If effects are uncertain, use Host-verified
receipt/output or supported no-effect reconciliation, then create a **fresh same-ID
Session on the same handle**. Reconciliation may change history; the old actor
must remain stale. Handoff never reexecutes a tool or completes the earlier Run.
The explicit exit retires an unanswered reminder's authority, not a claim that the
reminder was fulfilled. The next real user supplies its own controls.

For this new path, future requests and reopened Sessions must match the frozen
target model, origin, root and registry (definitions, policies and initial/deferred
configuration). Normal same-Run deferred declaration expansion remains supported.
A different target requires another explicit handoff. Core still checks projector
source evidence, legal pairing, Provider continuation rules and final budgets.
Some target adapters may reject a user/tool tail or an empty assistant ordinary
view; that local preflight failure preserves the original authority.

`try await journal.conversationControlState(sessionID:)` reads current persisted
controls without relying on a Session cache. It is advisory and does not prove
physical drain, eligibility, semantic fulfillment or settlement. Combine it with
existing Run lookup for Host presentation; Core repeats its own checks when acting.
See the exported-API `NativeContextHostExample.incompleteOrdinaryHandoff()` fixture
for native signed history, truncation, schema 12→14, changed target/deferred tools,
exact canonical/terminal preservation and reopen.

## Queued reminders

The resolver may return `AgentFollowUpConfiguration(model:capabilities:
contextControls:)` with an explicit `AgentRunContextControls(reminder:)`. The old
initializer signature remains available. The dispatcher freezes one resolver
result and passes controls through normal preflight/admission; they are not
instruction text smuggled into persisted user input. Each real queued user gets
its own reminder. Resolution after reopen retains existing at-least-once resolver
semantics, not permission to replay admitted input or completed tools.

The public HTTP fixture covers two queued tool-loop replies, distinct reminders,
exact execution/admission counts, cancellation before dispatch and reopen. There
is no between-replies maintenance callback in this scope. Stop/drain the queue
before handoff/idle compaction. Long tool-loop maintenance remains a separate #105
task; no OtohaAI code or SDK pin is changed here.

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
