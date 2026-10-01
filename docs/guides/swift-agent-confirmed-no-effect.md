# Confirmed no-effect mutation outcomes

Implemented on main by PR #62; unreleased. PR #59 recorded the proposed design,
and PR #62 implemented ADR 0010. RC6 has not been released. ADRs 0011/0012
remain deferred and unimplemented.

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
`requiredAudit` still requires explicit Host configuration, the enterprise
authorizer and identity context. Schema 6/7 stores support authorization audit;
creating that store does not enable `requiredAudit`.

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
schema 5. Explicit no-effect creation now selects **schema 7**, with proof v2
and the same witnessed per-call indexes and transaction domain. Existing
schema 6 stores remain schema 6 and use proof v1 for new calls. There is no
in-place migration, replacement ledger or operation-domain change. Queries,
restoration, maintenance and GC retain the intent/proof/error associations;
missing call indexes or witnesses still throw.

The actual pre-fix main reader (`e8ef319857ce651002504d6d3592fdcba7574172`)
rejects schema 7 at its format check before opening for writes, including empty
stores. RC5 and the pre-feature schema-5 reader likewise reject it. The new
reader reads valid v1 data and continues writing v1 in schema 6. Requests that
cannot fit the bounded v1 envelope are rejected **before intent or executor**;
large-argument correction requires an explicitly created schema 7 store for
new work. Existing stores must not be discarded to bypass pending operations.

Proof v2 adds `argumentBinding` (`encoding`, lowercase SHA-256, `utf8Bytes`),
`originalArgumentsUTF8Bytes`, and a separate `receiptSummary`. `canonicalArguments`
and `receipt` are now optional public/Codable fields. Small arguments and the
original Receipt remain inline when their combined JSON encoding is at most
16 KiB; larger calls omit both inline copies, rather than inventing `{}` or
truncating parameters. The parameter digest always binds the full canonical
input. The summary's typed `operation.source == intentIdempotencyKey` and key
digest/count reference the authoritative intent, using the proof's Session,
Run and call IDs. It is an archival receipt summary, **not a ToolReceipt with a
substituted operationID**. `ConfirmedNoEffectToolError.receipt` retains the full
original executor Receipt; it is validated with the live invocation token at
the return boundary. The commit and disk reader independently recompute both
bindings from the persisted intent. Nothing regenerates the intent's existing
idempotency key or deduplication facts.

`swiftagent-json-v1` encodes UTF-8 with no whitespace; object keys sort by UTF-8
bytes; array order is preserved. Unicode scalar sequences are preserved without
normalization. Quote/backslash are escaped, slash is literal, and all controls
use lowercase `\u00xx`. Finite Decimal values use POSIX base-10 non-exponent
spelling, with zero encoded as `0`. This is a proof encoding, separate from the
unchanged AgentLoop idempotency algorithm. Golden tests fix key order, escaping,
Unicode and numeric output across macOS/Linux. The original input byte count is
separate from these canonical bytes; `utf8-v1` hashes the exact original key.
SHA-256 uses the existing swift-crypto package in AgentTools; no AgentTools to
AgentCore dependency is introduced and no Swift `hashValue` is used.

Model-visible error JSON remains limited to 8 KiB; restricted basis to 4 KiB;
encoded proof to 128 KiB. New confirmations also bound optional receipt revision
to 4 KiB. Static definition/binding/resource/expectation capacity is checked
before executor admission, reserving worst-case escaped basis/revision space.
Confirmed-no-effect inputs have an independent 1 MiB raw UTF-8 bound and 8 MiB
canonical/key bounds; Run call/turn/deadline and store budgets still apply.
These limits do not promise arbitrary or infinite input support. Proof storage
no longer grows with large body/key copies; retained authoritative intent and
conversation storage still do. Historical valid v1 receipts remain readable,
including revisions accepted before the new generation bound.

**Required audit is not expanded.** `capture` records a bounded/truncated
received proposal when raw arguments exceed 64 KiB, records `proposal_too_large`
and rejects it with `proposalTooLarge` before authorization/intent/executor.
It does not truncate and continue. Audit storage capability alone does not
enable requiredAudit; legacy large-input correction and audited no-effect
within existing limits are separate supported paths. Standard audit export
remains a summary. Enterprise audit support for large bodies is not delivered.

Host selects safe code/message/details, not credentials or raw backend errors.
Restricted Journal may contain sensitive arguments and is not encrypted by this
feature. These checksummed archival facts are not signatures, permissions or
trusted timestamps. Decoding a proof never restores its live nonce.

Additional source/Codable changes include the digest, operation-binding and
receipt-summary types and `AgentJournal.noEffectProofVersion`. Optional-field
consumers must handle compact v2. Existing policy/enum/exhaustive-switch impacts
from #62 remain. Successful Receipt validation, stable operation identity,
default failure behavior, budgets, audit/quarantine and physical drain remain.

## Already-pending operations

Installing this fix does not abort existing pending operations, erase Journal
history or authorize replay. The Host must drain/reopen the same store, enumerate
`recoverPendingMutations(sessionID:)`, and investigate **each specific operation**
against its real backend, original parameters and idempotency key. If the entire
operation is freshly verified to have had no effect and no outstanding work,
use the existing `AgentNoEffectConfirmation(basis:)` with
`abortMutation(_:confirmedNoEffect:)`. If an effect occurred, supply the trusted
original Receipt/output to `reconcileMutation`. If the result is partial,
unknown or still in flight, leave it pending and continue investigation. A
saved executor proof is not a new confirmation or execution permit. There is
no bulk cleanup or automatic store migration in this fix.

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
