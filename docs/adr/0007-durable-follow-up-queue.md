# ADR 0007: Durable FIFO follow-up queue

Status: Implemented on `codex/rc4-follow-up-queue`; exact-head qualification is recorded in PR #22
Date: 2026-09-27

## Integrated baseline and scope

PR #20 (`033bf567b64ebd1b9dcee6f31ed8c2168600c694`) merged as
`3d25da6de66e36287f942bc6956ddceb6a789779`. PR #21
(`056c790e1f6d93b10989697914aa46a0e4eea94a`) merged on top as
`44e48f0783be0c467d45ac4b7d9f98c42e01718e`. This proposal is based on
that final `main` tree, `cda1c2f7bd5fa28bf15e8713166522ff4bbf0562`.
The main-line macOS, Linux and Apple CI jobs passed on that exact merge SHA.
The three original design documents were cherry-picked from local commit
`f12730ab8922d597d98216de1f96b486b59d7ae7` and corrected against the
integrated implementation. This branch now implements the first durable FIFO
slice; its final validation belongs to the PR's exact head, not the baseline CI.

Version one is FIFO within one Session. `run(_:)` still starts immediately or
rejects conflict; `run.steer(_:)` still corrects the current Run. An explicit
follow-up entry accepts a *future* input, with no prompt/history side effect
until a distinct, durable startup admission. There is no scheduler of tasks,
priority, timer, dependency graph, implicit retry or background OS guarantee.

## Facts, identities and state

A durable queue record is scoped by the actual persisted `storeID`, Session ID
and caller-stable `inputID`. The `operationID` is a separate caller-stable
logical mutation identity. Require a nonblank `operationID` on *all* queued
entries: the tool effect may be chosen only at dispatch time, and a mutation
retry must not silently fall back to a new Run/call key. Enqueue stores the
exact UTF-8 input, operation ID, and a bounded, non-authorizing configuration
reference. Those fields are the identity's immutable semantic payload. The
same key and equal payload returns its existing record/current status; a
different payload conflicts. Caller timestamps and resolver completion order
never assign order. A per-Session `nextQueueOrdinal` assigns monotonic FIFO
order under the store writer coordinator. Terminal `inputID` identities are
retained for the operation domain lifetime without TTL or silent reset.

Only three *durable queue* states exist: `queued`, `admitted(runID,
formalMessageID)`, and `withdrawn`. Preparing, resolving, executing, logical
termination and physical drain are facts of the actual dispatcher/Run owner,
not an independent success ledger. After restart, an admitted record with no
owned Run is *interrupted / needs Host inspection*, never queued again and
never automatically retried. Even if a prior Run may have finished, absent a
durable terminal fact the queue does not invent its outcome. The Journal's
trusted mutation state and Receipt remain separate.

The queue head also stores `lastAdmitted` and `lastReleased` ordinals. After
`.completed` **and physical drain**, the dispatcher durably releases the
admission barrier before taking another head; this records a Runtime ordering
fact, not Host fulfillment. A crash or abnormal outcome before that release
leaves the admitted item's original Run/message association and blocks later
heads on reopen. `resumeAfterInspection(inputID:)` is an explicit Host decision
to release that barrier **without** changing the item's admitted state or
replaying it. It rejects unresolved mutation records. Ordinary `resume()`
cannot clear the barrier. No queue state asserts that a business goal succeeded.

Start with durable-only enqueue. A missing/memory Journal returns a typed
durability error; no memory fallback or pretend cross-process recovery.
Per-Session bounds are 128 queued entries, 256 KiB UTF-8 per entry and 8 MiB
total queued text. A same-ID retry is checked before capacity. Full queues
fail without eviction. An admitted/withdrawn
identity does not count toward pending capacity but remains indexed.

## Single atomic queue-to-Run boundary

Extend the **existing** `AgentJournal` startup admission, not a second Run
engine. Prepare a Run ID, Host bindings and a candidate user message as now.
The new `JournalStoreView` startup operation atomically checks queue head,
status, queue revision and expected Session revision, then publishes one frame
containing both `queued → admitted(inputID, runID, formalMessageID)` and the
normal Session startup checkpoint / formal user message. The frame's checksum,
indexed locations, root and `CURRENT` have the same visibility boundary as
ADR 0004. It cannot publish half a queue transition. A rejected preflight
leaves the item queued and pauses dispatch. A commit-unknown result keeps an
owned failed Run and poisons unsafe writes until reopening and inspecting the
published root. Reopen distinguishes queued from admitted; it never infers
`notCommitted` merely from cancellation. A later explicit Host retry of an
admitted item retains its original association and `operationID`; no automatic
second Run is created.

