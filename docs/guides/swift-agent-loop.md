# SwiftAgent Agent Loop

last-verified: 2026-09-20

The package-internal loop owns the single model-to-tool-to-model cycle. Public
clients do not construct it. Use `Agent`, `AgentSession` and `AgentRun`. Providers
produce one normalized response per call; tools receive typed inputs through the
registry. Neither owns another agent loop.

```swift
import AgentCore
import AgentModels
import AgentTools

func respond(
    provider: any ModelProvider,
    model: ModelID,
    tools: [any AgentTool],
    text: String
) async throws -> AgentLoopResult {
    let agent = try Agent(model: model, provider: provider, tools: tools)
    let session = try agent.makeSession()
    return try await session.run(text).wait()
}
```

## Turn Contract

The loop consumes the [Model Event Contract](swift-agent-model-events.md) through a
clean EOF before dispatch. Provider namespace, configured capabilities and response
model identity must agree. Structured-output requests are forwarded to the provider
on every turn; the loop does not implement a second provider output decoder.

For a tool response, the entire batch must fit the remaining budget and pass
registry preparation, including Swift input decoding. Unknown tools, malformed
arguments and input values outside a Swift type's range stop the batch before any
executor starts. Call IDs cannot be reused from the supplied history or earlier
turns in the run. Adapters must issue stable, unique call IDs.

The [tool scheduler](swift-agent-scheduler.md) overlaps independent read-only groups
and applies sequential/exclusive barriers. The assistant proposal and validated
tool results become the next request's messages in original call order, regardless
of completion order. Every result retains its call ID. A failure stops later groups
and model turns after already-started reads settle; no automatic retry, provider
fallback or fabricated success message is introduced.

`AgentLoopResult.outcome` distinguishes normal completion, refusal and incomplete
responses. Model cancellation throws CancellationError. Inspect the outcome rather
than treating every returned result as a completed user goal. `response` retains
the final normalized model response, including interrupted proposals; `history`
contains model-ready messages and omits those unexecuted proposals. Empty terminal
content does not add an empty assistant message. This history is not a journal or
a mutation receipt.

## Startup, Budgets and Cancellation

`AgentSession.run` starts the absolute Run budget before asynchronous restore,
projection, token estimation or Provider request preparation. A
preflight that reaches the deadline fails with `AgentLoopError.deadlineExceeded`
before the new user message is journaled or appended to canonical history. A
preflight result that arrives after the deadline is discarded. If a projector or
estimator ignores cancellation, the Session retains its startup reservation
until that operation actually exits; a replacement Run cannot overlap it.

Caller cancellation remains `CancellationError`. A failed startup does not
create a visible `AgentRun`, mutation intent, Evidence, Receipt or Provider
request.

`maxModelTurns` includes the final answer turn. The loop does not dispatch a tool
batch unless another model turn remains. `maxToolCalls` applies across turns and
is checked for the whole batch. Both limits are finite integers; model turns must
be positive and tool calls may be zero.

The absolute run deadline uses ContinuousClock. Each tool gets the earlier of the
run deadline and its policy timeout, beginning at dispatch and including
resource waiting and authorization. The effective deadline is checked before starting work and is
carried in ToolContext through authorization, execution and output validation.
Prepared calls can narrow a context deadline, never extend it.

A deadline or caller cancellation settles the run once and cancels pending work.
The caller does not wait for a host operation that ignores cancellation. Such an
operation may still run until it cooperates or finishes; its late result is
discarded, and it cannot advance another tool or provider turn. Host adapters must
connect cancellation to their underlying requests. Timeouts do not undo external
effects. Resource isolation lasts until the real invocation exits. Mutation remains
blocked by the integrity boundary until durability/recovery prerequisites are met;
read-only receipt-required tools use the validated receipt path.

## Ownership

The loop is package configuration behind `Agent`. History, counters, deadlines and
call IDs are local to each Session run. Cancelling one run does not cancel another
run using the same Agent. The host supplies session identity and may supply a
stable run ID; otherwise a new UUID is generated. Tool idempotency keys combine
the run and call identities.

[AgentSession and AgentRun](swift-agent-sessions.md) provide those ownership and
in-memory history boundaries while invoking this same loop.

The same loop exposes [Agent Events](swift-agent-events.md) for incremental progress
and typed terminal outcomes. That stream defines observation and cancellation
semantics independently of any UI framework.
