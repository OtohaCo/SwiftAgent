# SwiftAgent Semantic Versioning

## Queued mutation identity (unreleased, Issue #74)

Queued inputs now explicitly select `AgentOperationIdentity.perCall` or
`.operation(String)`. The existing `operationID:` initializer keeps its
operation semantics. `AgentFollowUpInput.operationID` and
`AgentFollowUpRecord.operationID` change from `String` to `String?`: nil means
per-call mode; it is never an empty/synthetic ID. This is a source break for
clients requiring a nonoptional property. Both records expose `identity`.

Per-call dispatch passes no operation ID to the existing Run algorithm; each
new call ID uses that Run's ID/call ID. Duplicate call IDs remain protocol
errors. There is no cross-call/Run deduplication, automatic replay or recovery.
Same input ID retries compare exact text, configuration reference and identity
(including exact operation ID bytes), and return the current durable record.
An identity change conflicts even after admission/withdrawal.

Explicit `supportsPerCallFollowUps: true` creation selects format schema 8,
including schema-7 confirmed-no-effect and audit capabilities. Default and
other creation options retain their formats. Existing schema 3–7 stores stay
in their original format and reject per-call enqueue before publication with
`unsupportedFormat`. Their records decode as `.operation(storedOperationID)`.
There is no in-place migration, new-ledger escape hatch or identity reset.
Schema 8 is needed because schema-7 binaries could otherwise ignore a new
field and erase or misinterpret identity during maintenance. The actual
unmodified `27ceea564740bca8deac841b9e8c0231c2cd13ef` reader is exercised by
`Scripts/verify-per-call-compatibility.sh`: old open/append/maintain reject
schema 8 before and after new-reader maintenance. New readers retain old
operation records and per-call records on reopen. Pending intent,
needs-reconciliation, settlement, confirmed-no-effect, cancellation and drain
contracts remain unchanged; uncertain effects are inspected, never retried.

last-verified: 2026-10-02

## RC6 Decision evaluation (unreleased)

`Examples/DecisionEvaluation` is an optional package-outside-SDK Host consumer
and evaluation runner. `AgentDecisions`, Jev Noul/Choice/Score, their Codable
forms, and root SDK products/dependency directions are unchanged. No Core
Decision-service dependency, Journal schema change, authorization conversion
or native OpenAI Decisions API is added. The native protocol remains
unestablished; ordinary Responses is not relabeled as native Decisions.

The example's versioned synthetic dataset and JSONL ledger are evaluation
artifacts, not SDK approvals, execution facts or a recoverable Journal backup.
Ordinary CI uses no credentials or paid services. Host-attested live budget
bounds do not authenticate provider pricing or guarantee a server bill.

SwiftAgent follows Swift Package Manager rules, not a promise of ABI stability.
A major version is required when a change can fail a client that compiled
against the previous public API.

## Breaking

Treat as breaking:

- Removing or renaming a public type, method, property, or enum case
- Changing a public method’s parameters, throws, isolation, or Sendable contract
- Adding a case to a public enum that clients switch on exhaustively
- Changing `AgentEvent` or `ModelEvent` ordering, terminal-once, or cancellation
  ownership
- Changing tool execution safety: authorization, Evidence, Receipt, mutation
  admission, or journal settlement
- Changing recovery so a restart can replay an external mutation
- Making a previously non-throwing public API throw
- Narrowing `public` to `package` or `internal`

Adding `AgentFailure.session` is breaking for exhaustive switches even though it
is a new classified case.

`1.0.0-rc.5` bounded pre-admission replanning adds
`AgentEvent.toolAdmissionRejected`, `AgentJournalEvent.toolAdmissionRejected`
and `AgentSessionError.admissionRejectionJournalRequired`. Exhaustive public
enum switches must be updated even when the policy remains disabled. A new
rejection-capable store opts in at creation and uses format schema 4; the
unmodified RC4 reader rejects its `format.json` at open, even if no rejection
has occurred. The default new store remains schema 3 and the old reader can
open, append and maintain it. The new reader opens ordinary RC4 schema-3
stores, but rejects an opt-in Run there before contacting the provider. Neither
direction automatically migrates or downgrades the store, and a new store does
not inherit an old store's operation-deduplication facts. The opt-in does not
change stable mutation identities, Evidence authority or Receipt settlement.
Existing `AgentConfiguration` construction defaults to `.disabled`.

Also in `1.0.0-rc.5`: `ModelProviderRoute` returns opaque continuation state
only to the candidate that produced it, recorded in a Route-owned continuation
format. A request whose state the Route cannot attribute to one of its current
candidates, including state saved by RC4 through a Route and state from
candidates without declared IDs after a restart, now fails with
`fallbackBlocked` instead of reaching a candidate.
`ModelProviderFallbackPolicyError` adds `invalidCandidateIdentity`, thrown by
`ModelProviderRoute.init` for an invalid or duplicate candidate ID.

