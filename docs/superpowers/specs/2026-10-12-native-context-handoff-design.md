# Issue #105: explicit native context exit and queued reminders

Status: **scope/design approved by the user on 2026-10-12; implementation pending**.

Baseline: main `8b896eae05b5fd838e61e67a6cb69ca7c0e78458`, tree
`3c34571d48d65e6020434bc0e60d0bc794fed149`. #102 fixes the unsafe
Run-local reminder combination by refusing it before admission, and supports
idle compaction of provably completed/drained reminder turns. #103 fixes OpenAI
final-answer classification. Neither implements a durable native-to-ordinary exit.
The current main Linux build CI failed; this draft does not certify RC6.

## Scope and alternatives

Recommended first delivery: a public, explicit, idle native-to-ordinary transition
and per-reply controls in the existing follow-up resolver configuration. Keep
Run-local compaction plus required reminders refused. Long-running tool-loop
maintenance and a between-queued-replies maintenance hook need their own owner
and boundary contract and remain open under #105 until separately delivered.

Alternative: implement all three together, including a Run-owner maintenance
decision at a fully committed tool-result boundary. This is broader: retained
user/control placement, thinking-prefix validity, deadline and queue ownership
must be proved together. It must not be represented as an RC6 guard relaxation.

A new Session ID with Host-copied history is not an equivalent exit: it changes
session/mutation identity and does not retire the original durable authority.
Deleting the checkpoint or ignoring the native validation guard is rejected.

## First-delivery transition contract

The Host explicitly chooses semantic fallback to an ordinary request view. This
does not promise retention of the vendor's hidden reasoning or of the semantic
quality of a Host summary. The SDK preserves every canonical message, signed
payload, tool outcome, mutation identity, receipt, Run record and usage fact.

The public operation accepts a target frozen model binding and an explicit
policy authorizing omission of historical provider continuation blocks from the
new request view. No default or automatic fallback discards them. The transition
does not call a model, generate a summary, admit a user, execute a tool, reclassify
an old terminal or authorize reconciliation. Ordinary generated output remains
owned by a later normal Run.

Omission is bound to formal message IDs/positions at the retirement boundary,
not to all future continuations. Newly produced target-provider thinking remains
eligible for its normal native continuation checks. Core rejects projection
that reintroduces a retired payload, even when model/origin happen to match.
Source-referencing material is verified against the original Journal bytes
before applying the frozen omission to the corresponding source view. The
handoff accepts optional explicit capability binding, matching normal Run
registry selection, so its trusted tool baseline uses the actual frozen registry.

Eligibility is deliberately narrow: idle, no dispatcher reservation, no active
Run/maintenance, physically drained prior work, provably completed last Run,
closed tool pairing, no pending/quarantined mutation, and a matching persistent
history/native/control baseline. Active unanswered reminders and persistent
mid-conversation instructions refuse locally in this first delivery. Completed
turn reminders may retire with the completed turn; the next real user supplies
its own explicit controls. No instruction comes from summary/model text.

Core constructs a read-only ordinary source view from the full canonical history
and the authorized continuation omission. Message ordering, formal IDs and
tool call/result pairs stay intact; empty assistant content is permitted only
where the target adapter's ordinary-message contract permits it. Otherwise
preflight fails. There are no synthetic user, tool-result or assistant answers.
The Host projector sees a source-bound snapshot of this ordinary view; Core
validates source identity, tool pairing, continuation exclusion and the actual
final byte/token budgets. Historical read-only effect proof is not reconstructed
from the current registry. Unsupported excerpts preserve the original results
or fail. If the target adapter supports trusted controls, Core establishes an
explicit new control epoch and a fresh baseline from the target frozen registry
at the closed retirement boundary. Historical control entries remain recorded
but are not replayed as authority in the new epoch. The next real user may append
its new reminder there. This is an authorized baseline transition, not permission
to infer an arbitrary old history's tool baseline. Adapters lacking the target
ordinary-view/control capability refuse; the existing generic restoration guard
must not simply be removed.

Preflight must succeed before the state changes. Under the existing writer lease,
one publication transaction compares the history head plus expected native and
control identities, rechecks last-Run completion/pending state, and records the
retirement and unchanged canonical checkpoint. Metadata-only races must be
detected. Actor state changes only after definite commit. Definite failure keeps
the prior state; commitUnknown poisons continued use and requires drain plus a
fresh Session/reopen to inspect the actual committed state. Cancellation and
deadline apply through preflight and until the publication seal. Publication
retains the existing definite/unknown commit semantics. wait and physical drain
remain separate; a late projector result cannot publish or dispatch.

