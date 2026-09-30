# Changelog

All notable changes to SwiftAgent are recorded here.

## [Unreleased]

Changes after the RC5 candidate are not part of `1.0.0-rc.5`.

- Bound early CI build/test stages and retain per-attempt process/source evidence.
  Add a five-attempt Linux reporting reproduction experiment that stops on failure;
  historical #45/#46 hang/segfault root causes remain unestablished.
  Sample the current owned ancestry (root and at most two active descendants),
  with shared-budget identity checks and explicit unavailable/failure outcomes;
  do not select a stale historical PID or infer depth from PID size.
- Memory Journal keeps one full checkpoint per Session instead of all historical
  versions. Complete canonical history, steering IDs, sequences and Run identity
  queries are preserved. Identity-only metadata still grows with Sessions/Runs;
  memory mode gains no mutation/audit capability. Durable formats are unchanged.
- Projection source revision follows the actual committed Session snapshot after
  multiple tool-result commits; candidate preflight and the distinct Run source
  epoch are documented. Stale/wrong source plans still fail; Codable fields and
  digest format stay unchanged. Session `history` remains a loaded view; durable
  resume examples use the existing throwing `conversationSnapshot()`.

- Reuse the frozen Context source digest and identity-view size without retaining
  encoded buffers. Changed projections are measured independently; external
  source claims remain verified. The additive input `sourceDigest()` API keeps
  the existing Codable and digest format.

- Validate the whole replaced read-only failure group with committed execution
  provenance. Mixed mutation groups and missing/reopened proof are rejected;
  request views change without modifying canonical history or settlement.
- Parse Retry-After HTTP dates with controlled UTC semantics and preserve retry
  limits. DeepSeek diagnostic origin no longer depends on error message prose.
  Document/test inclusive message and exclusive follow-up pagination.
  This addresses selected #44 items, not the entire collection issue.

### Fixed: audit boundary closeout

- Preserve original and failure-audit errors while still attempting mutation
  quarantine. `AgentAuditPersistenceError` maps to the new source-breaking
  `AgentFailure.auditPersistence` case; a failed quarantine remains separate.
- Close prepared but unstarted sibling calls with known nonexecution facts and
  classify safe audit failure reasons from actual runtime/tool/executor stages.
- Clarify standard export as a conservative summary and demonstrate trusted
  Host-selected subject/policy/time archival without changing SDK export ACKs.

### Added: Audited Authorization (RC6 candidate)

- Host-owned structured decisions bind runtime-prepared exact tool actions.
  `AgentConfiguration.authorization` defaults to legacy; `requiredAudit` needs
  schema-5 durable storage, authorizer and identity before input/provider work.
  Read-only, mutation, dynamic and `.notRequired` tools all use the Host decision;
  required tool-domain checks remain additional. Archived decisions cannot
  restore live permission; changed inputs/versions, cancellation, generation
  and expiry are enforced in the existing admission path.
- Typed proposal, authorization, disposition and result-reference facts share
  the Journal transaction domain. Application/intent and settlement/reference
  publish atomically, without changing audit-only conversation revision.
  Explicit schema-5 creation includes rejection support; schema 3/4 remain
  unchanged and are not migrated. RC5 readers reject schema 5.
- Bounded throwing Host queries, conservative export views and explicitly
  started `AuditExportSink` delivery provide at-least-once archive delivery with
  durable prefix ACKs and receiver deduplication. Export failure never retries
  business execution; optional backlog pressure preserves in-flight settlement.
- Public `EnterpriseAuthorizationFixture`, process/fault/reader compatibility
  regressions and a storage-cost benchmark qualify the closed loop. Host
  identity/policy, immutable backend operations, archive authentication and
  viewing isolation remain Host responsibilities. Provider egress, IAM and
  distributed remote/local transactions are outside scope. See
  [the guide](docs/guides/swift-agent-authorization-audit.md).
- Source compatibility: `AgentFailure.authorization` requires exhaustive
  switches to change. `AgentTool.authorizationBinding(for:)` has a default;
  existing same-signature conformer members must satisfy the public requirement.
  Batch encoding metrics are additive. RC5 history is unchanged.