Also in `1.0.0-rc.5`: a cancelled or failed Run whose retained steering cannot
be committed now reports that Journal error (for example `commitUnknown`) from
`wait()` and its terminal event instead of `CancellationError` or its own
failure.

Also in `1.0.0-rc.5`: while a failed segment rotation leaves the active segment
past `segmentBytes`, Run startup, mutation admission and follow-up enqueue fail
with `maintenanceRequired` until maintenance rotates it.

Also in `1.0.0-rc.5`: opening a store with a `maxWorkBytes` smaller than its
retained segments or packs fails with the new
`AgentJournalError.maintenanceBudgetTooSmall(requiredWorkBytes:)`; exhaustive
switches must add it.

Also in `1.0.0-rc.5`: `AgentFailure` adds `modelBinding`, `capability`,
`contextPipeline` and `contextProjection`. These Core errors previously reached
the event stream as `unclassified`; exhaustive switches must add the cases.
`JournalMaintenancePolicy` now rejects a `maxWorkBytes` smaller than the
largest segment rotation can seal. Such a policy previously initialized, then
stalled maintenance permanently.

## RC6 candidate, unreleased

Projection `conversationRevision` now follows the exact committed live Session
snapshot after multi-result tool commits; startup preflight still uses a reserved
candidate revision. `contextEpoch` remains a distinct Run-local source-generation
coordinate. Numeric values after a tool batch can differ from earlier versions;
cache consumers must bind Session/Run, revision, epoch and exact source digest.
No projection field, Codable key or digest format changes. Session `history`
remains a loaded-memory view; the existing throwing `conversationSnapshot()` is
the restoration interface, including current instructions and storage errors.

`AgentFailure.authorization` and `AgentFailure.auditPersistence` are source breaks
for exhaustive switches. The candidate
classifies the new `AgentAuthorizationError`; presentation consumers must handle
it. Existing construction defaults to legacy and preserves tool execution.
`AgentTool.authorizationBinding(for:)` has a default; a conformer already using
that signature must adopt its now-public requirement, as with RC5 `definition`.
New read-only query/export contracts are additive. The metrics initializer adds
a defaulted batch-encoding counter.

Explicit audit-capable creation uses schema 5; RC5 readers reject it at open,
including empty stores. The new reader opens schema 3/4 without conversion and
refuses required audit there before input/provider work. Default creation stays
schema 3; rejection-only stays schema 4. Actual cross-reader open/append/maintain
checks are in `Scripts/verify-rc6-compatibility.sh`. No in-place migration or
new-directory deduplication transfer is provided. See
[Audited Authorization](swift-agent-authorization-audit.md).

## 1.0 freeze decisions (SAI-026B)

These source breaks happen before the first tagged 1.0:

- Mutation Sessions require `journal.storage == .durable`. `AgentJournal()` is
  not durable. The new `AgentIncrementalJournal.create/open` entry points
  provide the local durable store. `.durable` is configured persistence mode,
  not a guarantee that every later write succeeds.
- `Agent(model:provider:tools:configuration:)` is the advanced constructor.
  The only extra convenience is `instructions:`. Do not reintroduce a parallel
  list of limit parameters on `Agent`.
- `AnyAgentTool`, `ToolRegistry`, and `PreparedToolCall` are package-only.
  `ToolRegistryError` remains public.

## RC4 Journal replacement

The RC4 follow-up queue advances the segmented file store from format schema
1 / `BatchV1` through an unreleased schema-2 candidate to schema 3. Schema 3
retains the `BatchV2` payload and adds committed per-key index witnesses and
stable commit IDs on positions. New readers reject schema 1 and 2 without
overwrite or migration, and old readers reject schema 3. This is a
breaking durable-format boundary; Host operators must stop old workflows and
resolve their pending effects before choosing a new store. It does not alter
the Journal operation domain or a mutation's stable `operationID`. The
queue-specific public API is opt-in; `run` and `steer` retain their meaning.
`AgentJournal.close()` now releases an otherwise drained poisoned handle while
preserving its `commitUnknown` recovery responsibility. Its old Session cannot
restart work; only a fresh open may interpret the durable root.

The segmented file Journal intentionally breaks the old framed file format and
public `AgentJournal(persistenceURL:)`, `load(from:)`, `persist(to:)`,
`snapshot()`, and manual file compaction surface. `pendingMutations`,
`latestCheckpoint`, and `conversationSnapshot` now throw to report storage
failures honestly. The lossy canonical-history compactor has been removed;
`maxModelContextUTF8Bytes` applies to a request projection. A previously
published RC client must adopt the new API and cannot directly open its old
Journal. This change requires a version boundary before publication. See
[Journal](swift-agent-journal.md) for the new contract.