The retirement is durable, generation-bound, and contains enough identity to
prevent the retired signed payloads from being replayed after reopen. Later
ordinary requests continue to apply the explicit source transformation. A new
native chain, if explicitly enabled later, starts from the new ordinary baseline
and cannot reactivate an ancestral checkpoint or control generation.

## Storage and reader gate

An optional header field alone is unsafe: existing schema-11 readers can ignore
unknown fields. Use an explicit opt-in new store format (schema 12 if no other
work claims that number), retaining the default schema 3 and current opt-in
formats. Old readers must refuse open/append/maintenance before any write.
Do not encode a fake provider compaction or misuse a vendor signature as a
retirement tombstone.

Existing native stores need an explicit, writer-exclusive format upgrade path
before this operation can be supported there. No automatic upgrade, silent
copy to a new Session or global physical revision used as a history witness.
The upgrade must have its own crash/definite/unknown recovery proof and preserve
the complete existing session/native/control state. If that format transition
cannot be proved safely in the first PR, split it into a prerequisite PR; do not
claim existing schema-11 native sessions can exit until both parts land.

Independent review found that FORMAT and CURRENT cannot be changed by two
ordinary writes and called that gap blocking. The prerequisite uses an explicit
offline URL operation: close/drain all owners of the shared Journal first, then
acquire the existing whole-store writer lock. It prepares a target root equal to
the old root except formatDigest. The new schema-12 format embeds a bounded
upgrade bridge: exact old format bytes, old CURRENT identity, and target root ID.
Its digest binds the prepared target root; it does not embed the target root's
digest, avoiding a hash cycle. Persist the new format/reader gate, then publish
CURRENT. Before any normal open truncation or maintenance, a new reader seeing
the exact bridged old CURRENT verifies old format/root and that target-root
equivalence, then rolls forward to the prepared target. Any other mismatching
state refuses. Once CURRENT names a normal schema-12 root, the bridge grants no
rollback or repair authority. Existing old-format handles never survive the
offline upgrade. Format replacement may-have-happened errors are commitUnknown;
pre-gate failures preserve the schema-11 store. This upgrade and a later per-
Session retirement are distinct publications with separate acceptance evidence.

## Queued controls

Add an optional `AgentRunContextControls` to `AgentFollowUpConfiguration` using
a new overload while retaining the exact old initializer. The dispatcher freezes
the resolver result once and passes these controls through the normal startup
preflight/admission path; it does not acquire a second writer or serialize trusted
instruction text into the durable user-input record. configurationRef remains the
Host's stable resolution identity, not an authorization. Reopen uses the resolver
again under the existing at-least-once resolution semantics; no admitted input
or completed tool is replayed to refresh its reminder.

Pause continues to retain dispatcher ownership. Direct compact/handoff stays
refused until the queue is stopped/drained in this delivery. A maintenance hook
between queued replies is not disguised as a resolver callback borrowing a writer.

## Evidence required before merge

- Public File Journal fixture: native reply/compact/drain, explicit ordinary
  exit, new model or changed registry plus prepared source-bound projection,
  next real user, exact canonical/pending/receipts/terminal/usage equality,
  close/reopen and next ordinary request without the retired opaque state.
- Local refusal before publication/HTTP for stale actor, changed metadata,
  active writer/queue, incomplete Run, pending mutation, persistent instructions,
  unmatched tools, bad source proof, unknown target capability or hard budget.
- Publication barrier races, cancellation/deadline plus late projection, definite
  failure and commitUnknown; fresh actor observes only the actual durable result.
- Reader inspection/append/maintenance refusal with byte-for-byte unchanged
  upgraded stores, new-reader old-format compatibility, exact old initializer
  and conformer public fixtures, explicit upgrade crash recovery.
- Queued two-reply public HTTP fixture with distinct reminders, one execution
  per tool, no duplicate admission, cancellation/drain and reopen consistency.
- Existing mutation/no-effect, queue, context, native thinking, publication and
  complete repository gates plus independent three-direction review on final diff.

No paid live calls, OtohaAI pin/product changes, tag or Release. Fixtures establish
local policy and wire behavior; they do not verify vendor signatures or qualify
the current endpoint/account/model. #105 remains open for undelivered scope.

## Protocol basis

Checked 2026-10-12: [Anthropic on-demand compaction](https://platform.claude.com/docs/en/build-with-claude/compaction-on-demand)
requires reasserting still-needed summarized system instructions after the next
real user turn. [Preserved thinking](https://platform.claude.com/docs/en/build-with-claude/compaction-thinking-blocks)
has additional kept-prefix restrictions. Same-model/origin identity alone does
not prove compatibility. This design retains the current local refusals until
new transformations have their own SDK and protocol evidence.
