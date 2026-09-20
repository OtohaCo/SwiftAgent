# Changelog

All notable changes to SwiftAgent are recorded here.

## [Unreleased]

Development after `1.0.0-rc.1` targets the next release candidate. Public API
additions and behavior changes will be recorded here before that release is cut.

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
