# SwiftAgent Public API Inventory

last-verified: 2026-09-20

This is the stable API-freeze record for RC.2. It is generated from Swift 6.4
symbol graphs and describes the package products, not package-internal or test
symbols. The published rc.1 anchor remains
`d2347f11c6a78f421708e897dae42a51a98d37ea`.

## Reproduction

From the repository root:

```sh
swift package dump-symbol-graph --minimum-access-level public
```

Count `.symbols` entries with `accessLevel == "public"`. Count top-level types
as public symbols whose `pathComponents` contain one component and whose kind
is a struct, class, enum, protocol, actor or typealias. The graph was generated
with Apple Swift 6.4 / Xcode 27 on 2026-09-20.

## RC.1 to RC.2

| Product | RC.1 identifiers | RC.2 identifiers | Added | Removed |
| --- | ---: | ---: | ---: | ---: |
| AgentModels | 260 | 274 | 14 | 0 |
| AgentTools | 311 | 311 | 0 | 0 |
| AgentCore | 283 | 431 | 148 | 0 |
| AgentProviders | 41 | 157 | 116 | 0 |
| AgentAppleProvider | 5 | 7 | 2 | 0 |
| AgentCatalog | 0 | 240 | 240 | 0 |
| AgentDecisions | 0 | 131 | 131 | 0 |
| AgentJevProvider | 0 | 7 | 7 | 0 |
| AgentUsage | 0 | 145 | 145 | 0 |
| WorkspaceAgent | 56 | 56 | 0 | 0 |
| **Total** | **956** | **1,759** | **803** | **0** |

The RC.2 graph has 188 top-level public types, compared with 100 at the rc.1
anchor. The source graph was regenerated from the production candidate commit
`043e3b8` before the final documentation-only seal; the final release candidate
must retain this graph without source changes.

## Freeze decisions

- `AgentCatalog` is optional discovery data, not a closed SDK model list.
- `AgentModelBinding` is immutable per Run; routing remains Host-owned.
- Context projection is request-only and cannot replace canonical history,
  Evidence, mutation state, or Journal checkpoints.
- Provider continuation origin is scoped to the execution target and is not
  portable conversation memory.
- `AgentUsage` is optional observation and does not alter execution, settlement,
  or crash recovery.
- Provider-specific extensible values remain raw-value types where future wire
  values are expected; exhaustive public enums are not extended casually.

No public symbol was removed between the rc.1 anchor and this RC.2 candidate.
Any later production change requires regenerating this inventory and repeating
the API review before RC.2 release preparation.