## [1.0.0-rc.5] - 2026-09-29

RC5 is an SDK prerelease, not a stable 1.0 release or production Host
approval. See [RC5 release notes](docs/releases/1.0.0-rc.5.md).

### Added: bounded pre-admission replanning (opt-in)

- `AgentConfiguration.preAdmissionReplanning` defaults to `.disabled`.
  `.evidenceRejection(toolNames:)` lets named mutation tools receive one
  correlated error result when the runtime's first Evidence check rejects a
  single prepared call before authorization, durable intent or admission. The
  correction continues in the original Run with its remaining turn, tool-call
  and deadline budgets; no second Run starts. The denial is recorded as a
  typed Journal fact, not as a Receipt, Evidence, authorization or execution.
  See [ADR 0008](docs/adr/0008-bounded-pre-admission-replanning.md).
- An opt-in Run needs a store created with
  `AgentIncrementalJournal.create(..., supportsAdmissionRejections: true)`,
  which is format schema 4. Default creation stays schema 3.

### Added: tools defined at runtime

- `AgentTool` gains `definition`, defaulting to the type's static name,
  description and schemas. New `RuntimeAgentTool` (JSON input and output)
  supplies `runtimeDefinition`, so one type can serve tools named at runtime,
  such as a Host's app connectors or an external server's tools. Registration,
  schema validation, capability bindings and mutation admission use the
  instance definition, read once at registration. A capability binding keeps
  the definition it read when it was created. A name from the instance must
  be 1 to 64 letters, digits, `_` or `-`. Existing tools keep their behavior.

### Fixed

- The Journal store's writer lock descriptor is opened close-on-exec. A child
  process the Host started with `posix_spawn` or fork/exec while the store was
  open inherited the lock and kept a closed store locked (`storeInUse`) until
  that child exited. Foundation's `Process` was not affected.
- `ModelProviderRoute` no longer forwards one candidate's opaque continuation
  state (such as encrypted reasoning) to another candidate on fallback. State
  is recorded with its producing candidate and returned only to it; if that
  candidate fails or is unknown, the request fails with `fallbackBlocked`
  before any other candidate is contacted. New `ModelProviderRoute.Candidate`
  declares stable candidate IDs that survive restarts and reordering.
- Corrections accepted by `run.steer` but not delivered before a Run is cancelled
  or fails are committed to the Journal with their IDs before the Run ends. They
  were kept only in Session memory and lost on reopen. A failed commit is
  reported by the Run; after `commitUnknown` the Session refuses history reads
  and new Runs until reopen, and after a definite failure the corrections join
  the next Run's input.
- Once `AgentJournal.close()` starts, follow-up enqueue and withdrawal fail with
  `storeClosed`, like other new work. They were accepted while close waited
  for maintenance.
- A segment rotation whose `CURRENT` replacement is uncertain poisons the Journal
  handle, so later reads, writes and maintenance report `commitUnknown`. They
  reported `concurrentWriter` although no other writer existed. The batch that
  triggered the rotation stays committed.
- A rotation that keeps failing no longer grows the active segment past
  `maxWorkBytes`, which sealed a segment maintenance could never read. New Run
  input, mutation admission and follow-up enqueue fail with
  `maintenanceRequired`, admitted work settles within the remaining room, and
  maintenance retries the rotation.
- Opening a store with a `maxWorkBytes` smaller than its retained segments or
  packs fails with `maintenanceBudgetTooSmall(requiredWorkBytes:)` instead of
  opening and then failing every maintenance pass.
- Schema-4 stores read the `pending-operations` index as the Session set it
  stores. Maintenance previously decoded it as a batch sequence, so packing a
  sealed mutation batch and index cleanup failed on every pass, until mutation
  admission stopped with `maintenanceRequired`. The index pins no batch.
