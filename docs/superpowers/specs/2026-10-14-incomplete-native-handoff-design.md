# Issue #108: explicit ordinary handoff from an incomplete native turn

Status: **design approved by the user on 2026-10-14; implementation and acceptance in progress**.

Baseline main: `a7940ae0286c7accef4aef8647919c57c042b8b9`, tree
`e29e6bce80098cd3c49ea61a6a2c55d26a2ef2e8`. Published RC6 is immutable.
This is a subsequent SDK increment on `feat/incomplete-native-handoff`, not a
replacement RC6 tag or an OtohaAI integration change. No paid live calls.

## Problem and chosen approach

The current Session requires an assistant at the last formal position and a
persisted `.completed` latest Run. The same completion requirement is checked
again in the publication transaction. An admitted Run that ends with
`max_tokens`, cancellation or an error cannot legally retire its old native
checkpoint/control epoch, even after physical drain and verified reconciliation.
Reopening does not change that terminal and must not pretend otherwise.

Recommended: a distinct closed-turn proof for explicitly authorized incomplete
handoff. The proof binds the real latest admission and unchanged terminal to the
durable conversation boundary. Existing writer ownership establishes drain;
existing mutation state establishes settlement. No second mutation ledger.

An alternative is to add an entirely separate incomplete-handoff operation.
It gives explicit naming but duplicates the same ownership, preflight,
publication and drain machinery. A required-label overload reuses that machinery
while preserving the exact existing public function signature and behavior.

Simply accepting every logical terminal, or treating drain as `.completed`, is
unsafe: terminal/drain alone prove neither legal tool pairing nor settlement.
A new conversation with copied history changes identity and does not retire the
original authority. Neither is the implementation strategy.

## Public contract

Keep the existing `handoffToOrdinary` signature and its completed-turn semantics.
Add an overload with a required `allowingIncompleteTurn: Bool` label, in addition
to the existing explicit `discardingRetiredProviderContinuations: Bool` consent.
`false` uses the old completed-turn path; `true` permits the new proof path on a
capable durable store. The Host supplies the exact target deployment binding and
optional capability binding. This is an explicit fallback, never automatic.

Add public read-only `AgentJournal.conversationControlState(sessionID:)` access,
following the existing native checkpoint/handoff read APIs. It returns the
current durable control state, not Session actor cache. Hosts can combine this
with existing Run lookup to display admitted-but-no-response states. This read
is advisory: it does not certify eligibility, drain, settlement or authorization.
The mutation/transition operation independently reads and validates its own
consistent snapshot. It grants no writer or executor authority.

The new handoff records a separately named closed-turn proof. Existing
`completedRunID` retains its meaning: it is never populated with an incomplete
Run to suggest success. The proof carries the latest admitted Run identity and
actual terminal, admission identity/boundary, persistent history head and exact
retirement anchor. The handoff also binds the target model, root configuration,
origin and frozen tool declaration/registry digest, even for target adapters that
do not implement conversation controls. The old public fields remain available.

## Eligibility and boundary proof

Supported terminals are the existing persisted `.incomplete`, `.cancelled`,
`.failed` and `.refused` cases; `.completed` retains the existing successful path.
No category is an effect or drain proof. Each transition requires all of:

- idle Session and no dispatcher ownership; existing identity/Journal leases
  exclude another active or physically draining Run, including another actor;
- a real latest durable admission, its actual persisted terminal and matching
  history/native/control/handoff snapshot; a checkpoint import is not admission;
- nonempty formal history and legal complete tool call/result pairing;
- no pending, quarantined or otherwise unresolved mutation, using the existing
  mutation recovery state and indexes, not today's tool registration policies;
- no persistent trusted instruction that would be silently discarded;
- exact target binding and capability validity, explicit historical continuation
  omission consent, and a valid target preflight with actual budgets.

For this new proof the last formal message may be user, tool or assistant. A
trailing admitted user with no response, partial assistant output, or a fully
settled tool-result group is not a manufactured completed answer. Unanswered
tool calls remain unsupported; this task does not invent error results or execute
missing tools to close them. A crashed admission without any durable terminal is
also unsupported until a separate recovery contract establishes a terminal.
The in-memory Journal is not a substitute for this durable proof.

If the Run has an uncertain mutation, drain it, reconcile using Host-verified
receipt/output or supported no-effect proof, then create a fresh same-ID Session
on the same Journal handle. An old actor with stale history remains refused.
The earlier Run's logical terminal is preserved exactly.

## Data flow and publication

Acquire existing maintenance/writer ownership and wait for owned prior physical
work as today. Read a single store snapshot to prepare the closed-turn proof.
Check canonical tool pairing and unresolved mutation state. Build the ordinary
request view by omitting only retired-prefix provider continuations; keep every
canonical message, signed payload, tool outcome, receipt, admission, terminal,
usage fact and mutation identity unchanged.

Retire old reminder authority at that explicit boundary, including an unanswered
per-Run reminder. This is not a claim that the old reminder was fulfilled.
Initialize the target control epoch from the actual frozen target registry.
Persistent instructions remain refused. A subsequent real user chooses its own
new controls; there is no synthetic user, assistant, reminder response or model
request during handoff.

