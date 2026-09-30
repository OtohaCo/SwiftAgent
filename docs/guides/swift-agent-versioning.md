# SwiftAgent Semantic Versioning

last-verified: 2026-09-29

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

`JournalWriterLockWait` and an explicit-wait `openAsync` overload are additive.
The original overload (including function-reference signature) and fail-fast
default remain. Waiting changes no schema 3/4/5, mutation identity or recovery
rule. The new C POSIX helper target is test-process support only, not a library
executor or production lock implementation.
