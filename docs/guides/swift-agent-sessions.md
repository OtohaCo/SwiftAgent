# SwiftAgent Sessions and Runs

## Reading a reopened Session

`await session.history` returns the currently loaded in-memory view. It does
not initiate Journal restoration or report storage failures. Current runtime
instructions can make it nonempty before restoration; neither an empty nor a
nonempty array establishes whether a disk conversation exists.

Use the throwing snapshot API when resuming a durable conversation:

```swift
import AgentCore
import AgentJournalFileStore

let reopenedJournal = try AgentIncrementalJournal.open(at: hostStoreDirectory)
let resumed = try agent.makeSession(id: savedSessionID, journal: reopenedJournal)
let snapshot = try await resumed.conversationSnapshot()
// snapshot.messages restores formal history and uses this Agent's current instructions.
// A missing/damaged/closed store throws; it is not treated as an empty conversation.
```

The snapshot revision belongs to this live Session actor, not a durable commit
counter. See [Context](swift-agent-context.md) for candidate preflight and
projection source coordinates. This does not change synchronous history access
or introduce asynchronous Session construction.

## RC6 candidate: Host-enforced audited authorization

`AgentConfiguration.authorization` defaults to legacy. Required audit is
immutable Agent/Session factory configuration, with no Run downgrade. It
requires schema-5 durable storage, a Host authorizer and identity before input
commit or Provider contact. Every model tool, including bound/runtime-defined
read-only tools, is covered. Subsequent Runs, follow-up dispatch and settled
replay evaluate current permission. Run/scope drain retain a slow authorizer
until physical exit; exporters have separate owners/leases. See
[Audited Authorization](swift-agent-authorization-audit.md).

last-verified: 2026-09-27

Agent holds Sendable configuration: provider, model, typed tools, instructions,
structured-output schema, default run limits and a shared scheduler. Each
`try agent.makeSession()` creates an independent actor with its own canonical
message history and active-run ownership. Mutation tools require a journal with
`storage == .durable` at this point; `nil` and memory-only journals throw
`AgentSessionError.durableJournalRequired` before any model turn.

```swift
import AgentCore
import AgentModels
import AgentTools

func converse(
    model: ModelID,
    provider: any ModelProvider,
    tools: [any AgentTool],
    render: @Sendable (AgentEvent) async -> Void
) async throws -> AgentLoopResult {
    let agent = try Agent(
        model: model, provider: provider, tools: tools,
        instructions: "Use verified tool results."
    )
    let session = try agent.makeSession()
    let run = try await session.run("Find the resource and calculate the total.")
    for await event in run.events { await render(event) }
    _ = try await run.wait()

    let next = try await session.run("Continue with the same conditions.")
    for await event in next.events { await render(event) }
    return try await next.wait()
}
```

Advanced limits, structured output, and a shared scheduler go on
`AgentConfiguration`. Do not pass them as extra `Agent` initializer arguments.

Tool authors pass concrete AgentTool values; Agent creates their erased registry.
Default timeouts are relative to each run's start. `session.run(_:budget:)` can
supply an explicit per-run budget instead. Empty input, cancelled callers and
already-expired budgets do not append user input or start work.

Share the Agent's `ToolScheduler` whenever another Session can mutate the same
host resources. Two Agents that control one account or one file store must be
constructed with the same scheduler value.

For a *future* user input, use the explicit
[durable follow-up queue](swift-agent-follow-up-queue.md). Enqueue does not
change the current Run or formal history. The dispatcher requires a fresh
Host-approved model and capability binding, waits for physical drain, and
holds a distinct consumer claim. Direct `run` remains immediate and returns
`dispatchOwned` while that dispatcher is active; `run.steer` still targets
only the active Run. A queued input becomes a formal user message only in the
same durable frame that binds its Run ID.

## Run-scoped capability binding (RC4)

An Agent may have no default tools and bind an immutable tool set for one
Session Run. The Session creates the binding, tying it to that Session
instance rather than only a reusable UUID. The Host supplies tool and backend
versions plus exact `ToolResource` identities. The model's tool definitions,
token estimator, typed preparation and actual executors use the bound registry.
A newer binding affects only a later Run.

