# ADR 0013: native context operations and append-only controls

Status: accepted for implementation of #99; not a release or live qualification.
Base: 34103af09baf0ecadfb27389803126ad0dd8f4ac, tree
1a00400a9142184973a2453dc5b1841494d094f2. Requirements and acceptance matrix:
SwiftAgent #99 and the supplied implementation prompt.

## Decision

Reuse provider continuations and the per-session Journal checkpoint transaction.
Introduce typed native context transition metadata and a persisted effective
checkpoint. Canonical messages and tool/mutation facts are never compressed.
Do not implement a second conversation ledger or hide paid compaction in a
projector. Provider-native transformations retain their complete opaque wire
state and are scoped to the actual adapter/route owner, model, deployment,
root configuration and source lineage.

The alternatives were provider-only trimming (cannot enforce publication,
recovery or ownership), and replacing canonical history (destroys execution
facts). Neither satisfies #99. Typed checkpoint metadata plus an opt-in reader
boundary provides validation without teaching Core vendor cryptography.

## Public contract

AgentModels defines open compaction mode identities, explicit automatic policy,
optional ModelProvider compaction capability, operation request/result,
maintenance stop classification, native transition/checkpoint scope and
input-transformations/iteration usage. Existing conformers need no new method.
Old initializer function signatures remain; new overloads have required new
labels. New optional Codable data decodes absent fields as unknown.

Four distinct protocols are implemented: Anthropic threshold (>=50,000 input
trigger, pause bounded), Anthropic on-demand (standalone signed stage, mutually
exclusive with threshold configuration), OpenAI automatic (>=1,000 trigger,
latest complete compaction item plus following items), and OpenAI standalone
(nonstreaming /responses/compact; preserve the entire returned window).
Trigger is not a hard context limit. Unknown modes are storable metadata but
not executable. Adapter implementation and Host-qualified deployment support
are separate from catalog support. Compatible proxies inherit no beta support.

AgentSession exposes idle compact with operation/invocation identity, budget,
usage and cancellation. It acquires the same Session/Journal writer ownership
as Run startup, waits for physical drain and retains its reservation through
noncooperative transport/publication exit. Run-internal compaction shares the
remaining Run deadline and ownership through the same executor. Native summary
or pause is maintenance, never a final user answer. Explicit outcome distinguishes
published/no summary from failure/cancellation/timeout; uncertain publication
retains commitUnknown. No operation identity promises remote exactly-once work.

## Effective context and publication

Build a verified effective view first, then apply permitted suffix projection
and final token/byte checks, and send that same request. Native coverage binds
stable source anchors and input lineage, not a perpetually unchanged head.
The existing per-session history witness is publication CAS. Append changes
head but does not invalidate an anchored checkpoint. Native replay may begin
inside an assistant response, so response item order is retained.

Only a complete accepted response can publish its transition together with
its checkpoint. Steering or rejected/stripped calls/continuations revoke
associated candidates. Explicit compact publishes independently without a
fake assistant answer. EOF/partial/failed/incomplete results install nothing;
reported usage remains observable. Old effective state survives failure.
Model/deployment/root configuration/projected covered-source changes reject
unless explicit semantic handoff reconstructs from authorized canonical source.

Add opt-in native-context store semantics with an explicit new format boundary;
new reader reads old stores, old readers reject the new format before writes or
maintenance. No automatic upgrade, lossy migration or mutation replay.

## Append-only Anthropic controls

Trusted tool baseline plus appended differences drives BOTH visible declarations
and allowed executors. Inline by-value definitions support new/schema-updated
client tools; reference controls only refer to known definitions. Model output
and compaction tool_changes never grant authority. Append after a full user or
client tool-result group; never split tool pairing. Reopen restores the trusted
state; historical calls retain their original schemas.

Run reminder is typed harness system control, distinct from user steering and
root instructions. Preserve each native clear_at:next_user_message message;
append at most once per new complete user boundary, including grouped results.
Retry reuses the request; pause without a new user adds none. First release
supports no-native-compaction Runs and idle on-demand whole-history compact
followed by a real new user and reminder. Threshold+required reminder refuses
before HTTP; unsafe reminder coverage/tail combinations also refuse.

Thinking mismatch defaults to RC6 strict unchanged-prefix behavior. Explicit
Host-qualified error/drop_block encodes native binding controls and beta;
retain original signatures/witnesses and expose replacement-snapshot typed
input_transformations mapped from encoded paths to stable sources. Legal
native append/compaction transitions are validated first; drop_block does not
relax payload, origin or registry checks. No local signature validation claim.

## Catalog, usage and pricing

Catalog optional pricing uses validated Decimal per-million rates, explicit
currency/provenance and ordered whole-sampling tiers (inclusive or exclusive).
Nil is unknown, explicit zero is free. Select per sampling prompt length and
fixed service snapshot, never aggregate Run usage. Compaction descriptors are
open mode strings with tri-state support, minima, source and executability;
missing new metadata does not make metadataComplete stronger.

Usage retains cumulative .usage events and old fields, adding optional ordered
iteration snapshots with kind/model/coverage and token subsets. Native tables
replace, missing preserves, empty clears. Complete children define whole-response
aggregate; top-level and children are not double counted. Partial totals stay
unknown. HTTP-internal sampling is not another invocation. Examples preserve
cache-write/TTL pricing and report unknown or partially known cost honestly.

## Verification and delivery

TDD for engine changes; real encoders/decoders/transport fixtures for all four
protocols, malformed streams and controls. File Journal acceptance covers CAS,
publication faults, cancellation/drain, same Run/next Run/reopen, immutable
canonical/tool facts and old-reader refusal. Public external clients prove
old initializer/conformer/data compatibility and complete integration flows.
Three independent final-diff reviews cover Provider, Core/Journal and
Catalog/Usage/public clients. Run existing full gates without lowering coverage.
No paid live calls, Host changes, version assignment, tag or Release. Fixture
signatures do not establish current service/model/account qualification.

### Core implementation decisions (stage evidence, not complete #99 acceptance)

Idle compact returns `AgentCompactionOperation`; explicit `wait`, `cancel`, and
`waitForDrain` separate logical outcomes from transport/preflight exit. A frozen
`AgentNativeContextPolicy.compactBeforeGeneration` invokes the same executor from
an admitted Run without reacquiring its writer reservation. Native maintenance
never seals the final-answer deadline gate, and continuation attempts are bounded.
Standalone usage has an independent invocation in `AgentEvent.compaction`.

Canonical ranges are not silently renumbered after a native covered prefix. The
first implementation rejects existing source-bound range/excerpt projectors in
that combination; identity and custom suffix projectors still undergo Core
revision/digest/epoch and tool-pair checks. Adding an explicit canonical-to-native
range mapping is a later API extension. Covered history remains immutable.

Native token budgets require an `AgentNativeContextTokenEstimator` that explicitly
handles the opaque native window. Older estimators cannot accidentally count only
the visible suffix as the whole request. Ciphertext length is used only for bytes,
never tokens. The optional adapter wire-witness protocol binds publication to the
same serialized body checked before transport. A trigger remains a service policy,
not a pre-dispatch hard limit.

Optional compact capability alone does not enable native state or require schema
11 for ordinary requests. Actual enabled policies and restored native checkpoints
require the new opt-in format; unsupported explicit operations fail before input
admission. Provider protocol/HTTP qualification and external public examples are
subsequent stages and have not yet been accepted.
