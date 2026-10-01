# ADR 0010: Confirmed no-effect mutation outcomes

Status: proposed (draft, 2026-10-01); not implemented

## Context

A mutation tool often learns that its request was refused before anything
changed: an optimistic-concurrency check found a newer revision, the target
already exists, or the external system validated and rejected the input. The
model can usually recover by reading again and issuing a corrected call.

SwiftAgent currently gives such a tool two choices. It can declare
`effect: .mutation`; then `ToolPolicy` refuses `recoverableErrors:
.modelVisible` (`mutationCannotExposeRecoverableErrors`), and any receipt other
than `succeeded` throws `ToolReceiptError.unsuccessful`, which fails the Run.
Or it can declare `effect: .readOnly` to keep the model loop going, and lose the
durable intent, receipt validation and crash reconciliation that make mutations
safe.

Hosts take the second option in practice. A Host that wraps third-party apps
declares their actions read-only so that a conflict can reach the model; a
timed-out action then reaches the model as "may still finish; check before
trying again", which leaves the decision not to repeat an external side effect
to the model. MCP servers and CLI wrappers make this the common case.

The journal already models the outcome the tool needs.
`AgentNoEffectConfirmation` is a trusted Host decision that an operation did not
take effect; `mutationAborted` moves a record to `aborted`; the reducer accepts
that event from `intent` as well as `needsReconciliation`; and an aborted
idempotency identity may be admitted again. Only the executor path cannot reach
it: `abortMutation` is a reconciliation API that requires `needsReconciliation`.

## Decision

A mutation tool may opt in to report a confirmed no-effect outcome to the model.
Every other failure keeps failing closed.

1. **Opt-in.** `ToolPolicy.RecoverableErrors` gains a mutation-only case,
   tentatively `confirmedNoEffect`. `modelVisible` stays read-only only, and the
   regression that forbids it on mutations stays.
2. **Proof.** The executor ends the call by throwing a no-effect error that
   carries a `RecoverableToolError` (code, message, optional details) and a
   `ToolReceipt` with the call's operation ID, `status: .failed`,
   `failure: .rejected` or `.conflict`, and no confirmed targets. A revision,
   when present, is the revision the executor observed.
3. **Validation.** Core checks the proof against the call's operation ID with a
   dedicated no-effect check. `ToolReceiptValidator.validate` keeps its success
   semantics. These stay unchanged and quarantine the intent for reconciliation
   as today: `indeterminate`, `unavailable` or `unknown`; a missing or
   mismatched receipt; any confirmed target; a thrown error without the proof;
   timeout; cancellation.
4. **Settlement.** On a valid proof Core appends, in one durable batch as
   reconciliation settlement already does, `mutationAborted` for the pending
   intent (basis naming the executor receipt and failure) and a canonical error
   `toolCompleted` (`isError: true`) with the `RecoverableToolError` payload,
   then continues the model loop. It publishes no Evidence and no success
   receipt event.
5. **Retry.** Because the identity is aborted, the model may issue the same call
   again; a changed call gets a new identity as usual. Replaying the Run returns
   the recorded error and never re-executes.
6. **Audit.** Under `requiredAudit`, the abort is recorded with the existing
   no-effect confirmation result kind and an executor source, so audit export
   distinguishes executor proofs from Host reconciliation.

## Alternatives rejected

- **Allow `modelVisible` on mutations.** A thrown error does not prove the
  absence of an effect; timeouts and transport failures would become
  model-visible text.
- **Settle a failed receipt with `mutationSettled`.** Settled identities replay
  their stored output, so a corrected retry with the same arguments would never
  execute.
- **Leave it to Hosts.** They already route around the rule by declaring
  mutations read-only, which is strictly worse.

## Consequences

- Hosts can classify external actions honestly and keep intent, receipts and
  reconciliation for them.
- The proof is as trustworthy as the executor, the same rule as receipts: it is
  supplied by trusted Host code, never decoded from model output or external
  text.
- Journal schemas 3 to 5 already accept `intent → aborted`. The implementation
  must confirm that reducer, recovery and audit closure accept the error
  `toolCompleted` after an executor abort, and gate any new persisted field
  behind schema negotiation as ADRs 0008 and 0009 do.
- Tests keep `mutationCannotOptIntoModelVisibleErrors` and add regressions for
  conflict and rejection proofs, each refused proof shape, retry after abort,
  a crash before and after the batch, and the audit facts.
