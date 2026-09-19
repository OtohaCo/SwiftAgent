# SwiftAgent Security Model

last-verified: 2026-09-18

This document states what the SDK guarantees and what remains the host's job.
It is part of the 1.0 freeze.

## LLM output is untrusted

A model response is a proposal. Text, tool names, arguments, and structured
output are not authorization, not Evidence, and not a Receipt. The runtime
must not treat model content as proof that a resource exists, that a mutation
happened, or that the host should skip policy.

## A tool call is a proposal

Every complete tool call still passes:

1. Schema validation for input
2. Evidence requirements when the tool policy requires them
3. Authorization when the tool policy requires it
4. Resource identity for the scheduler
5. Receipt expectation for mutation and receipt-backed tools

Failing any step fails the call. Completeness on the wire only means the
transport finished the call payload.

## Model-visible tool failure is not a runtime failure

A read-only tool may opt into `ToolPolicy.RecoverableErrors.modelVisible` and
throw an explicit `RecoverableToolError`. Only that three-part combination is
converted into a structured model-facing tool result:

```json
{"code":"not_found","message":"No matching resource was found."}
```

The result has `isError == true`, uses the current tool call ID, enters the
canonical conversation, and consumes the normal tool-call and model-turn
budgets. The author controls every model-visible field; Core never stringifies
an arbitrary underlying error.

This channel is not available to mutation tools. It also does not catch input
or output schema errors, unknown tools, authorization, Evidence, receipts,
journal persistence, reconciliation, cancellation, deadlines, or ordinary
Swift errors. Those remain runtime failures. A recoverable error publishes no
Evidence and carries no Receipt, so text in its payload cannot establish a
trusted observation or claim a side effect.

## Mutation is not success until receipt

Executor return is not settlement. A mutation is successful only after
`ToolReceiptValidator` accepts a receipt that matches the durable operation
identity and targets, and the journal records settlement. Model text that
claims an effect does not create a receipt.

## Crash does not replay mutation

Restart recovery moves unsettled intents to `needsReconciliation`. The SDK
does not replay the host executor and does not infer success from the crash
tail. The host reconciles with a trusted receipt or aborts.

## Durable deduplication is journal-wide

Mutation deduplication is scoped to one shared durable `AgentJournal`, not to a
Session or Run. `operationID` names the logical operation and must stay stable
across retry attempts. For a non-nil `operationID`, the durable identity combines:

- The stable `operationID`
- The tool name
- The canonical semantic JSON arguments

Tool call ID, Session ID, and Run ID are excluded. Equivalent JSON object key
ordering, numeric spellings such as `1` and `1.0`, and equivalent JSON string
escapes therefore resolve to the same identity. Changing the tool or semantic
arguments creates a different identity and cannot reuse the prior settlement. A
nil or blank `operationID` falls back to a per-call identity and provides no
cross-run deduplication.

Admission fails closed according to the latest durable lifecycle:

- `intent` throws `AgentJournalError.mutationPending`; a second intent is not
  created and the executor does not run.
- `needsReconciliation` throws
  `AgentJournalError.mutationRequiresReconciliation`; the executor does not run.
- `settled` validates and reuses the original receipt without invoking the
  executor. Executor settlements durably preserve the canonical JSON tool
  output, so replay remains valid against the declared output schema.
  Transcript and run receipt records use the current tool call ID, not the
  original attempt's call ID.
- `aborted` permits a new lifecycle for the same logical identity. Abort means
  the trusted Host explicitly confirmed that the prior attempt produced no
  external side effect; cancellation or uncertainty alone is not an abort.

Authorization and Evidence checks currently run before durable replay admission,
so a settled receipt does not bypass current policy. Reconciliation should
provide the original canonical JSON output when later replay is required; a
legacy settlement without durable output fails closed with
`AgentJournalError.mutationReplayUnavailable`. Terminal identities are retained
indefinitely in the journal domain. The journal schema is version 3 and remains
backward-readable for version 1 and version 2 records.

## Provider fallback cannot replay an uncertain mutation

Once a mutation boundary is crossed, switching provider candidates for that
run is blocked. A later model must not retry an effect whose outcome is
unknown.

## Evidence does not equal authorization

Evidence is a trusted observation recorded by a tool or host. It answers
"this resource was seen in this session or run." Authorization is a separate
allow/deny decision. A valid Evidence record does not grant mutation rights.

## Receipt does not equal arbitrary host assertion

A receipt is bound to the admitted operation, idempotency key, and declared
targets. Hosts cannot mark an intent settled with unrelated JSON. Reconciliation
must satisfy the original expectation.

## Host executors remain the trust boundary

The SDK can:

- Refuse to open a mutation Session without durable journal storage
- Admit a mutation intent before the executor runs
- Validate receipts and refuse to settle on mismatch
- Keep scheduler isolation for shared resources
- Keep provider adapters from executing host tools

`.durable` on a journal is configured persistence mode. The SDK still has to
write the intent and can still fail that write. Hosts must handle persistence
errors.

The SDK cannot:

- Make an untrusted host executor honest
- Prove an external system changed without a receipt from that system
- Prevent a host from implementing `AgentTool.execute` incorrectly
- Replace operating-system sandboxing, secrets handling, or user consent

Product UI, platform services, file systems, and other host executors stay outside Core.
WorkspaceAgent is a Reference Host that demonstrates the contract; it is not a
security boundary for other apps.
