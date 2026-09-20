# SAI-072 Public API additions

Date: 2026-09-20
Baseline: `cb8cd022d5ad08f5739d714057200826aa523c95`
Candidate: `bc19c62`
Comparison: Swift symbol graphs generated with Swift 6.4 / Xcode 27

## Inventory

| Product | Baseline identifiers | Candidate identifiers | Added |
| --- | ---: | ---: | ---: |
| AgentModels | 260 | 273 | 13 |
| AgentTools | 311 | 311 | 0 |
| AgentCore | 283 | 431 | 148 |
| AgentProviders | 122 | 155 | 33 |
| AgentAppleProvider | 7 | 7 | 0 |
| AgentDecisions | 131 | 131 | 0 |
| AgentJevProvider | 7 | 7 | 0 |
| AgentUsage | 139 | 145 | 6 |
| AgentCatalog | 0 | 240 | 240 |
| WorkspaceAgent | 56 | 56 | 0 |
| **Total** | **1,316** | **1,759** | **443** |

Top-level public types are 138 in the baseline and 188 in the candidate. The
candidate adds no removed precise public identifier after the compatibility
overloads were restored. The independent-review remediation at `bc19c62` does
not add or remove library public identifiers.

## Added surface

The additions are limited to:

- `AgentCatalog`: open model/deployment identity, provenance, tri-state
  capabilities, independent reasoning controls, discovery protocols, provider
  clients, and bounded last-known-good cache;
- `AgentCore`: immutable `AgentModelBinding`, conversation snapshots,
  request-only context projection, host-approved read-only span projection,
  token budget checks, and `AgentSession` Run/snapshot entry points;
- `AgentModels`: continuation origin metadata and optional request validation;
- `AgentProviders`: Anthropic effort configuration and OpenAI/Anthropic/
  DeepSeek model-catalog adapters plus request validation conformances;
- `AgentUsage`: non-secret binding profile, deployment, context epoch, and
  route-source dimensions on observation identity.

The `DynamicModelRouting` example is a separate package and does not add its
types to the SwiftAgent library products.

## Compatibility decisions

Existing public initializers remain available for:

- `ModelProviderContinuation.init(model:format:payload:)`;
- `AnthropicProvider` initializers without effort;
- `UsageRecordIdentity.init(source:sessionID:runID:invocationID:providerResponseID:model:)`.

The new fields are additive. Existing `Agent(model:provider:)` and
`AgentSession.run(_:)` continue to use the default binding and identity
projection. No Journal schema version or public enum case was added for this
feature.

## Stability notes

`AgentCatalog` is optional and does not make model discovery a prerequisite for
explicit execution. Catalog values are data, not a closed SDK model list.
`AgentModelBinding` is immutable per Run; routing remains Host-owned. Projection
plans are request metadata and do not replace canonical history or trusted
runtime state. The API must be regenerated before an RC.2 freeze and reviewed
again if the implementation changes.
