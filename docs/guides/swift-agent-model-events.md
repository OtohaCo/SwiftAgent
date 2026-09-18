# SwiftAgent Model Event Contract

last-verified: 2026-09-18

This contract applies to one normalized model response, produced by a provider
adapter and consumed by the agent loop. The data types live in
[ModelEvent.swift](../../Sources/AgentModels/ModelEvent.swift); the
replay validator is
[ModelEventAccumulator](../../Sources/AgentModels/ModelEventAccumulator.swift).

## Ordering

1. Exactly one `responseStarted` opens the response.
2. Text, reasoning, tool lifecycle and usage events may interleave.
3. Each tool ID has one `toolCallStarted`, zero or more argument deltas, and at most
   one `toolCallCompleted`. Argument deltas concatenate in arrival order. The
   completed call must match the started name and accumulated arguments exactly.
4. Exactly one `responseCompleted` closes the response. Its info, content, calls
   and usage must match the accumulated events. No events may follow it.
5. The consumer must reach a clean stream EOF, then call `finish()`. A protocol
   error permanently invalidates that accumulator. EOF without a terminal event
   also invalidates it. A new response needs a new accumulator.

Adjacent deltas of the same content kind coalesce into one content part. Text and
reasoning remain separate, in their relative arrival order. Tool calls retain
their start order even when completion events arrive out of order.

Tool call IDs are opaque UTF-8 identities. IDs, tool names and raw argument text
must match byte for byte at completion and in the terminal response. Canonically
equivalent Unicode spellings remain distinct; no normalization repairs a mismatch.
ToolCallID and ToolCall equality and hashing follow that same rule.
Model IDs and response IDs also use exact UTF-8 identity.

`providerContinuation` carries model/format ownership and opaque bytes needed by
the provider on a later turn. Ownership must match the started response; format
and payload must be nonempty. Its corresponding ModelContent part is preserved in
canonical history, but Core never parses a native frame from it. A provider must
validate a restored snapshot against its canonical message before reuse. These
bytes are not user-visible text, tool authorization, evidence or receipts.

If Core discards proposed calls, including partial-batch checkpoints and interrupted
turns, it also removes continuation state bound to the original whole response.
Context transforms that modify a message must likewise invalidate its opaque state.

Usage events are cumulative snapshots, not increments. A reported field replaces
its previous value; a nil field leaves the previous report unchanged. Every
reported counter must be nonnegative and may only stay equal or increase. Adapters
receiving native usage increments must accumulate them before emitting normalized
usage. Terminal usage must match this merged snapshot.

Totals may arrive later than their subsets, so intermediate snapshots can be
incomplete. At the terminal boundary, cached input and cache-write counts must each
not exceed a reported input total, and reasoning must not exceed a reported output
total. Absent totals remain unreported, not zero or inferred values. Providers must
normalize provisional estimates before reporting authoritative cumulative counts.

If a native provider only sends a final snapshot, its adapter emits the equivalent
normalized start/delta/completion events before the response terminal. Native
frames and provider-specific fallback logic do not enter this contract.

## Completion and Tool Safety

`toolCallCompleted` requires `.complete` and syntactically valid JSON object
arguments. Syntax checking uses the package's JSONValue numeric range. Registry
schema validation, authorization, evidence, timeout and receipt checks remain
required before execution.

The shared parameter decoder also rejects duplicate object keys and canonically
equivalent Unicode keys that Swift dictionaries would otherwise merge.

| Stop reason | Tool calls in the normalized response |
| --- | --- |
| `toolCalls` | Nonempty; every call has a valid completion event |
| `endTurn`, `stopSequence` | None |
| `maxOutputTokens`, `refusal`, `cancelled`, `unknown` | Completed and/or incomplete calls retained for diagnostics; do not dispatch this batch |

A syntactically closed JSON object does not imply transport completeness. A call
without its completion event remains `.incomplete`. Partial arguments are retained
verbatim; neither the adapter nor the accumulator repairs JSON or invents missing
fields. A malformed completion event is a protocol error, not a successful tool
proposal. An unfinished call at a normal tool stop is also a protocol error.

`ModelResponse` is transport data, not a trusted execution receipt. The agent loop
may consider calls for dispatch only after successful validation and a clean EOF,
and only for `stopReason == .toolCalls`. It must not dispatch a completed subset of
an interrupted batch or act directly on `toolCallCompleted` events.

## Consuming a Stream

```swift
try Task.checkCancellation()
var accumulator = ModelEventAccumulator()
for try await event in events {
    try Task.checkCancellation()
    try accumulator.append(event)
    // Forward deltas for presentation; do not execute tools here.
}
try Task.checkCancellation()
let response = try accumulator.finish()
```

Transport errors and cancellation propagate from the stream. Do not catch them
and then call `finish()`, even when a terminal event was already observed. The
consumer owns cancellation and must not turn an interrupted stream into success.

AsyncThrowingStream iteration can end normally when its consumer task is cancelled.
The explicit cancellation checks above prevent that end from becoming either a
successful response or a misleading missing-terminal protocol error.

`ModelStreamError` carries structural categories and call IDs, without embedding
prompt text or raw arguments. Codable events can be used for fixtures; their
encoding is not a frozen journal or provider wire format.

## Provider Implementations

[ModelProvider](../../Sources/AgentModels/ModelProvider.swift) is Sendable
and exposes `stream(request:)` plus a descriptor. The descriptor's ID is an open
namespace matching `ModelID.provider`. Capabilities describe the adapter's current
configuration, not every model from that vendor. Adapters reject unsupported
requests explicitly rather than silently discarding tools or output constraints.

Adapters translate native failures into `ModelProviderError.Kind`. `retryAfter`
is a Duration hint, never permission to retry or replay a mutation. Retry and
fallback decisions belong to the agent loop's policy. Cancellation remains
`CancellationError`; adapters must not reclassify it as transport failure.

[ModelEventStream.make](../../Sources/AgentModels/ModelEventStream.swift)
provides a task-backed stream for one response:

```swift
func stream(request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
    ModelEventStream.make { emit in
        // Convert a single native response and emit normalized events here.
        // Throw classified errors; returning finishes the stream.
    }
}
```

The helper rejects an already-cancelled caller, cancels its producer Task when the
stream terminates, and checks cancellation before and after production and before
each emission. Each invocation owns its own Task. Producers must use cancellable
operations or check cancellation themselves; Swift cancellation cannot forcibly
stop uncooperative work. Callback-based transports must connect task cancellation
to their native request cancellation API.

Each stream has one consumer. Consume to EOF or cancel the consumer task; simply
breaking iteration while retaining the stream is not a cancellation API. The
helper buffers events without dropping them; the consumer must drain them, and
run deadlines and resource budgets belong to orchestration.