```swift
let scope = try await session.bindCapabilities(
    identity: "project-B", version: "v1",
    backendInstanceID: "local-workspace", backendVersion: "v1",
    allowedResources: [.named(.init(namespace: "workspace", id: "project-B"))],
    tools: [.init(id: "write", version: "v1", tool: writeTool)]
)
let run = try await session.run("Update the project", capabilities: scope,
                                operationID: "stable-logical-update")
await scope.revoke()
_ = try? await run.wait()
try await run.waitForDrain()
try await scope.waitForDrain()
```

`revoke()` stops **new final execution admissions** and requests cancellation;
it does not assert an in-flight external effect was rolled back. A call that
obtained admission first keeps its cleanup and settlement owner until drain;
a call waiting for resources, Host authorization or durable intent cannot
enter the executor after revoke. `waitForDrain()` separately observes the
actual exit, including startup preflight and the bound Run's Journal lease and
Session identity release. A cooperative startup projector or estimator receives
revocation before the normal Run worker exists; uncooperative work keeps the
lease until it actually returns. A committed user input retains an owned Run
even if revoke races worker installation. Cancelling one waiter cannot release
the Journal lease. Scope
status counts Run reservations and admissions; admission does not prove
executor entry or a file write. Diagnostic `AgentCapabilityInfo` is not a
recoverable permission credential.

