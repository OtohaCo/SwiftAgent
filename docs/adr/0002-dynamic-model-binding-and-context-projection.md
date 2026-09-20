# ADR 0002: Dynamic Model Binding, Catalog Discovery, and Context Projection

Status: Accepted for RC.2 development
Date: 2026-09-20
Scope: `AgentCatalog`, `AgentCore`, provider adapters, and Host examples

## Context

SwiftAgent currently binds one immutable `ModelID` and `ModelProvider` to an
`AgentLoop`. That is safe within a Run, but a long-lived `AgentSession` cannot
select another model or reasoning configuration without constructing another
Agent and Session. The existing `ModelCapabilities` bit set describes a
configured adapter; it cannot distinguish an upstream omission from explicit
unsupported capability metadata.

Provider continuations are canonical-history attachments interpreted only by
their owning adapter. A model name alone is not enough to prove that opaque
state can be replayed against another endpoint or configuration. Existing
Journal compaction also serves recovery, not permanent raw-transcript audit.

Official contracts checked on 2026-09-20:

- OpenAI `GET /v1/models` returns basic model identity/ownership metadata; it
  does not provide a complete execution-capability matrix.
- Anthropic `GET /v1/models` is cursor-paginated and may return nullable model
  capabilities, context limits, effort values, and thinking modes.
- Anthropic effort is encoded as `output_config.effort`; effort, thinking mode,
  and thinking token budget remain separate controls.
- DeepSeek `GET /models` returns basic model identity/ownership metadata.
- DeepSeek thinking with tools requires replay of the original reasoning
  content on subsequent requests.

Sources:

- https://developers.openai.com/api/reference/resources/models/methods/list
- https://platform.claude.com/docs/en/api/models/list
- https://platform.claude.com/docs/en/build-with-claude/effort
- https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- https://api-docs.deepseek.com/api/list-models/
- https://api-docs.deepseek.com/guides/thinking_mode/

## Decision

1. Add an optional `AgentCatalog` product that depends only on `AgentModels`.
   It owns open model descriptions, explicit `supported` / `unsupported` /
   `unknown` capability states, reasoning-control descriptions, discovery
   protocols, manifests, and a bounded TTL/last-known-good cache.
2. Keep provider-specific HTTP clients in `AgentProviders`. OpenAI, Anthropic,
   and DeepSeek use their own documented response shapes and controlled catalog
   endpoints. Discovery is never a prerequisite for an explicitly configured
   model Run.
3. Add an immutable `AgentModelBinding` in `AgentCore`. An Agent keeps its
   existing default binding; `AgentSession.run(_:using:)` captures a selected
   binding for one Run. The captured loop remains the drain authority for that
   Run.
4. Add local preflight before a user turn is journaled. It checks provider/model
   identity, configured capabilities, opaque-continuation compatibility,
   provider request encoding when available, projection integrity, and an
   optional target-model token budget.
5. Add request-only context projection. Canonical Session history, Evidence,
   mutation state, receipts, checkpoints, and idempotency remain unchanged.
   The default projector is identity. Lossy handoff and resolved read-only tool
   compression are explicit Host choices and operate on complete interaction
   groups.
6. Bind newly emitted opaque continuation state to a non-secret execution
   target scope. Legacy continuation without scope remains accepted only by the
   legacy default Run path; explicit dynamic bindings are strict by default.
7. Keep automatic routing in Host/example code. TypeSafe/Jev may choose only
   from finite executable candidate IDs. Deterministic Host policy applies
   privacy, capability, compatibility, cache, cost, cooldown, and fallback
   rules before starting a Run.

## Compatibility

- Existing `Agent`, `AgentSession.run`, provider initializers, `ModelUsage`, and
  Journal records keep their current behavior.
- No Journal schema migration is introduced. Optional continuation scope uses
  backward-compatible decoding; missing scope is treated conservatively by the
  new strict binding path.
- `ModelCapabilities` remains the configured adapter contract. Catalog metadata
  uses separate tri-state values and does not reinterpret existing bits.
- Provider-native append-only configuration updates are not implemented in the
  first slice. Request-level configuration changes are correct but cache impact
  may be unknown.

## Consequences

- A Session can safely select a different immutable provider/model profile for
  the next Run without rebuilding trusted Session state.
- Discovery data can remain partial or stale without becoming execution truth.
- Projection can reduce model-visible context without erasing canonical facts
  or minting Evidence.
- Hosts remain responsible for catalog manifests, pricing, privacy policy,
  routing evaluation data, and any permanent raw-transcript archive.
