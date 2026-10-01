# ADR 0011: Host-initiated tool invocation

Status: proposed (draft, 2026-10-01); deferred until a Host lets embedded UI or
a user invoke mutation tools outside a model turn

## Context

Hosts show tool-specific UI next to the conversation: embedded views served by
an MCP server, or native panels. A user action in that UI may call a tool
directly, for example moving a clip, saving settings or starting an export.

ADR 0006 states that a Host can call a trusted tool directly outside the SDK and
that the guarantees apply to the Agent execution path. For read-only calls this
is enough. For mutations the Host would have to build its own durable intent,
receipt validation and reconciliation, a second ledger beside the journal, and
the model would not learn that the effect happened.

## Proposal

`AgentSession` gains an entry point that executes one call of a tool from the
Session's current capability binding without a model turn.

- The call goes through the same checks as a model call: tool authorization,
  `AgentAuthorizer` under `requiredAudit`, resource and mutation admission,
  receipt validation, Evidence, cancellation and deadlines.
- It is journaled with a Host-origin marker, so recovery reconciles it like any
  mutation and audit export shows who initiated it.
- Its canonical result can be appended to history as a Host-originated record so
  the next model turn sees the effect, or kept out of history when the Host
  chooses.
- It serializes with Runs through the existing Session admission; it never runs
  concurrently with a Run's exclusive tools.
- It cannot add tools. Only tools in the binding are invocable, so UI cannot
  reach anything the Host did not bind.

## Open questions

- Whether a Host-initiated invocation is a Run (simplest reuse of journal and
  audit) or a new journal unit.
- How history represents the result without impersonating the user or the
  assistant.
- Interaction with the follow-up queue and pre-admission replanning.

## Until then

Hosts let embedded UI call read-only tools only. A mutation requested from UI
becomes a message to the model, which goes through the normal Agent path.
