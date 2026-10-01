# ADR 0010: Confirmed no-effect mutation outcomes

Status: implemented on main by PR #62 (2026-10-01); unreleased

PR #59 recorded the revised proposal; PR #62 subsequently implemented this
contract on main. RC6 has not been released. The public API, explicit schema-6 (now schema 7 for proof v2)
format boundary, limits and integration are described in
[the guide](../guides/swift-agent-confirmed-no-effect.md). ADRs 0011/0012 remain
deferred and unimplemented.

## Context and pre-implementation behavior

The OtohaAI Host report (OAI-257) describes a need to return a conflict to the
model after a correctly classified mutation has definitively produced no
business effect. We have not independently inspected or reproduced that Host
integration. This report does not establish how other Hosts, MCP servers or CLI
wrappers behave.

Declaring a side-effecting tool `readOnly` to expose errors is a Host
classification bypass to correct, not a legitimate alternative: it loses the
SDK's mutation intent, Receipt validation and reconciliation guarantees.
Real side effects must remain mutations; conflict feedback is no justification
for lowering the effect classification.

At the fixed source baseline `74771806ea410f1648eba8d9b5d244f87b001815`:

- [ToolPolicy](../../Sources/AgentTools/ToolPolicy.swift) rejects mutation
  `recoverableErrors: .modelVisible`. [AnyAgentTool](../../Sources/AgentTools/AnyAgentTool.swift)
  exposes that error channel only for opted-in read-only executor failures.
- [ToolReceiptValidator](../../Sources/AgentTools/ToolReceipt.swift) validates
  success; a failed Receipt is not accepted as successful execution.
- [AgentJournal](../../Sources/AgentCore/AgentJournal.swift) restores formal
  history from a canonical checkpoint. An isolated `toolCompleted` event does
  not persist formal history. Successful mutation settlement includes output,
  Receipt and checkpoint and supports settled result replay.
- The reducer permits `intent` or `needsReconciliation` to become `aborted`;
  public `abortMutation` requires a quarantined `needsReconciliation` intent.
  An aborted operation identity permits new admission, not old-error replay.
- The current default audit reference for `mutationAborted` has kind
  `noEffectConfirmation`; it does not supply a structured executor proof or
  distinguish its origin. That is a foundation, not this feature's delivery.

## No-effect contract

A mutation may explicitly opt into the `confirmedNoEffect` policy and the
executor-context `ConfirmedNoEffectToolError` channel. Default
failure behavior is unchanged; ordinary `modelVisible` remains read-only only.
Unknown, partial or unconfirmed effects remain closed for reconciliation.

A `failed` Receipt with `failure: rejected` or `conflict` and
`confirmedTargets: []` is an allowed payload shape, **not proof of no effect**.
Trusted Host executor/adapter code must explicitly confirm all of the following:

- The whole business operation represented by this invocation produced no
  business effect, not merely that its final step failed.
- There is no partial effect and no queued, in-flight or background action
  that could still produce an effect later.
- The confirmation belongs to this exact invocation, logical operation
  identity, tool/backend, resource scope and frozen action conditions.

For example, step A writes a file and step B encounters a conflict. A final
failed Receipt with empty targets cannot certify the whole operation as having
no effect: A already changed state.

Do not infer confirmation from HTTP 409/422, MCP `isError`, CLI nonzero exit,
empty targets, absence of a successful Receipt, timeout/cancellation, ordinary
error text or model output. A missing, mismatched, stale or insufficient proof
keeps the ordinary closed failure path. Success Receipt validation stays intact.

The dedicated proof can acquire executor origin only at the actual trusted
executor return boundary. Preparation, enterprise authorizer, tool authorize,
other callbacks and model text cannot acquire that origin by returning or
throwing a same-named public type. Follow the actual-stage classification in
[ADR 0008](0008-bounded-pre-admission-replanning.md) and
[AgentAuditRuntime](../../Sources/AgentCore/AgentAuditRuntime.swift), not Error
names. The Host owns backend truth; the SDK binds and validates the declared
facts and execution boundaries. This proposes neither a signature platform nor
an ability to detect a malicious Host executor.

## One reliable publication boundary

Extend the existing [batch-progress](../../Sources/AgentCore/AgentToolBatchProgress.swift)
and settlement chain. When a valid executor confirmation is accepted, the
following must become committed facts in **one authoritative Journal root /
transaction publication**:

1. Typed no-effect confirmation and recoverable proof or immutable proof link,
   with current invocation/backend/resource/action associations.
2. `mutationAborted` for that intent.
3. Correctly paired assistant tool call and `isError` tool result.
4. Canonical checkpoint containing those formal messages.
5. Under `requiredAudit`, result association, executor provenance and necessary
   structured proof information.

Do not abort first and later commit history/audit. An enum case, `recordCount`,
in-memory observation or isolated `toolCompleted` is not disk persistence; an
unstructured `basis` alone is not the proof model. After reliable publication,
the Session adopts committed state and only then may request the next model
turn. On definite commit failure or `commitUnknown`, continuation stops and
existing recovery/drain ownership remains; do not clear intent because error
feedback was constructed or observed elsewhere.

