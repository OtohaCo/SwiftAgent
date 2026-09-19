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
  tool-call order, and native function identities; reject reordered or
  rewritten replay state.
- Fence provider-route candidate callbacks by Run generation so a response that
  finishes after clear/cancel cannot restore stale pinning.
- Add deterministic ownership tests proving a timed-out compactor cannot
  overwrite a newer memory or durable checkpoint and terminal completion waits
  for a reserved mutation commit.

### Providers

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
