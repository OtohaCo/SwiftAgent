# SwiftAgent Sessions and Runs

last-verified: 2026-09-18

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
host resources. Two Agents that control one player or one file store must be
constructed with the same scheduler value.

## Ownership and History

A Session rejects overlapping requests with `AgentSessionError.runInProgress`.
It neither queues them nor supersedes the existing run. Other Sessions continue
independently. New runs get distinct IDs; their tool contexts retain the Session ID.

History is readable and not assignable. Restoration uses a journal checkpoint,
never a caller-supplied array. `activeRunID` is similarly readable only.

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
newer run. History is in memory; durable journaling, restoration and compaction
are separate concerns. See [Context Policy](swift-agent-context.md).

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
or failure are retained in Session history even if they could not be delivered.
Stable IDs prevent duplication across the checkpoint/acknowledgment boundary.
Such retained inputs need not have a steeringApplied event. Full follow-up queues
and configurable drain policies remain separate from this Run control API.
