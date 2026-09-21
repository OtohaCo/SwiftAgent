# ADR 0003: Execution reporting and Host integration

Status: Accepted for post-RC3 development
Date: 2026-09-21
Scope: `Examples/ExecutionReportingSupport`, `Examples/AppleChatApp`, and the
headless Host example

## Context

The Core already exposes the public facts needed by a Host, but they arrive at
different lifecycle boundaries:

- `AgentRun.events` carries one bound stream with `runStarted`, model events,
  tool admission, tool results, validated receipts, and one `runFinished`.
- `AgentRun.wait()` reports the logical result or throws; it does not mean the
  event consumer has processed the stream or that physical work has drained.
- `AgentRun.waitForDrain()` is the physical cleanup boundary.
- `AgentLoopResult.receipts` and the receipt event can describe the same
  accepted execution fact and must be merged idempotently.
- `AgentJournal` exposes durable lifecycle and pending-mutation recovery, but
  a report must not write the journal, reconcile mutations, or authorize tools.

`AgentEvent` does not repeat session/run identity on every case. The consumer
therefore has to bind one reducer to one `AgentRun` stream and reject a
mismatched lifecycle identity. A missing event, receipt, or terminal is an
observation gap, not proof that no executor or mutation occurred.

## Decision

1. Put a small portable `ExecutionReportingSupport` package under `Examples/`.
   It depends on the published Core/Models/Tools interfaces and is used by
   both `AppleChatApp` and the independent headless Host example. It is not a
   new top-level SDK product and it has no executor, journal, scheduler, or
   authorization authority.
2. Expose a synchronous `ExecutionReportReducer` owned by the existing Host
   actor/controller. It accepts the bound stream's events, the observed
   `wait()` result, presentation diagnostics, stream completion, and drain
   completion. It keeps bounded model text and tool previews, retains accepted
   receipts monotonically, and records conflicts rather than overwriting them.
3. Keep four results separate: runtime termination, execution facts, Host
   domain fulfillment, and presentation. Model text, structured JSON, or a
   decoded report can never create execution facts.
4. Make the report final only after the observer has processed the terminal,
   the logical wait observation is recorded, the stream has ended, and physical
   drain has completed. Early observer cancellation is explicitly partial.
5. Keep authorization and domain settlement in each Host. The read-only
   example rejects a mutation before executor entry; the file example checks
   the actual file and journal receipt independently of the model's final
   wording.

## Consequences

- Hosts can render “the write committed, but the final reply failed” without
  replaying a tool or trusting malformed model text.
- A tool result with `isError == true`, a failed tool, or a missing receipt is
  never upgraded to a successful effect. A failed tool also does not erase an
  earlier committed tool.
- Duplicate receipt observations are counted once. Conflicting observations
  remain visible as diagnostics.
- Usage remains with `AgentUsage`; the report only carries identity and
  coverage diagnostics. Transport attempts and live-provider qualification
  remain outside this change.
- The package is example/support code. A future extraction into the SDK needs
  separate evidence that multiple non-example Hosts require the same public
  interface.
