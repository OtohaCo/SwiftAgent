# ADR 0011: Host-initiated tool invocation

Status: proposed (2026-10-01); deferred; not implemented

Document merge records a proposal only. No public entry point or RC6 capability
is delivered here; future implementation/acceptance requires a separate PR.

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