Withdrawal checks the same queue state under the writer coordinator: a
reliably published withdrawal wins over admission; a reliably published
admission wins and returns its Run ID. An unknown publish must be inspected
after reopening before either outcome is reported as certain.

## Journal format and cost boundary

The integrated baseline opens format schema 1 and writes `BatchV1`. The new
runtime **creates and opens only format schema 2** with `BatchV2`. The
unchanged nested `DiskMessageV1`/`DiskMutationV1` DTOs remain explicitly
converted under the new batch boundary. `BatchV1` stores a Session header, formal messages, optional
mutation and record count; it does **not** persist arbitrary `AgentJournalEvent`
cases. `JournalStoreChange` increments the Session revision on every existing
publish. Merely adding an enum case or writing an adjacent queue file cannot
provide atomic admission. `BatchV2` carries a bounded queue delta and
independent per-Session queue head/next ordinal/revision. The managed
`queue-heads/`, `queue-ids/`, `queue-order/`, and `queue-links/` indexes resolve a Session head,
its full UTF-8 input identity and its ordinal without decoding another
Session's queue. The linked successor is a separate small delta: appending a
short item does not re-encode a previous large queued body. A bounded linked
queued chain finds the next dispatch head;
terminal ID/ordinal indexes remain. A queue-only commit changes queue state and
the store's logical position but **does not** increment the conversation
revision or invalidate an active Run's expected Session revision. The combined
startup batch checks both revisions at one publication boundary. Session B's
enqueue does not decode Session A's history. All records/large payloads and
their queue index references participate in the existing managed-file
integrity, maintenance and GC proof; do not retain a segment forever merely
because it once held a queued item. Normal enqueue encodes only its delta and
bounded index/root metadata, never a full queue or conversation.

Creating a new store uses schema 2. Opening a schema-1 store with the new
queue runtime returns typed `unsupportedFormat` and leaves bytes untouched;
opening schema 2 with an old reader must likewise reject it. No implicit
migration, reset, dual-writer mode or file-copy cutover is part of this
slice. The queue index positions and managed blob references participate in
segment packing, obsolete-pack cleanup and GC. Storage corruption or an
unrecognized format fails explicitly; neither path creates an empty store.

## Dispatch, re-binding, cancellation and drain

The Host explicitly starts dispatch; reopening a store leaves it paused.
One dispatcher claims `(storeID,sessionID)` within the existing Journal/Session
ownership boundary. Direct `run` during that claim rejects with a typed
dispatch-owned error; the dispatcher uses an internal queued-start entry into
the **same** `AgentSession.startRun` machinery rather than calling `run` in a
poll/retry loop. A second dispatcher or old Session instance cannot claim the
same head. The store's lifetime writer lock remains ADR 0004's same-machine
single writer; this proposal adds no distributed coordination.

For each head, the Host asynchronously resolves a *fresh* `AgentModelBinding`
and a **required** same-Session `AgentCapabilityBinding` from the configuration
reference; the existing tool path performs current authorization later. The
dispatcher builds a Run budget before resolver work. Persist no executor, credential, permission,
binding, closure or monotonic-clock instant. The resolver has an owned attempt
generation: pause/stop/cancellation invalidate a late result. If it ignores
cancellation, its worker and lease remain owned until physical exit. The Run
budget starts at actual dispatch preparation (including resolve and preflight),
not enqueue time. #20 source revisions/context budgets and #21 Session-instance
scope/generation, resource bounds, durable mutation prerequisite and final
execution admission still run normally. A revoked scope is never silently
replaced by a newly created one; the Host must explicitly approve another
binding. Model text or a queue configuration label creates no authorization.

`pause` stops future dispatch without cancelling the current Run. `stop`
stops admission and cancels the owned resolver; it does not by itself erase
queued records or cancel a current Run. `cancelCurrent` delegates to
`AgentRun.cancel()`. `waitForDrain` waits for accepted queue I/O, resolver,
startup, Run physical drain and the dispatch claim/lease release; it does **not**
wait for every queued item to be consumed. One cancelled waiter observes only
its own cancellation. No new consumer of `AgentRun.events` is installed;
one existing Host consumer may fan out display/usage/ExecutionReport facts.

The dispatcher may advance after `.completed` and physical drain only. A
refusal, incomplete response, failure, cancellation, `commitUnknown`, resolver
error, or uncertain recovered state pauses dispatch without skipping or
auto-retrying the head. Runtime completion does not establish Host business
fulfillment. `journal.close()` rejects an active dispatcher/Run/resolver lease;
after stop and real drain a sole-user store can close, while another Session's
valid work still prevents close. No store transaction/lock spans Provider,
resolver, executor or drain awaits.
