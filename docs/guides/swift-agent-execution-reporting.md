# Execution reporting and Host integration

last-verified: 2026-09-21

This guide describes the Host-side pattern for presenting what a Run actually
observed. It does not change `AgentRun.wait()`, terminal events, mutation
settlement, Journal recovery, or authorization. The reference implementation
is the reusable support package in
[`Examples/ExecutionReportingSupport`](../../Examples/ExecutionReportingSupport).
The runnable headless Host is in
[`Examples/HeadlessExecutionHost`](../../Examples/HeadlessExecutionHost).

## Keep four results separate

An integration should retain four independently computed layers:

1. **Runtime termination**: the SDK Run completed, was refused, became
   incomplete, failed, or was cancelled.
2. **Execution facts**: tool proposals, admission, tool results, validated
   Receipts, and unknown or conflicting observations. A Host may add a
   separately instrumented executor-entry observation; the public
   `toolCompleted` event does not prove that entry and can also describe a
   settled replay.
3. **Domain fulfillment**: whether the Host's already accepted goal is now
   satisfied. This requires Host-owned target and permission state, execution
   facts, and any required current resource state.
4. **Presentation**: model text, structured display data, parsing failures, and
   local fallback text.

The model's final text is presentation. It cannot create a Receipt, authorize a
tool, prove that a mutation occurred, or erase an observed mutation. A Receipt
is historical execution evidence; it does not by itself prove that an external
resource still has the same current state.

## One event consumer, then drain

`AgentRun.events` is a single-consumer stream. The controller that owns the Run
should feed the same event into its existing UI/Usage projection and into one
`ExecutionReportReducer`. Do not start a second event loop just for reporting.
The reducer is synchronous and value-based; the existing actor or controller
provides serialization.

The report is not final until the observer has processed the stream, the Host
has recorded the logical `wait()` result, and `waitForDrain()` has completed:

```swift
var reducer = ExecutionReportReducer(sessionID: run.sessionID, runID: run.id)

let observer = Task {
    for await event in run.events {
        reducer.consume(event)
        // Update the Host projection and Usage accumulator here as well.
    }
    reducer.markStreamEnded()
    return reducer
}

let waitResult: Result<AgentLoopResult, AgentFailure>
do {
    waitResult = .success(try await run.wait())
} catch {
    waitResult = .failure(ExecutionReportReducer.classify(error))
}

reducer = await observer.value
reducer.recordWait(waitResult)
try await run.waitForDrain()
reducer.markDrainCompleted()

let report = reducer.report
```

The exact controller may store the reducer across actor turns, but the order is
the same. `wait()` can finish before the event consumer has processed the last
event. Stream end is not physical drain. Cancelling a UI observer is not the
same operation as cancelling the Run.

## Fail closed and preserve facts

The reducer keeps prior observations when later work fails, is cancelled, or
produces malformed presentation data. For example, “the note was written, but
the final reply was unavailable” is a valid result: the report contains the
committed Receipt, the Runtime termination is failed, and presentation is
malformed.

The following cases remain distinct:

| Situation | Host result |
| --- | --- |
| Tool completed and final text is malformed | Keep the tool fact; show a local unavailable-reply message. |
| Structured text says search-only after a committed write | Keep the write and report a presentation/fact conflict. |
| Text says “saved” with no tool evidence | Do not show execution success. |
| Mutation committed, then Provider failed | Keep the Receipt and failed Runtime termination; do not replay the tool. |
| User cancelled after a committed mutation | Keep the historical fact; do not claim rollback. |
| Read-only Host receives a mutation proposal | Reject before executor entry; executor count must remain zero. |
| Receipt is missing after a tool attempt | Keep the operation unknown; missing evidence does not prove no side effect. |

Host authorization is evaluated before executor entry from an accepted,
revision-bound target and permission policy. A model confidence value or a
presentation field is not authorization. Domain fulfillment is also Host-owned;
the generic runtime does not decide whether a note, queue, playback request, or
other business goal is complete.

## Identity, overlap, and limits

Bind every reducer to `sessionID` and `runID`. Use `callID` and the operation
identity carried by the Receipt when joining tool observations. Late or
mismatched events are diagnosed and cannot overwrite a newer conversation.

The same Receipt may appear in a validated event and in the final logical
result. Identical overlap is counted once. A conflicting Receipt is retained as
the first observation and produces a diagnostic. Repeated text deltas are
appended; deduplication by whole event would lose valid repeated text.

Text and tool previews are bounded. Truncation is diagnosed. The default report
does not log API keys, complete request bodies, opaque continuation state,
private file content, internal endpoints, or absolute paths. The Codable
`ExecutionReportSnapshot` is display data only. Restoring it cannot authorize a
tool, create Evidence, issue a Receipt, or mutate a Journal.

## Runnable examples

Both examples use deterministic fixtures and make zero model-generation
requests:

```sh
swift test --package-path Examples/ExecutionReportingSupport \
  --disable-sandbox --no-parallel
swift test --package-path Examples/HeadlessExecutionHost \
  --disable-sandbox --no-parallel
swift run --package-path Examples/HeadlessExecutionHost \
  HeadlessExecutionHostCLI failure-after-write
swift run --package-path Examples/HeadlessExecutionHost \
  HeadlessExecutionHostCLI read-only-rejects-write
```

`failure-after-write` writes a real file through the registered mutation tool,
then ends the fixture Provider with an invalid final response. The report keeps
the committed Receipt, and a replay with the same operation identity does not
write the file again through the existing Journal path. The read-only scenario
rejects the same proposal before executor entry and produces no file or Receipt.

`Examples/AppleChatApp` uses the same reducer from its existing single event
consumer. Its projection keeps the report after terminal cleanup so the UI can
distinguish a completed tool with an unavailable reply, a failed/cancelled Run
with earlier actions, and an uncertain tool result. The UI is a presentation
surface, not the permission boundary.

## Acceptance record

The repository script writes a bounded machine-readable artifact to
`.build/execution-reporting-acceptance.json` (or the path in
`SWIFT_AGENT_ACCEPTANCE_OUTPUT`):

```sh
bash Scripts/ci-execution-reporting.sh
```

Each case records the source commit and tree, workspace-dirty state, platform,
toolchain, mode, exit code, result, duration, and known model request count.
`skip` or `blocked` must not be rewritten as `pass`; fixture acceptance is not
live Provider qualification. The script is included by the formal macOS and
Linux CI scripts. Linux evidence must still come from a real Linux Swift 6.4
runner; running `ci-linux.sh` on macOS is not Linux evidence.