A bound tool can be `.deferred`: bound, but its definition is sent to the model
only after a tool result of the same Run declares it. An undeclared call fails
as an unknown tool. See [Deferred Tools](swift-agent-tools.md#deferred-tools-unreleased).

Explicitly bound mutation tools recheck durable Journal availability before
candidate input is committed, even when the Agent has no default mutations.
The Session shares its scheduler and Journal across scopes. New scope versions
do not alter operation identity; two scopes touching one file or account must
declare the same real resource identity. The Host closes shared backends only
after all users drain. See [ADR 0006](../adr/0006-run-scoped-capability-binding.md)
and the no-network [ExternalClient fixture](../../Examples/ExternalClient/Sources/ScopedCapabilityFixture).

## Operation Identity and Mutation Retries

`session.run(_:budget:operationID:)` accepts a logical operation identity. Reuse
the same non-nil `operationID` for attempts that mean "perform this same mutation
once." Within one open durable store, mutation deduplication is shared across
Sessions and Runs. A matching domain label in another directory does not
share that ledger. Its key combines the stable operation ID, tool name,
and canonical semantic JSON arguments; it excludes tool call ID, Session ID, and
Run ID. JSON objects with different key ordering, equivalent numeric spellings,
and equivalent JSON string escapes are the same identity.

Passing nil or blank `operationID` uses a per-call identity. That keeps one call
internally coherent but intentionally provides no cross-run deduplication.

The journal lifecycle controls retry admission:

| Latest state | Retry behavior |
| --- | --- |
| `intent` | Fails closed with `AgentJournalError.mutationPending` |
| `needsReconciliation` | Fails closed with `AgentJournalError.mutationRequiresReconciliation` |
| `settled` | Reuses the original receipt and does not invoke the executor |
| `aborted` | Starts a new durable lifecycle for the same logical operation |

`aborted` is not a synonym for cancelled or unknown. The trusted Host calls `abortMutation(_:confirmedNoEffect:)` only after
explicitly confirming that no external side effect occurred and providing a
nonempty basis. Settled and aborted identities are retained indefinitely in the shared
journal domain.

Authorization and Evidence requirements are currently checked before replay
admission. A settled retry therefore still must satisfy current policy. On a
settled replay, the runtime returns the original durable canonical JSON output,
validates it against the current tool output schema, records the original
receipt, and uses the current tool call ID in the transcript and run result.
Hosts reconciling an uncertain mutation provide a trusted receipt and the
canonical replay output. Uncertain effects are never re-executed automatically.

## Ownership and History

A Session rejects overlapping requests with `AgentSessionError.runInProgress`.
It neither queues them nor supersedes the existing run. Other Sessions continue
independently. New runs get distinct IDs; their tool contexts retain the Session ID.

History is readable and not assignable. Restoration reads the indexed Session
messages from the open store, never a caller-supplied array. `activeRunID` is similarly readable only.

Accepted user messages are saved immediately. The loop commits safe checkpoints
to Session history. When a tool batch fails partway through, history retains only
the completed proposal/result pairs. Pending or invalid proposals and provisional
model deltas are not made into canonical tool history. A run's terminal response
can still contain interrupted proposals for diagnostics.

History is committed before `runFinished` is published. That is the logical
terminal: `run.wait()` returns, and the event stream closes. It does not mean
provider or tool work has exited, or that the Session identity is free.

`try await run.waitForDrain()` waits for that physical release. The same owner is
exposed as `session.waitForRunToDrain(runID:)`. Do not start a second drain.
A replacement Session with the same ID must wait until drain completes;
`runInProgress` is the typed rejection if it tries to run earlier.

Late work from an older cancelled run cannot overwrite history belonging to a
newer run. The Session keeps its active conversation in memory; formal messages
and the mutation ledger are persisted independently of request projection.
Segment packing is physical maintenance, not conversational summary. See [Context Policy](swift-agent-context.md).

## Run Control

The public Run surface is `events`, `cancel()`, `steer(_:)`, `wait()`, and
`waitForDrain()`. The backing Task and scheduler handles are not exposed.

```swift
let result = try await run.wait()
try await run.waitForDrain()
```

`await run.cancel()` requests cancellation idempotently. Wait for `run.wait()`
before treating the Run as logically finished. Wait for `waitForDrain()` before
reusing the Session ID or assuming host executors have returned. Cancellation
does not roll back external effects. A host operation that ignores cancellation
may finish later; its result cannot advance the run or alter the Session.

`try await run.wait()` returns the cached AgentLoopResult or throws the original
error. Multiple callers can wait independently. Cancelling one waiter only ends
that wait. The result still distinguishes completed, refused and incomplete.

`try await run.waitForDrain()` follows the same observer rule: cancelling one
waiter throws `CancellationError` only to that caller. Provider/tool drain,
Session identity release, and other drain waiters continue under the Session's
single physical owner.

`run.events` is a single-consumer stream, not a replay or broadcast subscription.
It may be consumed while the run executes or drained after it finishes. Cancelling
the observer disconnects that stream but does not cancel its owned Run; use explicit
cancel when execution should stop. The typed event ordering is in
[Agent Events](swift-agent-events.md).

## Steering

`try await run.steer(text)` accepts a correction and returns its UUID. Blank input
is rejected. A run that is cancelled or has sealed its terminal decision rejects
new corrections with `AgentRunError.finished`, even if terminal delivery is pending.

Corrections are delivered FIFO at safe checkpoints: before a model request, after
a model response and between tool batches. A correction arriving during model
generation discards unexecuted proposals and requests replanning. Once a tool batch
has begun, steering does not split it; the correction follows its results. Steering
uses the same budgets and never resets model-turn limits.

`steeringApplied(id:text:)` reports application to the run context, not a promise
that a later provider request will succeed. Corrections accepted before cancellation
or failure but never delivered are committed to the Journal with their IDs before
the Run ends, so the Session and a reopened Journal agree. Stable IDs prevent
duplication across the checkpoint/acknowledgment boundary. Such retained inputs
need not have a steeringApplied event.

If that commit fails, the Run reports the Journal error instead of its own outcome.
After a definite failure the corrections stay owed and join the next Run's admitted
input ahead of its text. After `commitUnknown`, only the Journal can say whether
they became history: the Session refuses `conversationSnapshot()`, context
provenance and new Runs until the Journal is closed, reopened and inspected. Full follow-up queues
and configurable drain policies remain separate from this Run control API.

## Same-Run confirmed conflict correction (implemented, unreleased)

[Confirmed no-effect mutations](swift-agent-confirmed-no-effect.md) retain the
original turn/call/deadline budgets, require new invocation and authorization,
and commit paired feedback before continuing. Restoring a Session does not
execute old calls; unknown/pending still requires reconciliation.
