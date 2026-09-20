# Dynamic model selection

> last-verified: 2026-09-20

This guide describes the RC.2 model-selection slice. It is intentionally a
Host capability: `AgentCore` captures an immutable execution binding for each
Run, while catalog discovery and routing remain optional products or app code.

## Model catalogs are advisory

`AgentCatalog` represents model identity, deployment scope, provenance, and
capabilities with three states: `supported`, `unsupported`, and `unknown`.
Unknown is not the same as unsupported. A catalog entry may describe a model
without proving that the current SwiftAgent adapter can encode every advertised
parameter.

`OpenAIModelCatalogProvider`, `AnthropicModelCatalogProvider`, and
`DeepSeekModelCatalogProvider` use their documented model-list shapes. OpenAI
and Anthropic cursor pagination is passed through the bounded cache; DeepSeek's
current model-list shape is treated as a single page. They preserve incomplete
metadata and never make discovery a prerequisite for an explicitly configured
Run. `ModelCatalogCache` is host-refreshed, bounded, and keeps a stale
last-known-good snapshot separate from a failed refresh.

```swift
let catalog = try await ModelCatalogCache().refresh(
    using: openAIModels,
    policy: .init(timeToLive: 15 * 60, maximumPages: 4)
)
let entry = catalog.models.first { $0.model.name == "a-model-id" }
```

Do not infer tools, reasoning, context windows, or pricing from a model name.
Use a host manifest when an upstream catalog does not report the needed facts;
record its scope, revision, and source.

## Bind a Run, not a Session

The existing `session.run("...")` API still uses the Agent default. To select a
different model or provider configuration for one new Run, create an immutable
`AgentModelBinding` and pass it explicitly:

```swift
let binding = try AgentModelBinding(
    profileID: "private-balanced",
    profileRevision: "2026-09-20.1",
    model: ModelID(provider: "anthropic", name: "model-id"),
    provider: provider,
    deployment: try AgentModelDeployment(
        serviceInstanceID: "anthropic-primary",
        endpointScope: "https://api.anthropic.com/v1",
        apiDialect: "anthropic-messages",
        apiVersion: "2023-06-01"
    ),
    configurationSummary: ["effort": .string("medium")]
)

let snapshot = await session.conversationSnapshot()
let run = try await session.run(
    "Continue the task.",
    using: binding,
    expectedConversationRevision: snapshot.revision
)
let result = try await run.wait()
try await run.waitForDrain()
```

The provider, model, profile revision, projector, and token budget are fixed
for that Run. Changing a Host default affects a later Run; it cannot mutate an
active loop or a Run that is draining. A failed preflight does not append the
new user message.

## History compatibility and handoff

The default explicit binding is strict. Provider continuation is accepted only
when its model and deployment origin match the binding. A model name alone is
not proof that two service instances understand the same opaque state.

`AgentSemanticHandoffProjector` is an explicit, lossy Host choice. It removes
provider-private continuation and reasoning while preserving visible content
and tool-call/result pairs. It does not fabricate a native continuation, close
an unresolved tool call, mint Evidence, or authorize a mutation. If no safe
handoff exists, keep the old Session unchanged and surface the typed failure.

## Projection is request-only

`AgentContextProjector` receives a canonical snapshot and returns messages for
one request plus a versioned plan and source digest. The projection never
replaces Session history or Journal checkpoints. The default
`AgentIdentityContextProjector` is lossless.

For a read-only error corrected by a later successful call, a Host may supply
an explicit `AgentResolvedReadOnlyToolSpan`. The projector replaces the whole
closed interaction group with a source-marked summary only after validating
the failed and successful call IDs, tool name, order, and result status. Keep
permission failures, mutation uncertainty, active calls, and unresolved pairs.

## Budget and routing

`AgentContextTokenBudget` accepts a Host-supplied estimator and reserves output,
reasoning, and protocol space with checked arithmetic. An estimate is not a
tokenizer and is not the provider's usage report.

The runnable [DynamicModelRouting](../../Examples/DynamicModelRouting) example
shows the intended Host boundary. It filters a finite candidate set, blocks
remote classification for sensitive tasks, lets Jev choose only a legal
candidate ID, rechecks conversation/catalog revisions, applies cooldown and
cache-aware pricing policy, and finally starts a Run with the selected binding.
Jev receives no credentials, opaque continuation, full tool log, endpoint, or
permission to execute a tool.

Run it without network access:

```sh
swift run --package-path Examples/DynamicModelRouting DynamicModelRouting
swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel
```

Set `SWIFT_AGENT_JEV_LIVE=1` only when the Host has separately approved a live
TypeSafe request and configured `TYPESAFE_API_KEY` and `TYPESAFE_MODEL`. The
example remains a decision proposal; it never grants authorization.

## Compatibility boundary

Existing Agent construction, `session.run(_:)`, provider wire protocols,
Journal schema, mutation identity, Evidence, Receipt, and usage accounting are
unchanged. Provider-native append-only cache configuration is not implemented.
Cache hit, price, and lifetime usage remain Host observations; an identical
Session ID or a new Provider instance does not prove a server cache hit.
