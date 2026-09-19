# Claude Fable 5.1 Independent Review Prompt

Last verified: 2026-09-19

## Review metadata

- Model: Claude Fable 5.1
- Invocation: Herdr workspace Panel 2 delegated review
- Repository: `OtohaPlayer/SwiftAgent`
- Reviewed SHA: `d2347f11c6a78f421708e897dae42a51a98d37ea`
- Scope: full repository, not a diff
- Mode: read-only

## Prompt

Act as an independent Swift SDK architect, Agent runtime reviewer, Swift
concurrency reviewer, security reviewer, provider abstraction reviewer, and
public API reviewer.

Review:

- `Package.swift`
- `Sources/AgentModels`
- `Sources/AgentTools`
- `Sources/AgentCore`
- `Sources/AgentProviders`, including the existing `AnthropicProvider`
- `Sources/AgentAppleProvider`
- `Sources/WorkspaceAgent`
- `Tests`
- `Examples`
- `docs/security-model.md`
- `docs/guides`
- `docs/reviews`

Check the following contracts:

1. `AgentLoop` remains the single orchestration authority across tool turns,
   terminal states, provider fallback, steering, cancellation, deadlines, and
   physical drain.
2. `AgentSession` keeps conversation state, run state, restart behavior,
   `wait()`, and `waitForDrain()` coherent.
3. Swift 6 concurrency boundaries are sound: `Sendable`, actors, task lifetime,
   parallel tools, continuations, and cancellation cannot race into duplicate
   completion or leaked work.
4. Conversation content is not Evidence, and provider/model output cannot mint
   Evidence.
5. Mutation execution preserves authorization, durable intent, one executor
   entry, Receipt validation, durable settlement, reconciliation, and the rule
   that uncertain mutations are never automatically replayed.
6. Stable idempotency remains correct across operation IDs, canonical semantic
   arguments, tool identity, journal identity, settled replay, pending state,
   restart, and compaction.
7. Journal v1/v2/v3 recovery, corrupt and truncated tails, compaction,
   concurrent writers, stale writers, and retained mutation identities remain
   safe.
8. `ModelProvider`, `ModelRequest`, `ModelEvent`, capabilities, usage, and opaque
   continuation abstractions can support Anthropic, OpenAI Responses, Apple
   on-device models, and Apple Private Cloud Compute without leaking vendor
   semantics into `AgentCore`.
9. `AnthropicProvider` correctly handles request encoding, SSE framing and
   terminal validation, tool calls, structured output, thinking continuation,
   usage, sanitized errors, cancellation, and physical drain. Do not propose a
   separate Claude or Fable provider.
10. `AppleFoundationProvider` only proposes a plan. It must not register or
    execute SwiftAgent tools inside `LanguageModelSession`.
11. Public APIs should be evaluated for accidental exposure, likely post-1.0
    regret, source compatibility, and missing abstraction.

Classify every item as one of:

- P0
- P1
- P2
- P3
- Architecture suggestion
- Not an issue

For each finding provide:

- source location
- problem
- impact and reasoning or reproduction
- recommended fix

Explicitly answer:

- Does `AnthropicProvider` require a code change?
- If this SDK runs for months in production, what fails first?
- Which public APIs are most likely to be regretted after 1.0?
- Can provider output bypass Evidence, authorization, mutation intent, Receipt,
  or Journal settlement?

Do not modify repository files. Return a structured Markdown review.

## Execution record

The authoritative review was returned by the existing Herdr workspace Panel 2.
Two earlier delegated attempts produced no review output because one remote
context compaction and one response transport failed; neither is treated as a
completed review.
