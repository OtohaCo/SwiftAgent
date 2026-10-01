# Confirmed no-effect mutation outcomes

Implementation candidate; requires its independent feature PR to merge before
main provides this capability. ADR 0010 was merged as a proposed design, not a
feature release. ADRs 0011/0012 remain deferred.

## Host contract and opt-in

Default mutation failures remain closed. `modelVisible` is still read-only
only. A Host explicitly selects `.confirmedNoEffect` on a mutation and creates
a store with `supportsConfirmedNoEffect: true`. This fails before provider
contact/candidate input publication on memory or schema 3/4/5 stores.

The trusted executor must establish that the **entire** business operation had
no effect, including no partial effect and no queued/in-flight/background action
that may later take effect. Step A having succeeded followed by step B conflict
is not no effect. HTTP 409/422, failed Receipt with empty targets, MCP `isError`,
CLI exit, timeout/cancellation, error text and model output are insufficient.
No signature platform or ability to detect a malicious Host is claimed.

The executor-only context factory binds an archival proof to an SDK-generated
invocation ID, Session/Run/model correlation, stable operation identity, frozen
tool definition/implementation/backend/account generations, semantic arguments,
resource/material revisions and optional capability scope instance. Live nonce
binding is not archived permission. Same named errors from preparation, enterprise
or tool authorization cannot enter this channel. Decoded proof is query data;
there is no public archived-proof-to-error or permit constructor.

```swift
// AgentTool policy; ordinary mutation behavior remains the default.
let policy = try ToolPolicy.mutation(
    evidence: .none, recoverableErrors: .confirmedNoEffect)

// Host chooses a NEW directory; no migration or fresh-ledger workaround.
let journal = try AgentIncrementalJournal.create(
    at: hostChosenDirectory, operationDomain: "shared-business-domain",
    supportsConfirmedNoEffect: true)

// In execute ONLY, after a trusted conditional/version check has refused the
// whole operation and the executor has established that no work remains:
throw try context.confirmNoEffect(
    receipt: ToolReceipt(operationID: context.idempotencyKey!, status: .failed,
                         confirmedTargets: [], failure: .conflict),
    error: RecoverableToolError(code: "revision_conflict",
                               message: "Read the current revision before trying again."),
    wholeOperationHadNoEffect: true, noOutstandingEffects: true,
    basis: "conditional operation refused before any business effect")
```

Declare non-secret backend/account generation and implementation version through
`authorizationBinding(for:)`; the executor must itself use immutable inputs or
conditional writes. A digest/declaration does not freeze arbitrary Host code.
The compiling [public fixture](../../Examples/ExternalClient/Sources/ConfirmedNoEffectFixture)
contains the full AgentTool/provider/authorizer/Session integration.
Existing authorization, Evidence, resources, scope and final admission remain;
`requiredAudit` still requires the enterprise authorizer and identity context.

## Persistence, queries and lifecycle

The existing batch-progress and Journal checkpoint commit publish typed proof
within the mutation DTO, `mutationAborted`, paired assistant/error messages,
canonical checkpoint and requiredAudit executor/result association in one root.
No success Receipt/event, success Evidence or read-only provenance is produced.
The next model request follows that reliable commit and Session adoption.

```swift
let old = try await journal.mutationStatus(
    sessionID: sessionID, runID: runID, callID: ToolCallID(rawValue: "A"))
let proof = try await journal.executorNoEffectConfirmation(
    sessionID: sessionID, runID: runID, callID: ToolCallID(rawValue: "A"))
let history = try await session.conversationSnapshot()
let audit = try await journal.auditRecords(matching: .init(runID: runID))
```

These are trusted Host management reads; Host access control/tenant isolation is
required. Executor confirmation has `executorProof`; reconciliation confirmation
has basis and no executor proof. `abortMutation` rejects decoded executor proof;
the Host must make a fresh reconciliation confirmation through its existing API. Audit result references distinguish
`settlementSource: executor` from `reconciliation`; older nil-source records do
not retrospectively acquire proven executor provenance. Standard audit export
remains a summary, with no raw proof/arguments or extra-field ACK claim.

Formal restoration/query never execute. A new call instance rechecks all gates
under original absolute deadline and call/turn budgets. Failed attempts count.
Stable operation identity follows existing semantic rules; old invocation
redelivery is rejected rather than silently treated as new. Pending/unknown
cannot be bypassed by changing IDs. No automatic Run/error replay is added.
Successful settled operations still return original Receipt/output without a
new business execution, subject to current access checks.

Cancellation, revocation and timeout are stops, not no-effect proof. Late
returns cannot start another model turn. The original owner retains executor,
Session/scope and Journal lease through physical drain. Definite publication
failure or commitUnknown closes continuation; reopen the actual root. Audit
failure cannot skip quarantine; combined persistence errors remain observable.
Mixed batches retain successful siblings' Receipt/history and keep unstarted,
in-flight and unknown calls distinct.

## Format and limits

Ordinary creation remains schema 3, rejection-capable schema 4 and audit-capable
schema 5. Explicit no-effect creation selects schema 6 (including schema 4/5
facilities). Schema 6 adds a typed executor proof to the mutation payload and
witnessed per-call indexes. Missing proof indexes/witnesses throw; they are not
empty confirmation results. Existing mutation/call indexes retain proofs and
associations through bounded maintenance/GC. No automatic forgetting, migration,
new operation domain or duplicate executor/ledger exists.

RC5 and the pre-feature schema-5 reader reject schema 6 through their actual
format check before writes; current reader preserves ordinary 3/4/5 behavior.
Stores are never upgraded in place. Proof/query payloads are ordinary local
checksummed facts, not signatures, trusted timestamps or tamper-proof archives.

Model-visible error JSON is limited to 8 KiB; restricted basis to 4 KiB; encoded
proof to 128 KiB. Host selects safe code/message/details, not raw backend errors,
credentials or private body text. Restricted Journal may contain sensitive
arguments; it is not encrypted by this feature. Archival proof cannot revive a
permit. Storage grows with retained operation/invocation facts.

Source/Codable additions: ToolPolicy.RecoverableErrors.confirmedNoEffect,
ToolNoEffectProof, ConfirmedNoEffectToolError (not Codable), ToolNoEffectError,
AgentFailure.noEffect, AgentSessionError.confirmedNoEffectJournalRequired,
AgentNoEffectConfirmation.executorProof, creation flag and per-call queries.
Exhaustive enum switches and stored policies may need updating. Existing
success Receipt validator, stable idempotency identity and default failure
behavior are unchanged.

## Acceptance categories

Actual Session/Run and package-outside-SDK tests cover correction counts,
rejected/conflict, insufficient/default proof, stale/cross-invocation proof,
authorization-origin failures, budgets, mixed batches, cancellation/revoke/
deadline and physical drain. Fault injection covers definite noncommit and
commitUnknown, with whole proof/error/audit publication. Independent processes
verify SIGKILL before/after publication; this is **not power-loss validation**.
Maintenance and missing call index/witness tests exercise recovery, and real
old readers exercise the format boundary. Existing #49 A/B/C, strict Evidence
replanning, runtime-tools, schema 3/4/5 and maintenance combination gates remain.

Live Provider, production Host/store and power-loss validation are NOT RUN.
Fixture timing/counts describe controlled SDK execution, not model or service
performance. Final per-SHA acceptance is recorded in the implementation PR.