## Non-breaking

RC4 adds opt-in Session-created `AgentCapabilityBinding` and a
`session.run(_:capabilities:using:...)` overload. Bound Runs expose a
non-authorizing `AgentRun.capabilities` diagnostic snapshot; `revoke()` and
`waitForDrain()` are distinct. Existing Runs without an explicit binding
retain their current tool behavior. Dynamic mutation tools require durable
Journal storage before candidate input admission. The RC4 API does not restore
runtime permissions after restart.

RC4 adds opt-in `AgentCompositeContextProjector`, source materials, bounded
reports and indexed `AgentSession` source-range queries. The existing binding
initializer gains an optional report buffer with a default of `nil`; identity
projection remains the default. The public projection input/result structs
gain defaulted source-ID and report parameters. Rebuild downstream clients
against the RC4 tag and regenerate their symbol graph; this entry describes
the API contract, while the release note records qualification limits.

Source-bound wrappers now declare `AgentContextSourceReferencing` requirements;
`AgentContextProjectionInput` carries committed read-only result evidence
instead of a current tool-name allowlist. There is no durable read-only effect
history in the v1 Journal, so excerpts of pre-restart results fail closed.

The `1.0.0-rc.5` `AgentTool.definition` requirement has a default that returns
the type's static values, so existing tools compile and register unchanged.
`RuntimeAgentTool` is a new protocol for tools named at runtime. A conforming
type that already declares its own `definition` is affected. If it is a
`ModelToolDefinition` less accessible than the type, it no longer compiles. If
it is an internal or public `ModelToolDefinition`, it becomes the tool's
definition. A member of another type is unaffected.

Unreleased deferred tools are additive. `AgentCapabilityTool.init` gains a
defaulted `exposure:` (`ToolExposure`, default `.declared`) and `ToolResult.init`
a defaulted `declaredTools:` (default empty), so existing calls compile and keep
their meaning. Code that names either initializer by its old compound name, for
example `AgentCapabilityTool.init(id:version:tool:)` as a function value, no
longer compiles. `AgentCapabilityInfo.Tool.exposure` is encoded only for
`.deferred` and decodes as `.declared` when absent, so a binding without
deferred tools encodes and decodes as before. Requests, token estimates and
Provider capability checks carry only declared tools, which is every tool
unless a Host defers some. No Journal format, schema or operation identity
changes. See [Deferred Tools](swift-agent-tools.md#deferred-tools-unreleased).

Treat as non-breaking when existing clients still compile and keep the same
runtime meaning:

- A new module or provider package that nobody is required to link
- A new convenience initializer or factory that does not change defaults of
  existing initializers
- A new optional protocol requirement with a default
- Documentation, DocC, and internal performance work
- New tests

Unknown future provider values belong on typed extension points
(`StopReason.unknown`, optional usage fields, `ModelProviderContinuation`), not
`[String: Any]`.

Post-`1.0.0-rc.1`, OpenAI and DeepSeek reasoning configuration use extensible
`RawRepresentable` structs, so a new non-empty wire value does not require a
new enum case. Provider construction still validates values that cannot form a
legal request.

The RC.2 candidate graph contains 1,759 precise public identifiers and 188
top-level public types. Relative to the immutable rc.1 graph of 956
identifiers and 100 top-level types, the candidate adds 803 identifiers and
removes none. The additions are the optional `AgentCatalog`, `AgentDecisions`,
`AgentJevProvider`, `AgentUsage`, model bindings, projection contracts,
continuation origin metadata, provider adapters and the existing Host example
surface. They are source-compatible for clients that continue using the
original `Agent` and `AgentSession.run(_:)` APIs. The reproducible command and
module breakdown are in [the public API inventory](swift-agent-public-api.md).

The release checklist records the final candidate SHA. RC2's release scope and
limitations are recorded in [the RC2 release note](../releases/1.0.0-rc.2.md).
The public API policy in this guide is normative; one-time audit evidence stays
in the parent project's Kanban records.

## Enums

In Swift, a new public enum case is a source break for exhaustive `switch`.
This package will not claim “adding cases is compatible.” If a vocabulary must
grow without a major version, it needs an `unknown` or non-frozen payload
already in 1.0, as `StopReason.unknown` does.

## What this package does not promise

- Binary / ABI stability across compilers
- Library evolution (`@frozen` / `@available`) beyond what the current sources
  declare
- Compatibility for `package` APIs, test helpers, or WorkspaceAgent host types
  as if they were the Core SDK

The additive `AgentContextProjectionInput.sourceDigest()` method lets projectors
reuse the runtime's frozen source measurement. Its cache is excluded from
Codable, equality and hashing; decoded inputs do not acquire a trusted runtime
cache. There is no digest, Journal schema, Provider request or budget change.

Resolved read-only group projection now requires proof for all removed calls and
the resolving call. This stricter behavior can reject previously accepted Host
spans. `AgentContextReadOnlyGroupReferencing` is additive; wrappers must forward
its requirements. Existing source/Codable proof fields and schema 3/4/5 stay
unchanged. Reopened Sessions conservatively reject spans without live proof.

`JournalWriterLockWait` and an explicit-wait `openAsync` overload are additive.
The original overload (including function-reference signature) and fail-fast
default remain. Waiting changes no schema 3/4/5, mutation identity or recovery
rule. The new C POSIX helper target is test-process support only, not a library
executor or production lock implementation.

## Provider context overflow (unreleased)

`ModelProviderError.Kind` adds `contextWindowExceeded` (Codable raw value
`"contextWindowExceeded"`). It is a source break for exhaustive switches over
the kind; older decoders of an encoded `Kind` reject the new value. Behavior
changes for the same wire input:

- OpenAI `context_length_exceeded` was `invalidRequest` (HTTP 400) or
  `invalidResponse` (stream); it is now `contextWindowExceeded`.
- LM Studio's overflow was `unavailable` (HTTP 500, retried and eligible for
  fallback by `ModelProviderRoute`) or `invalidResponse` (stream); it is now
  `contextWindowExceeded`, which is never retried and never falls back.
