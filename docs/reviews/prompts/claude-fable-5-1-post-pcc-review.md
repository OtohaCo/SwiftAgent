# Claude Fable 5.1 Post-PCC Review Prompt

> last-verified: 2026-09-19

## Metadata

- Repository: `OtohaPlayer/SwiftAgent`
- Reviewed SHA: `a66c19f45e4c394002ada1c88bcf5ce2f1b7d712`
- Branch: `plan/swift-agent-rc2`
- Model: Claude Fable 5.1
- Invocation: existing Herdr workspace Panel 2
- Mode: read-only full-repository review

## Prompt

Review the current public SwiftAgent repository as an independent Swift SDK
architect, Agent runtime reviewer, Swift concurrency reviewer, security
reviewer, provider-abstraction reviewer, and public API reviewer.

Read `Package.swift`, every module under `Sources`, tests, examples, the
security model, guides, reviews, and release documents. Verify AgentLoop and
AgentSession orchestration, cancellation and drain, Evidence separation,
mutation intent/Receipt/settlement, idempotency, journal compatibility and
growth, provider continuation, Anthropic correctness, Apple on-device and PCC
boundaries, public API stability, and the suitability of the current provider
abstraction for an OpenAI Responses adapter without Core changes.

Classify findings as P0, P1, P2, P3, architecture suggestion, or not an issue.
For each finding include a source location, impact, evidence or reasoning, and
a recommended fix. Explicitly answer what fails first in a months-long process,
which public APIs are most likely to be regretted after 1.0, whether
`AnthropicProvider` needs a change, and whether provider output can bypass
Evidence, authorization, mutation intent, Receipt, or journal settlement.

Do not modify the repository.
