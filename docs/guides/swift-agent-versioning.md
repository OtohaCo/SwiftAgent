# SwiftAgent Semantic Versioning

last-verified: 2026-09-20

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

## 1.0 freeze decisions (SAI-026B)

These source breaks happen before the first tagged 1.0:

- Mutation Sessions require `journal.storage == .durable`. `AgentJournal()` is
  not durable. `persist(to:)` can upgrade a memory journal before `makeSession`.
  `.durable` is configured persistence mode, not a guarantee that every later
  write succeeds.
- `Agent(model:provider:tools:configuration:)` is the advanced constructor.
  The only extra convenience is `instructions:`. Do not reintroduce a parallel
  list of limit parameters on `Agent`.
- `AnyAgentTool`, `ToolRegistry`, and `PreparedToolCall` are package-only.
  `ToolRegistryError` remains public.

## Non-breaking

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

The current SAI-071 RC.2 working graph contains 1,316 precise public identifiers
and 138 top-level public types. It adds 360 identifiers and removes none relative
to `1.0.0-rc.1`. The latest 21 identifiers add the optional
`LocalResponsesProvider` surface in `AgentProviders`; the prior 139 add the
optional `AgentUsage` product. These additions are source-compatible for clients
that do not adopt the new providers, decision products, or usage accounting.

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