- llama.cpp server `exceed_context_size_error` and Anthropic "prompt is too
  long" were `invalidRequest`; they are now `contextWindowExceeded`.
- Responses stream `error` events with the nested `error` object were always
  `invalidResponse`; they are now classified by their code like the flat shape.
- On HTTP 400 and 500, OpenAI, Local Responses and Anthropic adapters read up
  to 64 KiB of the error body before failing. Other statuses still fail on the
  header. DeepSeek is unchanged.

No message carries the provider's text. See
[Provider context overflow](swift-agent-errors.md#provider-context-overflow).

## Confirmed no-effect on main (unreleased)

ADR 0010 adds explicit mutation-only `.confirmedNoEffect`,
bounded executor-context confirmation and Host queries, `AgentFailure.noEffect`
and `AgentSessionError.confirmedNoEffectJournalRequired` enum cases. Exhaustive
switches/new policy Codable values require source consideration. Ordinary
creation still uses schema 3; rejection 4; audit 5. Explicit confirmation-capable
creation now selects schema 7/proof v2, rejected by the actual pre-fix schema-6
reader. Existing schema 6 stays v1 and rejects unrepresentable new calls before
executor entry; new readers preserve valid v1 data. ToolNoEffectProof
canonicalArguments/receipt are optional for compact v2; argumentBinding,
originalArgumentsUTF8Bytes and receiptSummary explicitly bind the original intent. No automatic migration or
new ledger for existing operations. See [contract, limits and format](swift-agent-confirmed-no-effect.md).
PR #62 implemented this capability on main; RC6 remains unreleased. Storage
audit capability does not enable the Host-configured `requiredAudit` mode.

## Durable Run association and logical terminal (unreleased, Issue #75)

`AgentRunCorrelation` supplies a Host correlation key and declared payload
identity to `session.run(..., correlation:)`. Run IDs are generated by the SDK;
a key never supplies or restores a Run ID. Duplicate committed submissions
throw `alreadyAdmitted(originalRecord)`; changed formal text, operation mode/ID
or declared digest conflicts. The SDK fingerprints exact input independently
of the supplied digest. Rebuilt runtime binding handles do not change this
stable payload identity. Uncommitted overlapping startup returns
`admissionInProgress`, without claiming a committed admission.

Explicit `supportsRunRecords: true` creation selects schema 9, including schema
8 capabilities. All actual Runs, including follow-ups without a key, publish
an admission with their formal user message in the existing transaction. The
actual owner publishes `AgentRunTerminal` with its final canonical checkpoint
only after started writes and retained steering resolve. Persistence failure
is visible through the Run result; poisoned/unknown storage receives no blind
retry. Terminals distinguish completed, refused, incomplete, cancelled and
failed using bounded sanitized enums. A cancelled waiter does not cancel the
Run. Logical terminal neither promises drain nor authorizes recovery/replay.

Session and Journal `runRecord` queries by key or Run ID distinguish not
admitted, admitted without terminal, terminal, and a throwing unavailable
store. Indexed/witnessed associations and terminals survive maintenance for
the whole store lifetime. Schema 3–8 and memory-only Journals explicitly lack
this capability; missing published indexes are errors. No migration, reset,
second ledger or old-Run guess is provided. Actual schema-8 binaries reject
schema 9 before append/maintenance, including an empty schema-9 store. See
[ADR 0014](../adr/0014-durable-run-association.md) and the public offline
`RunRecordFixture`. Exhaustive switches over `AgentJournalEvent` must handle
`runTerminated`; added API parameters also change stored function signatures.
