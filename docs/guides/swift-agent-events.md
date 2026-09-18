# SwiftAgent Agent Events

last-verified: 2026-09-18

`AgentRun.events` is a single-consumer `AsyncStream<AgentEvent>`. Events are
Sendable and contain enough information to render progress and the final outcome
without reading mutable engine state.

```swift
import AgentCore
import AgentModels

func observe(_ run: AgentRun, render: @Sendable (AgentEvent) async -> Void) async {
    for await event in run.events {
        await render(event)
    }
}
```

## Ordering

| Event | Meaning |
| --- | --- |
| `runStarted` | Session ID, run ID and configured model for this stream |
| `turnStarted` | One-based model-turn number |
| `model` | A validated prefix of the normalized ModelEvent stream |
| `toolStarted` | Runtime admission, including authorization. Not proof that a host executor started or acquired a lease |
| `toolReceiptValidated` | Executor confirmation passed result checks; includes call ID and tool effect |
| `toolCompleted` | Typed output passed validation; includes its call ID |
| `toolFailed` | The active attempt ended without a valid result |
| `steeringApplied` | An accepted correction was committed to run context; includes its ID |
| `runFinished` | The single terminal result, failure or cancellation |

`runStarted` fires exactly once. Exactly one `runFinished` closes the stream.
For each turn, model events precede tool attempts. Starts use proposal order;
parallel completions can arrive in another order. Each started attempt has one completed or failed event before run
termination while the consumer remains connected. A proposal that fails batch
preparation has no toolStarted; the run fails before dispatch. Model tool-call
events describe proposals, not evidence that a host operation executed.

SAI-030 may later publish admission-versus-executor telemetry on a diagnostic
channel. It must not redefine `toolStarted`.

An accepted [receipt](swift-agent-receipts.md) event precedes its toolCompleted.
Read-only confirmations are distinguished by effect; neither run completion nor
model claims create mutation success. The terminal result retains accepted receipts
from this run only.

Text, reasoning and usage events arrive incrementally after prefix validation.
They remain provisional. Model responseCompleted is withheld until clean EOF and
model identity validation. Extra frames, transport errors or missing terminal
frames cannot publish a valid model completion. A completed model response still
does not mean the whole run has finished.

The terminal `result` carries AgentLoopResult; inspect its outcome for completed,
refused or incomplete. Typed AgentFailure distinguishes loop, session, provider,
model protocol, registry, invocation, evidence, receipt, resource, scheduler and
journal failures. Unknown host errors become unclassified without copying their
arbitrary descriptions into events. Combined mutation settlement/quarantine
failures are `AgentFailure.mutationPersistence`. Context policy failures are
`AgentFailure.context`. `wait()` throws the original error. `wait()` is the
logical terminal; `waitForDrain()` is the physical provider/tool release.

## Cancellation and Lifetime

Deadline and failure close all active attempts before runFinished. An accepted
history checkpoint commits its receipt/completion together before termination;
cancellation cannot relabel that committed result as a tool failure. The event outlet
settles once and refuses later events, including output from operations that ignore
cancellation. A toolFailed event reports the runtime outcome, not proof that an
external effect was undone. See the [Loop Contract](swift-agent-loop.md) for deadline
and execution-integrity semantics.

Model/tool cancellation is observable as runFinished(cancelled) when the consumer
stays connected. Cancelling the `AgentRun.events` observer disconnects that
stream and does not cancel the Run. A disconnected consumer is not guaranteed a
terminal tail. Call `run.cancel()` to reach active provider, authorization and
tool work. Each Run has independent state and an independent event outlet.

Consume the stream to completion or cancel the consuming task. Breaking iteration
while retaining the stream is not a cancellation API. Events are buffered without
dropping lifecycle data; consumers must drain them. The stream is not a persistent
journal, replay subscription or telemetry sink, and payloads may contain user data.
Only persist them under an explicit host policy.

For an owned [AgentRun](swift-agent-sessions.md), cancelling its events observer
only disconnects observation. Use `run.cancel()` to stop execution; `run.wait()`
remains available independently.