- A checkpoint whose append returns after the Run's deadline or cancellation is
  adopted by the Session. The Session previously kept its older history, so its
  next Run failed with `concurrentWriter` until reopen. Finishing a Run waits for
  its in-flight Journal write; a draining Run's mutation settlement is adopted.
- `JournalMaintenancePolicy` rejects a work budget smaller than the largest
  segment rotation can seal, which previously stalled maintenance.
- `AgentIncrementalJournal.create` succeeds under a parent directory reached
  through a symlink. It previously failed after writing a complete store.
  Managed paths inside the store still refuse symlinks.

### Breaking

- A store created with `supportsAdmissionRejections: true` is schema 4 from
  creation, and the RC4 reader rejects it at open. Default stores stay schema 3
  and remain readable, appendable and maintainable by RC4. The RC5 reader opens
  RC4 schema-3 stores; an opt-in Run on one fails before the Provider request.
  No store is migrated, upgraded or downgraded, and a new store does not
  inherit an old store's operation-deduplication facts.
- `AgentEvent` and `AgentJournalEvent` add `toolAdmissionRejected`;
  `AgentSessionError` adds `admissionRejectionJournalRequired`. Exhaustive
  switches must add them even while replanning is disabled.
- `ModelProviderFallbackPolicyError` adds `invalidCandidateIdentity`, thrown by
  `ModelProviderRoute.init` for an invalid or duplicate candidate ID. A Route
  refuses continuation state it cannot attribute to a current candidate with
  `fallbackBlocked`. This includes state saved by RC4 through a Route and
  state from candidates without declared IDs after the Route is re-created.
- A cancelled or failed Run whose retained steering cannot be committed reports
  that Journal error from `wait()` and its terminal event.
- `AgentJournalError` adds `maintenanceBudgetTooSmall(requiredWorkBytes:)`.
  `JournalMaintenancePolicy` throws for a work budget below the largest segment
  rotation can seal, and a failed rotation now applies `maintenanceRequired`
  backpressure to new Run input, mutation admission and follow-up enqueue.
- `AgentFailure` adds `modelBinding`, `capability`, `contextPipeline` and
  `contextProjection` for Core errors that were reported as `unclassified`.

### Tests and CI

- `FollowUpProcessTests` bounds every child wait and fails with the child's
  state instead of hanging. `Scripts/ci-execution-reporting.sh` keeps per-case
  logs, bounds each case and collects stack or crash evidence; CI uploads them.
- New regressions cover writer-lock inheritance by spawned children and make
  the rotation backpressure test independent of automatic maintenance timing.

### Known issues

