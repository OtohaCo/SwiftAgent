# ADR 0011: Host-initiated tool invocation

Status: proposed (2026-10-01); first implementation on branch
`feat/host-initiated-tool-invocation` (2026-10-22), pending review and acceptance

The proposal below is unchanged. The decisions taken by the first implementation,
and what it does not cover, are under [Implementation](#implementation-2026-10-22).
It is not part of the immutable RC6.

## Context

Embedded MCP UI or native panels may request tools outside a model turn. As
[ADR 0006](0006-run-scoped-capability-binding.md) explains, a Host can directly
call its own trusted tool outside the SDK, but then the Host owns authorization,
resource restrictions and audit for **both read-only and mutation** calls.
Read-only does not imply permission-free. UI calls needing SwiftAgent's same
guarantees should use a future controlled entry point regardless of effect.

## Proposal and trust boundary

A future Session entry point would accept a Host-origin call without requiring
a model proposal. Host-origin identifies request source; it does not prove user
approval. Embedded UI/MCP UI is a requester, not a trusted permission issuer.
The Host must validate subject, tool, arguments, scope and approval basis. This
proposal does not put enterprise UI or an approval platform inside the SDK.

The caller must explicitly supply an immutable capability binding belonging to
that Session **instance**, not a mutable “current tool list”. Existing binding
code captures tools, policies, backend and resources for a Run. The future
entry point must verify version, scope generation and revocation before
execution. Waiting cannot silently switch to a new tool or broader permission.
It cannot invoke an unbound tool or revive an old scope/approval.

- Reuse ordinary tool authorization, requiredAudit enterprise authorization,
  Evidence where required, resource checks, durable mutation admission,
  Receipt validation, cancellation and the original absolute deadline.
- Coordinate same-Session calls with Run/queue admission and physical drain;
  retain actual owners/leases while work remains. Cross-Session operations
  continue using the existing shared resource scheduler/domain.
- Do not introduce a second lock system, executor or mutation ledger.
- Intent, Receipt, recovery and requiredAudit facts remain authoritative even
  if the Host elects not to show the result to the model. Model visibility is
  a request-view choice, not permission to omit execution facts.
- Formal history must represent Host origin honestly, never forge an assistant
  tool call as though the model proposed the action. Existing summary export
  must not be claimed to include identity/origin fields it does not export.

## Open questions

Whether this is a Run, how Host-origin formal history is represented, and how it
interacts with follow-up queues/replanning remain open. No new public API is
selected in this docs-only proposal. These are implementation decisions with
independent acceptance, not existing runtime guarantees.

## Until then

A UI mutation request can become input to the existing Agent path, where the
model may propose a subsequent action. That input is not already authorized;
normal Host authorization and all SDK gates still apply. Do not declare a
mutation read-only to bypass them. Hosts executing either effect outside that
path must explicitly accept their own authorization/resource/audit obligations.

## Implementation (2026-10-22)

`AgentSession.invokeHostTool(_:capabilities:operationID:budget:)` takes an
`AgentHostToolCall` (tool name, JSON arguments, optional Host note) and returns an
`AgentHostInvocation` handle (`wait`, `waitForDrain`, `cancel`), as `run` returns
an `AgentRun`. Admission failures throw from the call; execution failures from
`wait`. Decisions on the open questions:

- **It is a Run without a model.** Admission is a Run's: one owner per Session
  (an active Run, a starting Run or an active follow-up dispatcher refuses it with
  the existing errors), the previous Run's physical drain first, the Session
  identity and Journal lease, the history witness, pending-mutation recovery and a
  startup frame within the call's deadline. On Journals that keep Run records it
  has a Run admission record and a terminal like any Run; no Journal schema
  changes. A startup commit of unknown outcome keeps the owner through drain and
  never runs the call. The owner (lease, identity, binding Run, drain handle) is
  released only after the executor physically returned
  (`ToolScheduler.waitForRunToDrain`), even when the outcome came earlier by
  deadline, cancellation or revocation, and even if the Host released the Session.
  No model is asked.
- **Only the supplied binding.** The call is prepared on the binding's registry
  (any of its tools, deferred ones included; none outside it, including tools of
  the Agent the binding does not hold), registered with its scope (wrong Session
  instance, revoked or regenerated bindings are refused) and checked against its
  allowed resources. Revoking the binding cancels the call.
- **Same guarantees.** The prepared call runs through the shared scheduler with
  the tool's own authorization, Evidence, durable mutation intent, Receipt
  validation, confirmed-no-effect settlement and reconciliation marking; the same
  Session commit functions settle it, and tool errors are classified as a Run's.
  A mutation requires the Host's `operationID`; its idempotency key is
  `host:<operationID>/<tool>/<arguments>`, and Runs and queued inputs cannot name
  `host:` operations, so a retry replays a settled result or is refused until an
  unknown outcome is reconciled, and a model call never shares the key.
- **Formal history.** User-side messages beginning with
  `AgentHostToolCall.historyHeader`: the Host's request (the Run's formal input:
  tool, call identity, the Host's note, arguments as data), then its result as
  tool data, not instructions; a replay says the earlier result was replayed and
  the tool not run again; a failure says nothing was changed or that the outcome
  awaits reconciliation; `reconcileMutation` settles a Host call with a user-side
  Host notice. No assistant tool call is ever written for a Host call. The next
  Run's model sees all of it.
- **Host namespace.** Host call identities begin with
  `AgentHostToolCall.callIDPrefix`. A model proposal using that prefix ends its
  Run with `AgentHostInvocationError.reservedCallIdentity` before preparation, so
  a model never makes a call in the Host's name; Host origin is visible in the
  pending-mutation intent's call identity.

Not covered by this implementation:

- `requiredAudit` authorization is refused (`requiredAuditUnsupported`): its
  records start from a model proposal, and a Host-origin capture is not designed.
- No Journal event or audit/summary export field states Host origin. Origin is
  carried by the call identity namespace and the history wording only. The
  wording is not authenticated: other user-side text (a Run's input, steering or
  a queued input) could imitate it, and `note` must be written by the Host, never
  relayed from an embedded panel.
- Model visibility is not optional, and a large result is kept in history whole:
  the tool-result projection and excerpts do not apply to Host notices.
- Follow-up queues are not coordinated beyond refusing while a dispatcher owns
  the Session; no event stream is published for a Host call. `maxToolCalls` does
  not apply (one call).
