# SwiftAgent Semantic Versioning

last-verified: 2026-09-21

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