There is one execution ledger, no second success state machine. Audit must
distinguish executor-confirmed no effect from Host reconciliation-confirmed no
effect, with one accurate result association rather than an ambiguous default
plus duplicate or contradictory records. No successful Receipt event, success
Evidence or read-only provenance is created. A no-effect mutation is still a
mutation and cannot become eligible for read-only history projection.

## Recovery, replay and a new attempt

Restoring formal history or querying an existing invocation does not execute
anything. A new attempt is a new runtime call instance, with a new invocation
identity. A model call ID is an untrusted correlation label, not permission or
a globally unique attempt identity; Run ID locates its owning budget/lifecycle.
The stable operation identity keeps the existing semantic idempotency rules,
independent of a new approval or invocation. Do not overwrite the previous
aborted invocation's history or audit associations.

Every new attempt rechecks authorization (enterprise and tool where required),
Evidence, scope, resource/action conditions and durable admission. Old-call
redelivery must not be mistaken for a new attempt, and unknown results cannot
be bypassed by changing call ID or operation ID. An aborted identity's ability
to admit a new call does not establish an error replay contract. Any additional
per-invocation error replay API needs a separately defined and verified contract;
this first version does not promise automatic Run replay.

Continue under the original absolute deadline, model-turn and tool-attempt
budgets. Failed attempts count; no budget reset or automatic unbounded retry.
Host deny, scope revoke and cancellation remain execution stops, irrespective
of whether a conflict could otherwise be corrected.

## Failure and batch constraints

| Boundary | Required behavior / regression |
| --- | --- |
| Timeout, cancellation, revoke or expired budget | Not no-effect proof; no next model request after stop, including a late result |
| Noncooperative or late executor | Original owner retains executor, Session and Journal lease until physical drain; recording/cleanup cannot release working resources early |
| Definite publication failure / commitUnknown | Stop; reopen the real root as required; never partially expose abort/error/audit or automatically retry effects |
| Audit persistence failure | Preserve execution, audit and persistence errors; do not short-circuit quarantine/recovery responsibility or claim a failed quarantine succeeded |
| Mixed batch | Preserve completed siblings' Receipt and paired history; distinguish unstarted, in-flight and unknown calls, never relabel all as no effect |
| Model feedback privacy | Bound and redact error content; raw proof material is not automatically model-visible |
| Effect qualification | No successful Evidence/Receipt or read-only projection proof from an aborted mutation |

Implementation acceptance must include valid rejected/conflict confirmations;
all insufficient forms including partial effects and still-running background
work; stale/wrong binding and error-origin impersonation; legitimate new attempts
versus duplicate old calls; exhausted budgets and repeated conflicts; failures
before and after publication and `commitUnknown`; SIGKILL/reopen (not power-loss
validation); cancellation/return races; mixed batches; audit failure; and
maintenance/GC/index integrity followed by recovery. Use barriers and controlled
fault injection rather than timing-dependent sleeps.

## Disk and source compatibility

Existing schema 3–5 `intent → aborted` support proves a state-transition basis
only. It does not establish compatibility for new proof payloads, error replay,
executor audit provenance or old readers. Before implementation claims
compatibility, verify actual disk representation, atomic associations,
maintenance/GC, reopen and old-reader behavior.

If new persisted fields or semantics cannot be safely understood by an older
reader, use a format boundary that the old binary actually checks, as in
[ADR 0008](0008-bounded-pre-admission-replanning.md) and
[ADR 0009](0009-audited-authorization.md). Do not mechanically upgrade schemas,
ignore new fields to claim compatibility, automatically migrate existing stores
or resume an old operation on a new empty ledger. Record public enum/API/Codable
changes and preserve an opt-out/default legacy comparison.

## Implementation decisions and responsibility

PR #62 implements `ToolContext.confirmNoEffect`, bounded `ToolNoEffectProof`,
read-only per-call queries, live executor nonce/invocation binding, existing
batch-progress atomic publication and explicit schema 6. Its
[per-head acceptance record](https://github.com/OtohaCo/SwiftAgent/pull/62#issuecomment-5924397610)
records actual reader, recovery, fault and physical-drain validation. No
per-invocation error replay or automatic Run replay API was added. These choices
preserve success validation, authorization, recovery and physical drain.

Host code remains responsible for the truth of whole-operation no effect and
absence of outstanding actions. Storage capability does not enable
`requiredAudit`; the Host must configure that mode explicitly. This implementation
is available on main but is not an RC6 release.

Issue #65 adds bounded proof v2 with versioned argument/key bindings and schema 7
for new no-effect stores. Valid schema-6/v1 data remains readable and is not
migrated. See the [current format and pending recovery contract](../guides/swift-agent-confirmed-no-effect.md#format-and-limits).
