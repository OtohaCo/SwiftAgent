# Durable follow-up inputs

## RC6 candidate: required audit on queued work

Required audit also checks configuration, storage and backlog before enqueue or
candidate input publication. Dispatch remains a new Run with current model,
capability and authorization decisions; durable approvals never revive live
permission. A failed audit store refuses new work while an already admitted
mutation retains settlement/drain ownership. See
[Audited Authorization](swift-agent-authorization-audit.md).

`AgentSession.enqueueFollowUp(_:)` durably receives *future* user input. It
does not call a model or append to the formal conversation. `session.run(_:)`
still starts immediately (or rejects overlap); `run.steer(_:)` still corrects
the current Run. This queue is FIFO within one Session and is available only
with a schema-3 `AgentJournalFileStore` durable Journal. A memory-only Agent
can still run read-only work without a queue.

## Public API and identities

`AgentFollowUpInput` has a stable caller-supplied `inputID`, exact UTF-8 text,
nonblank `operationID` and bounded `configurationRef`. The identity scope is
the **actual store ID plus Session ID**; the operation ID names a separate
logical tool effect. Repeating the same input ID and identical payload returns
the existing ordinal and *current* state. Different text, operation ID or
configuration reference conflicts. Terminal IDs remain indexed for the life
of the store's operation domain; there is no TTL or reset. A second directory
with the same domain label has a different store and cannot share deduplication.

The default per-Session pending bounds are 128 queued items, 256 KiB of text
per item and 8 MiB of queued text. An exact same-ID retry is checked before
capacity. `followUps(after:limit:)` is a throwing page query with an exclusive
ordinal cursor and maximum page size 100. Its bounded record omits text;
`followUpText(inputID:)` is an explicit private-body read. Neither queue
diagnostics nor `configurationRef` is permission, Evidence, a Receipt or a
complete request log.

The durable states are `queued`, `withdrawn`, and `admitted(runID,
formalMessageID)`. Withdrawal wins only before the combined startup commit;
after that boundary it returns `.alreadyAdmitted` with the real association.
If it wins while the resolver is still running, the dispatcher confirms the
selected store/Session/input/ordinal and waits for startup cleanup before
advancing to the next FIFO item. A true writer conflict or unknown publication
still pauses; a withdrawal is never inferred from a generic conflict error.
Cancellation of that Run does not undo the formal input. A queue-only commit
does not advance conversation revision or change the active model context.

## Dispatch and current approval

The Host starts one dispatcher explicitly, then supplies a resolver that
returns a **fresh** `AgentModelBinding` and a **required** Session-bound
`AgentCapabilityBinding`. The persisted configuration reference is only a
lookup hint; it never restores a provider client, executor, scope, credential
or old `allowed` decision. A resolver failure cannot fall back to the Agent's
default tool registry. Context source revision and byte/token budgets, tool
authorization, Evidence, resource bounds and durable mutation intent are
checked in their existing execution paths. The Run timeout starts before
resolver work, so it includes resolution and preflight; queue waiting has no
process-clock deadline persisted across restart.

The credential-free, runnable [ExternalClient fixture](../../Examples/ExternalClient/Sources/FollowUpQueueFixture/main.swift)
shows two Sessions sharing one Journal and scheduler, a blocked current Run,
enqueue/withdraw, physical drain, a paused and reopened queue, fresh project
capabilities, a real temporary-file mutation and a stable-operation replay.
Run it without network access:

```sh
swift run --package-path Examples/ExternalClient FollowUpQueueFixture
```

Only one dispatcher owns a `(storeID, Session ID)` pair. Direct `run` while
it owns the Session returns `dispatchOwned`; another Session can keep using
the same Journal and scheduler. Pass `onRun` to `startFollowUpDispatch` to
receive each admitted `AgentRun` with its input record. That callback owns the
**single** `run.events` consumer and may feed the existing
`ExecutionReportReducer`; the dispatcher observes `wait()` and
`waitForDrain()` without competing for events. The callback is asynchronous
and is owned through physical drain. Without `onRun`, the dispatcher consumes
and discards progress in headless mode. Queued Run streams retain at most 256
unconsumed progress events; a slow observer can lose intermediate events, so
use the Journal for trusted Receipt/output and do not treat a partial event
report as the durable ledger. After `.completed` *and physical
drain*, it records an ordering release and may dispatch the next queued item.
Runtime completion is not Host business fulfillment.

