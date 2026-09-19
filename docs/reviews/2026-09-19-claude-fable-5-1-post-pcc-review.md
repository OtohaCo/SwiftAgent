# Claude Fable 5.1 Post-PCC Independent Review

> last-verified: 2026-09-19

## Metadata

- Repository: `OtohaPlayer/SwiftAgent`
- Reviewed SHA: `a66c19f45e4c394002ada1c88bcf5ce2f1b7d712`
- Model: Claude Fable 5.1
- Invocation: Herdr workspace Panel 2
- Prompt: [claude-fable-5-1-post-pcc-review.md](prompts/claude-fable-5-1-post-pcc-review.md)
- Result: P0 0, P1 0, P2 3, P3 5, architecture suggestions 2

The reviewer independently built the package, ran the full macOS package
suite, built the iOS 16 triple, and ran ExternalClient 6/6 from an isolated
copy. Live providers and Linux were outside that review invocation.

## Findings And Codex Disposition

### P2: Providers have no typed context-window overflow signal

**Accepted as separate pre-1.0 API work.** Provider HTTP 400 failures currently
collapse context overflow into `.invalidRequest`, while the local context bound
is byte-based. Adding a provider-neutral error kind and defining whether Core
may compact and retry changes public error and runtime policy contracts. It is
not folded into SAI-054.

### P2: Model alias diagnostics and policy are vendor-specific

**Partially accepted.** Exact response identity remains the fail-closed default.
SAI-054 gives OpenAI the same explicit alias-to-snapshot configuration as
Anthropic and returns sanitized expected/observed names. A shared public
`ModelIdentityPolicy` remains a separate API-design decision rather than a
prerequisite for the adapter.

### P2: Journal cost grows with retained terminal identities

**Accepted, post-RC.** This is the existing correctness-first retention tradeoff
owned by the tombstone-retention backlog. Provider work does not weaken or
silently prune mutation identity.

### P3 findings

The review recorded an unbounded `Retry-After` sleep, unknown Anthropic events
after terminal, replay Evidence limitations, different cancellation behavior
between the two drain entry points, and discarded non-200 vendor bodies.
These are retained as non-blocking follow-up evidence and are not mixed into
the OpenAI adapter implementation.

### Architecture suggestions

Apple on-device/PCC routing needs an explicit model-selection contract before
being presented as automatic fallback. Public exhaustive enums also require a
documented evolution policy before stable 1.0. Both are accepted as design
inputs, not implicit feature authorization.

## Verified Boundaries

- No P0 or P1 was found at the reviewed SHA.
- `AnthropicProvider` required no blocking change.
- Apple on-device and PCC sessions propose plans with no registered SwiftAgent
  tools; AgentCore remains the executor.
- Provider output cannot bypass schema validation, Evidence, authorization,
  durable mutation intent, Receipt validation, or journal settlement.
- The existing provider-neutral models can host OpenAI Responses without an
  AgentCore dependency on OpenAI, provided canonical conversation stays local,
  remote IDs remain opaque, and provider-hosted tools never become host tool
  proposals.
