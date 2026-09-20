# Next RC Development Policy

> last-verified: 2026-09-19

SwiftAgent `1.0.0-rc.1` is frozen at
`d2347f11c6a78f421708e897dae42a51a98d37ea`. The tag and GitHub Release are
immutable. RC.2 development uses a dedicated feature branch and does not
rewrite the published release or merge to `main`.

## Scope

The next release candidate may add provider adapters, a vendor-neutral decision
contract, examples, and fixes accepted through review. `AgentLoop` remains the
only orchestration authority. Provider and decision output cannot bypass Tool
policy, Evidence, mutation admission, Receipt validation, or Journal settlement.

Every new public symbol must have a documented cross-vendor purpose and a clear
stability rationale. Vendor wire formats remain internal to their adapters.

The dynamic-model selection slice adds the optional `AgentCatalog` product,
immutable per-Run model bindings, request-only context projection, provider
deployment-scoped continuation metadata, and a fixture-first Host routing
example. The stable [public API inventory](../guides/swift-agent-public-api.md)
records the reproducible symbol-graph comparison; candidate-specific evidence
belongs in the parent project's Kanban.

## Release Gate

Before the next release candidate is authorized:

- Independent review findings are classified and resolved or explicitly deferred.
- macOS, Linux, iOS cross-build, Apple adapter, ExternalClient, and examples pass.
- Hosted CI passes on the exact candidate commit.
- Open P0, P1, and release-blocking P2 findings are zero.
- The release tag and GitHub Release are created only after explicit authorization.
