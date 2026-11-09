# ADR 0016: Pre-admission tool outcomes reach the model

Status: implemented on branch `otoha/review-1110-core` (2026-11-10); unreleased

## Context

Before this change a tool call ended the whole Run when:

- the model named a tool the Run does not offer (`ToolRegistryError.unknownTool`);
- the tool's own `authorize` returned `.denied` (`ToolInvocationError.authorizationDenied`);
- the tool's own `authorize` threw.

Only opted-in read-only executor failures (`recoverableErrors: .modelVisible`) and
arguments that do not fit the input schema went back to the model. `ToolPolicy`
forbids `.modelVisible` for mutations, because an executor failure after the
mutation intent is written may have changed something.

None of the three cases above can have an effect: the executor never ran and, for a
mutation, no intent was written. Ending the Run lost the turn and pushed hosts into
workarounds: declaring a command tool read-only to report a refusal, wrapping every
tool so a denial becomes an executor error, or returning a success receipt for a
command that never ran (which also writes an intent for nothing).

## Decision

These outcomes become ordinary error tool results (`isError: true`) committed to
history like any other result, and the Run continues with the next model request:

| Case | `code` | Text |
|---|---|---|
| Unknown or undeclared tool name | `unknown_tool` | fixed |
| `authorize` returned `.denied` | `not_allowed` | fixed |
| `authorize` threw `RecoverableToolError` | the error's `code` | the error's `message` and `details` |
| `authorize` threw any other error | `authorization_failed` | fixed |
| Authorization outlived `ToolScheduler.authorizationWaitLimit` (OAI-1519) | `not_answered` | fixed |
| The lease wait outlived `ToolScheduler.leaseWaitLimit` (OAI-1519) | `busy` | fixed |

Rules:

- Fixed texts never contain the model-supplied tool name, arguments or the thrown
  error's description. A `RecoverableToolError` is written by the host's own tool
  code and is shown as written, as it already is for read-only executors.
- The rule holds for read-only tools and mutations alike, because it applies only
  before admission: no executor entry and no mutation intent. A failure after the
  intent is written (executor error, timeout, invalid receipt or output) still marks
  the mutation as needing reconciliation and ends the Run, unchanged.
- Cancellation, the Run deadline, the tool timeout, revoked capability scope,
  Evidence (ADR 0008 keeps its bounded replanning) and integrity failures
  (missing idempotency key, missing mutation admission) still end the Run.
- Under audited authorization (ADR 0009) the audit's own decision and a tool
  `authorize` called inside the audited step keep their current behaviour; the
  audit record needs a terminal disposition that this ADR does not define.
- Unknown tool names under audit are recorded as the rejection reason
  `unknown_tool`, like `invalid_arguments`.
- Host-initiated calls (ADR 0011) get the same result returned to the host, so a
  denied host call is an error result, not a thrown error. Calling a tool name that
  is not bound still throws to the host: that is a host programming error.

### Default, not opt-in

A denial is model-visible by default with no switch. A denied call changed nothing,
so telling the model is never less safe than ending the Run; it only changes what
happens next. A host that wants a denial to stop the task (a "stop" button next to
"deny") cancels the Run, which still ends it. Repeated denied calls are bounded by
`maxToolCalls` and `maxModelTurns`. No host need was found for ending the Run on a
plain denial, so no compatibility setting is added.

## Consequences

- Tests and hosts that expected `authorizationDenied` or `unknownTool` to end a Run
  now see a completed Run with an error tool result.
- A mutation tool can refuse with a precise, host-written explanation by throwing
  `RecoverableToolError` from `authorize`, without writing an intent or inventing a
  receipt.
- The replayed assistant message keeps the model's own call, including an unknown
  name; a provider that rejects replaying a call to an undeclared tool would fail
  the next request, which is no worse than ending the Run here.
