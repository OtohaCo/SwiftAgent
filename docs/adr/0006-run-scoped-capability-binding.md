# ADR 0006: Run-scoped capability binding and revocation

Status: accepted for RC4 implementation

## Decision and identities

An `AgentSession` issues a capability binding for its own process-local instance.
The immutable binding captures Host-approved capability/tool IDs and versions,
typed tool implementations and policies, backend instance/configuration labels,
an exact set of allowed `ToolResource` identities, and one scope instance with
an initial generation. Its read-only diagnostic view is not an execution
credential and cannot be decoded to regain permission. Session UUID, Session
instance, scope instance, capability version, Run UUID, resource identity, and
the Journal's operation domain remain distinct. A new binding can be selected
for a later Run; an already admitted or draining Run retains its original
registry, definitions, estimator inputs, backend references and scope handle.
Changing a Sendable tool's hidden mutable backend is a Host contract violation;
the SDK captures the tool value and checks the declared backend version but
cannot freeze an arbitrary service behind that value.

The Session's existing scheduler coordinates actual resource identities across
scopes. A scope allows only an explicit set of validated resource identities;
it never prefixes scheduler keys with scope or Session IDs. `global` is the
actual global resource identity, not a wildcard grant. Host tools must map
inputs to honest resource identities and use their bound backend/account; this
is not OS sandboxing. A Host can call a trusted tool directly outside the SDK,
so the guarantee applies to the Agent execution path.

## Admission and revoke linearization

The scope actor owns one live generation, a revoked flag, Run reservations and
final execution admissions. Starting a Run registers its cancellation owner
before the startup Journal commit. Preflight checks the binding against the
Session instance and the mutation-Journal prerequisite before accepting input.
The Run keeps the reservation until provider/tool/projection/estimation work
physically drains; logical completion alone does not release it. A failure
before startup publication unregisters the reservation. A commit whose result
is unknown still creates an owned failed Run under existing Session rules.

Typed preparation, resource acquisition, Evidence, Host authorization and
durable intent may suspend. They are not final execution admission. Directly
before `tool.execute`, the scope actor atomically checks its generation,
revocation, Run reservation and exact resource set, then records one final
admission. That actor transition is the linearization point against revoke.
If revoke wins, executor entry is forbidden. If admission wins, work is in
flight; revoke requests Run cancellation, but the owner retains its execution
and drain responsibility until it returns. Admission is distinct from executor
entry and from a real external effect. The actor holds no lock across Provider,
authorization, Journal I/O, executor or drain awaits. Repeat revoke is
idempotent. `revoke()` stops new admissions and requests cancellation;
`waitForDrain()` separately waits for all registered Runs to exit. Cancelling
one waiter does not cancel the owner or other waiters.

Mutation intent must be durably confirmed before final admission. A revoke
after intent and before executor entry leaves the intent for the existing
reconciliation path; cancellation is not trusted confirmation of no effect.
The existing receipt/output/conversation settlement and physical drain paths
remain authoritative. A settled replay does not enter the executor and does
not derive permission from its receipt. Scope/version/Run IDs never enter the
stable operation identity. Restart restores formal facts, not permissions:
Host approval creates a fresh scope instance, while old handles and generations
cannot be revived. The v1 Journal format and operation domain are unchanged.

## Boundaries

The first version revokes the whole scope and by default cancels dependent
Runs. It does not implement individual tool hot-swap, inherited permissions,
arbitrary code loading, an OS sandbox, remote executors, a second scheduler,
partial continuation, or automatic replay of uncertain operations. The Host
owns shared backend and Journal closure after every dependent Run drains.
Diagnostic status reports bounded counts and non-secret Host labels, never
credentials, full arguments, resource paths, prompts or executor outputs.