Run the existing source/continuation/pairing/budget preflight on the candidate
ordinary view under the existing deadline/cancellation owner. Bind the new
target model and registry evidence to that exact preflight; recheck capabilities
before the publication seal. Later requests and reopened Sessions validate that
target evidence before admission/dispatch. Future legitimate continuations are
not retired, and the existing reinjection guard remains active.

Within the actual publication transaction, recheck the corresponding history
head, latest admission and exact terminal, retirement anchor, native/control
identities, prior handoff generation and current unresolved mutation state.
Detect relevant metadata-only races without using global CURRENT or a physical
maintenance revision as the conversation witness. Persist proof, retirement and
the unchanged canonical checkpoint atomically. Install actor state only after
definite commit. No proof can independently authorize settlement or Run execution.

Cancellation/deadline apply until publication seals. Late projector results cannot
publish or dispatch. Definite failure retains old authority; `commitUnknown`
poisons the actor and requires drain plus a fresh Session/reopen to inspect the
actual durable result. `wait` and `waitForDrain` keep their distinct contracts.
Reconciliation and handoff do not rewrite the old Run terminal or retry a tool.

## Store and reader compatibility

Use explicit opt-in schema 14 for incomplete-turn retirement authority. Schema
12/13 readers have only the completed-turn contract and must refuse the new
store before inspect/append/maintenance, rather than ignore new proof fields.
Default schema 3 and existing create signatures/formats are unchanged. New
named creation factories explicitly opt in (a single-Bool overload would make
existing function references ambiguous); schema 14 retains schema
13 capabilities, including typed files, rather than downgrade an existing store.

Provide explicit offline schema 12/13 to 14 upgrade. All owners of the shared
Journal must close/drain before this separate whole-store operation. Preserve
store/session identity, canonical messages and all execution/control/native
state. Reuse the existing durable reader gate and narrowly validated upgrade
bridge; nested old bridges must remain bounded and fully validated. Test actual
crash recovery, not just two successful format/root writes. No automatic upgrade,
downgrade or schema 3 to 14 migration. A schema 11 Host can perform the existing
11 to 12 upgrade first, then the new upgrade; those are separate transactions.

Old supported formats remain readable/appendable. The new incomplete path
refuses them before projection/publication. Completed-turn handoff remains
supported on schema 12/13. Storage, proof validation and Session runtime must
ship together, with actual RC6 schema-13 reader rejection evidence.

## Acceptance and independent review

First preserve runtime RED evidence for the current refusal on real File Journal
admitted incomplete turns. Public API compile absence is separately labelled,
not presented as runtime RED. Then prove GREEN with deterministic Swift HTTP
fixtures, no paid service or signature-verification simulation:

- schema-12 repro upgraded to 14: native checkpoint plus required reminder,
  max-tokens output, transport-held cancellation and provider error after
  admission; drain, change target model/deployment or registry, explicitly hand
  off without extra requests/tools/admission, and continue with a real user;
- reopen after incomplete Run before handoff, and again after handoff; durable
  read-only controls are visible and all canonical history/old terminal/effects
  remain exact; new target controls and continuations function normally;
- real pending mutation refusal, verified reconciliation, fresh same-ID actor
  handoff success, and no original mutation replay or fabricated settlement;
- user-only, partial assistant and settled tool-result tails; unmatched calls,
  missing terminal/imported checkpoint, persistent instructions, missing consent,
  wrong target model/origin/registry, stale actor and active/late drain refusal;
- publication barriers for changed terminal/admission and pending metadata with
  unchanged history head; unrelated Session writes/maintenance do not misreject;
- cancellation/deadline during noncooperative projection, capability revocation,
  definite failure/commitUnknown, durable reopen, reinjection and budget refusal;
- actual RC6 old-reader inspect/append/maintenance rejection with unchanged bytes,
  new-reader old-format compatibility, both upgrade sources and controlled crash
  points, missing/altered recovery target refusal, typed-file preservation;
- public external Host fixture uses only exported APIs and verifies target
  requests, executor counts, state inspection, reconciliation and reopen.

Run the complete applicable repository gates from their actual scripts and
retain first failures. Obtain independent final-diff reviews for storage and
mutation consistency, Provider continuation/request behavior, and runtime/public
API/documentation. Resolve blocking findings, push a PR and wait for exact-head
CI; do not bypass protected checks. Published RC6/tag remain untouched. No new
tag/Release is authorized by this design.

Update the stable handoff/recovery/versioning/public API guides and CHANGELOG
with the new opt-in format and refusal/recovery boundaries. Record candidate
source/tree, command/platform evidence, hosted CI, reviews and remaining limits
in an issue-108 acceptance document. Update #108 based on actual merged evidence;
do not close #105's unrelated long-tool-loop/queued-maintenance work.

## Explicitly deferred

No Run-local native compaction with required reminders, arbitrary current-Run
tool-output shortening, between-queued-replies maintenance, automatic summary,
terminal recovery for crash-without-terminal, historical effect-provenance
inference, universal Provider compression, OtohaAI changes or live qualification.
Target adapters may still reject the ordinary view under their real local
contract; handoff never retries the original Run to hide that refusal.