- Unattributed CI flakes: hosted macOS 30-minute timeouts
  ([#45](https://github.com/OtohaCo/SwiftAgent/issues/45)) and one Linux
  segfault ([#46](https://github.com/OtohaCo/SwiftAgent/issues/46)).
- Reopening right after `close()` while the process spawns a child can briefly
  get `storeInUse` ([#47](https://github.com/OtohaCo/SwiftAgent/issues/47)).
- Tracked design and performance items: #39 to #44. The live real-model
  replanning evaluation was not run.

## [1.0.0-rc.4] - 2026-09-28

RC4 is a breaking SDK prerelease, not a stable 1.0 release or production Host
cutover. See [RC4 release notes](docs/releases/1.0.0-rc.4.md).

### Breaking: RC4 durable follow-up queue

- Add explicit per-Session FIFO `enqueueFollowUp`, paginated status and
  withdrawal; same-ID retries keep one ordinal, while changed payloads
  conflict. Dispatcher startup is Host-owned and disabled on reopen. It uses
  current model/capability bindings, the existing Run admission, and one
  atomic queue/Run/formal-input Journal publication. Pause, stop, current-Run
  cancellation and actual drain remain separate operations.
- New stores write format schema 3 with the bounded `BatchV2` payload and
  committed index witnesses. Schema-1 and unreleased schema-2 stores are
  rejected unchanged; no implicit migration or memory
  fallback is supplied. Formal messages, mutation identity, trusted receipts
  and reconciliation remain in their existing execution paths. Terminal
  input identities remain indexed without TTL. The queue does not retry an
  interrupted admitted Run on process reopen.
- Review fixes keep inspection publication owned through stop/drain, require an
  actual interrupted admission before inspection release, and pause dispatch
  after an abnormal pre-existing direct Run. `startFollowUpDispatch(onRun:)`
  delivers admitted Runs to the Host's single event observer; headless dispatch
  discards bounded progress without affecting trusted settlement.
- Close a poisoned store after actual drain without resolving its unknown
  commit. A withdrawn head may advance only when its typed, scoped
  pre-admission result and cleanup are confirmed. Missing published Session,
  queue or operation indexes now fail closed rather than looking empty; the
  per-key witness and stable position commit identity are the reason for the
  schema-3 boundary.

### RC4 scoped capabilities

- Add Session-created, Run-bound tool/backend/resource snapshots with one
  actor-linearized whole-scope revocation and separate physical drain wait.
  Dynamic mutation tools recheck the durable Journal prerequisite before
  input admission. Version changes affect later Runs; the Journal format,
  operation identity, Receipt settlement and shared resource scheduler remain.
- Add a credential-free ExternalClient example for isolated Session tool sets,
  resource refusal, revocation and cross-restart mutation no-replay. A scope
  diagnostic cannot be decoded into an execution credential.
- Propagate scope revocation to cooperative startup projection and estimation;
  retain leases for noncooperative work through physical exit. Scope drain now
  includes the bound Run's Journal/Session cleanup. Reject out-of-scope typed
  resources before scheduler dispatch as well as at final execution admission.

### RC4 context pipeline

- Add source-scoped, deterministically ordered Host materials and Journal-ID-bound
  request summaries. Closed historical text groups can be summarized without
  changing formal conversation; successful read-only tool results can be
  excerpted while preserving the complete Journal result and call pairing.
- Apply the existing per-request byte and token checks to the assembled request,
  and expose a bounded report with redacted source decisions and estimates.
  The credential-free ExternalClient fixture covers two Sessions and recovery.
- Add public `AgentSession.contextHistorySpan`, `contextToolExcerpt`,
  `AgentCompositeContextProjector`, material/summary/excerpt types and an
  optional `AgentModelBinding.contextReports` buffer. No Journal format or
  mutation execution contract changes.
- Review hardening lets forwarding projectors declare indexed source needs,
  ties read-only excerpts to committed same-Session effect evidence instead of
  current tool names, requires complete text groups for summaries, reserves
  material bytes for required sources and binds reports to all derived inputs.
  Old read-only results without process-local effect proof fail closed after
  restart; the Journal disk format is unchanged.

### Breaking: Journal storage

- Replace the framed single-file durable Journal with the optional
  `AgentJournalFileStore` segmented local store. Explicit `create`/`open` and
  a store-lifetime OS writer lock separate Session identity from the shared
  operation domain. Old files are rejected without overwrite or migration.
- Commit only new formal messages and mutation changes. A trusted receipt,
  replay output and conversation result publish atomically. Indexed recovery
  reads one Session without replaying other Sessions' terminal lifecycles.
  Automatic bounded maintenance packs sealed segments and safely reclaims
  obsolete managed files, while preserving formal messages and terminal
  identity facts.
- Remove old file constructors, manual compaction, memory-to-file `persist`,
  full-record snapshot diagnostics and the lossy canonical-history compactor.
  Recovery queries and conversation snapshots now throw on storage errors;
  paginated formal message and indexed mutation queries replace full snapshots.
  Abort requires a trusted `AgentNoEffectConfirmation` and reconciliation
  requires replay output. Context limits apply to the projected model request
  without rewriting formal history.
- Review hardening binds the stored domain to the published root, rejects
  symlinked managed paths and oversized corrupt frame lengths, preserves paired
  assistant calls when a tool batch extends its committed tail, and reclaims
  superseded lifecycle blobs and obsolete state packs after safe maintenance
  publication.

## [1.0.0-rc.3] - 2026-09-21

This is a focused compatibility hotfix from the immutable RC2 anchor.

### Providers

- Fix Anthropic Models API capability-object decoding for effort levels and
  `thinking.types`, while preserving the existing string-array fixtures.
- Keep model catalog metadata fail-closed: only nested values with an explicit
  `supported: true` are published, and missing or incomplete metadata remains
  `unknown`.
- Preserve the distinction between discovery and adapter executability. New
  Anthropic effort raw values remain executable through the existing
  `output_config.effort` parameter; unknown thinking modes require an adapter
  upgrade.

### Compatibility

- No AgentCore execution contract, Journal schema, mutation safety, provider
  continuation boundary, Provider, routing architecture, or public API removal
  changes are included.
- The immutable `1.0.0-rc.1` and `1.0.0-rc.2` tags remain unchanged.

### Host integration

- Add a reusable example-side execution report reducer that keeps Runtime
  termination, observed tool facts, Host-owned fulfillment, and presentation
  separate across failure, cancellation, malformed replies, and physical drain.
- Preserve durable mutation facts through a failed final model response and a
  Journal-backed replay with a new tool call ID, without re-entering the
  executor or counting a replay completion as executor entry.
- Bind reports to the actual Run session identity, reject unbound event bodies,
  and isolate mismatched lifecycle headers before they can contaminate a report.
- Add runnable AppleChatApp and headless Host examples covering committed
  mutation recovery, pre-execution read-only rejection, bounded diagnostics,
  and zero-request deterministic fixtures.

## [1.0.0-rc.2] - 2026-09-21

The RC2 release candidate adds the reliability, provider, catalog, decision,
usage, and example work described below. Qualification remains scoped to the
recorded provider matrices; it is not a claim for every model or deployment.

### Reliability

- Sync the journal parent directory when publishing a new durable file, and
  conservatively adopt a frame that was written before directory sync failed.
- Validate Anthropic response model identity, with an explicit mapping for
  legacy aliases that resolve to dated model IDs.
- Reject illegal or contradictory OpenAI and DeepSeek output-item terminal
  states before AgentCore can dispatch a tool, while preserving legal
  incomplete output as non-executable partial state.
- Bind OpenAI and DeepSeek continuations to ordered canonical visible content,
  including legal cross-item stream interleaving, tool-call order, and native
  function identities; reject reordered or rewritten replay state while
  retaining readability of older opaque payloads.
- Fence provider-route candidate callbacks by Run generation so a response that
  finishes after clear/cancel cannot restore stale pinning.
- Preserve visible DeepSeek incomplete-turn history without requiring discarded
  tool/reasoning continuation state on the next Run; incomplete tool proposals
  remain non-executable.
- Accept DeepSeek `response.output_item.done` frames whose item is explicitly
  incomplete before the `response.incomplete` terminal, without dispatching
  partial function calls.
- Accept a DeepSeek text-only terminal response after a completed Host tool
  result while still requiring replayable reasoning on turns that emit tools.
- Use the public `SUB2API_*` namespace for opt-in gateway qualification and
  require an explicit gateway endpoint instead of falling back to OpenAI.
- Add deterministic ownership tests proving a timed-out compactor cannot
  overwrite a newer memory or durable checkpoint and terminal completion waits
  for a reserved mutation commit.
- Capture an immutable provider/model binding per Run, with preflight revision
  checks and provider-continuation origin validation across Session restarts.
- Add request-only context projection and explicit resolved read-only tool-span
  denoising without replacing canonical history or trusted runtime state.

### Providers

- Add `LocalResponsesProvider` for explicitly configured local or self-hosted
  OpenAI-compatible Responses endpoints. It replays canonical SwiftAgent
  history on every turn, never depends on `previous_response_id` or OpenAI
  encrypted continuation state, keeps tools Host-executed, and makes tool and
  structured-output capabilities explicit per configured model.
- Add an explicit Apple Private Cloud Compute backend for macOS and iOS 27,
  while keeping SwiftAgent Core as the sole tool execution authority.
- Add an OpenAI Responses API adapter with typed SSE streaming, host-executed
  function calls, structured output, encrypted reasoning continuation,
  normalized usage, explicit model-alias identity, classified stream failures,
  and stateless canonical conversation replay.
- Add an independent DeepSeek Responses API adapter with typed SSE streaming,
  host-executed function calls, structured output, plaintext reasoning replay,
  usage normalization, explicit model-alias identity, and fail-closed terminal
  validation. DeepSeek live-cloud qualification is not claimed in this entry.
- Make DeepSeek reasoning effort an extensible validated raw-value type so new
  provider effort values do not require expanding a closed public enum.
- Add the optional `AgentCatalog` product and documented OpenAI, Anthropic, and
  DeepSeek model discovery clients with tri-state capabilities, provenance,
  bounded pagination, and last-known-good caching.

### Decisions

- Add the Linux-portable `AgentDecisions` product with typed Noul, Choice, and
  Score requests, responses, usage, deadlines, and an extensible error taxonomy.
- Add `AgentJevProvider` for the verified TypeSafe Jev System One HTTP contract,
  including strict response identity/range validation, classified sanitized
  failures, retry metadata without hidden retries, and cancellation ownership.
- Keep decisions outside AgentCore: they cannot create Evidence, authorize or
  execute tools, create Receipts, or settle journals.
- Add a fixture-first `DynamicModelRouting` Host example that lets Jev choose
  only from legal candidates after deterministic capability, privacy, revision,
  cooldown, and cache-aware cost checks.

### Usage accounting

- Add the optional `AgentUsage` product for response, Run, Session-window, and
  provider/model aggregation without adding a dependency to AgentCore.
- Preserve per-field reported and missing counts, distinguish explicit zero
  from unreported values, and keep finalized and provisional totals separate.
- Make duplicate observations idempotent and reject conflicts, regressions,
  invalid subsets, negative values, and checked-arithmetic overflow without
  changing the underlying Run or mutation result.
- Correct ProviderQualification to count every visible response in multi-turn,
  tool, restart, failure, and cancellation paths; AppleChatApp now displays
  response, Run, and Session-window usage with cost explicitly unestimated.

### Release scope

- OpenAI official and DeepSeek official live evidence is limited to the recorded
  qualification matrices; Anthropic is limited to the configured gateway/service
  matrix and Jev to typed Decision qualification.
- Apple on-device live evidence is limited to the recorded opt-in cases.
- Apple Private Cloud Compute is experimental and not live-qualified for the
  full SwiftAgent Core tool loop or durable restart in RC2.
- Downstream Tingting/Otoha app CI, media closed-loop assertions, and live UI
  qualification are outside the SwiftAgent RC2 release gate.

## [1.0.0-rc.1] - 2026-09-19

### Runtime

- Provider-neutral Agent, Session, Run, event, budget, cancellation, steering,
  logical completion, and physical drain contracts.
- Multi-Run conversation continuity with explicit, fail-closed context policy.

### Tools

- Typed AgentTool inputs and outputs, schema validation, authorization,
  Evidence requirements, resource isolation, receipts, and deterministic ordering.
- Explicit recoverable read-only tool failures without weakening safety errors.

### Providers

- Anthropic streaming, signed continuations, structured tool calls, SSE validation,
  classified retry, and provider-route fallback.
- Optional Apple Foundation Models adapter with fixture-based CI coverage.

### Durability

- Versioned AgentJournal records, checksums, crash-tail recovery, atomic compaction,
  stale-writer detection, Session leases, and durable conversation checkpoints.

### Mutation Safety

- Durable intent before execution, validated Receipt before success, conservative
  reconciliation, and stable settled-result reuse across Runs, Sessions, restart,
  provider fallback, and journal compaction without executor re-execution.

### Concurrency

- Swift 6 actor isolation, cancellation-safe waiters, physical drain ownership,
  resource coordination, and deterministic regression coverage.

### Platforms

- Core products for macOS 13+, iOS 16+, and Linux, validated with Swift 6.4.
- Optional Apple Foundation Models adapter for macOS/iOS 26+.