The [ExternalClient public API test](../../Examples/ExternalClient/Tests/ExternalClientTests/ExternalClientTests.swift)
shows the complete `onRun` callback: the `inputID` links the delivered Run
to its durable queue record, and the single event consumer feeds the existing
`ExecutionReportReducer` without controlling mutation settlement.

`pause()` cancels a pending resolver/startup but does not cancel an admitted
Run or release the consumer claim. `resume()` is explicit. `stop()` prevents
future starts and cancels outstanding preparation; `cancelCurrent()` separately
requests current Run cancellation. Call `stop()` and then
`waitForDrain()` before trying to close a sole-user Journal. One cancelled
waiter cannot release the actual resolver/Run owner. A resolver that ignores
cancellation remains owned until it actually exits. If another Session still
uses the shared Journal, `close()` correctly refuses its lease.

On reopen there is **no automatic dispatch**. An admitted item whose prior
Runtime completed-and-drained ordering release is missing stays linked to its
original Run/message and blocks later items. It never returns to `queued` and
is not automatically re-executed. `resume()` reports `needsInspection`. After
current Host inspection, `resumeAfterInspection(inputID:)` may permit **later**
items, provided no unresolved Session mutation remains. It does not mark the
old Run successful, abort an external effect, or retry that item. Use the
existing Journal reconciliation and stable operation ID rules for an unknown
mutation. Receipt/output/conversation settlement remains in the Journal.
Manual pause during an unfinished Run is not an interrupted admission; the
inspection release rejects it. An inspection accepted before `stop()` may
publish its ordering release, but its late return cannot restart the stopped
dispatcher. `waitForDrain()` continues to own that accepted storage operation.
An existing direct Run captured when dispatch starts must complete normally
and physically drain before dispatch advances; refusal, incomplete, failure
and cancellation pause the queue for explicit Host action.

## Disk format and failure handling

New stores use `format.json` schema 3 with `BatchV2` queue deltas and managed
`queue-heads/`, `queue-ids/`, `queue-order/` and `queue-links/` indexes. The
successor link is a small delta, so a new short item does not rewrite the
preceding large input body. The unchanged nested
message/mutation DTOs remain explicitly converted under this batch format.
Schema-1, unreleased schema-2, unknown future schemas and older framed Journal files are
rejected without overwrite, reset, memory fallback or implicit migration.
Old binaries reject schema 3 before writing. A queue admission, Run ID and
formal user message publish in **one** checksummed startup frame and one
`CURRENT` visibility boundary. Queue-only writes touch the queue revision,
not the Session conversation revision. Physical packing may reclaim obsolete
process files after the current indexes retain queued text, terminal inputID
identity, admitted links and all mutation facts. Total disk usage can still
grow with genuinely retained inputs and operation identities.
Schema 3 adds a first-publication witness in a separate managed shard for the Session, queue-head,
queue-ID and operation index files. A missing committed index cannot be read
as an empty Session/queue/ledger; the store fails explicitly. A witness from a
failed, unpublished transaction does not create an input or block a different
first-use identity. These per-key checks do not scan the whole store.

If a write result is `commitUnknown`, stop writing through that poisoned
handle, reopen and query the same input ID; do not allocate a new ID or infer
noncommit from cancellation. Permission, corruption and disk-full failures
remain explicit. The independent-process `SIGKILL` fixture tests process
termination and uncertain external effects, **not** power-loss durability.
After stop and actual drain, a poisoned Journal can be closed to release the
writer lock; this does not settle or undo its uncertain batch. Retained old
Session objects cannot start work through that closed handle. If close fails,
ownership remains with the old handle until a successful retry.
This local single-writer format is not cross-device replication or an OS
sandbox. See [ADR 0007](../adr/0007-durable-follow-up-queue.md) and
[mutation recovery](swift-agent-mutation-recovery.md).
