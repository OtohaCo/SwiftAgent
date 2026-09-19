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

### Providers

- Add an explicit Apple Private Cloud Compute backend for macOS and iOS 27,
  while keeping SwiftAgent Core as the sole tool execution authority.

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
