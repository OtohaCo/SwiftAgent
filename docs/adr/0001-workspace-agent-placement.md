# ADR 0001: WorkspaceAgent placement

status: Accepted
date: 2026-09-18

## Context

WorkspaceAgent is a non-music Reference Host. It proves the public Agent /
Session / Run API works for a sandbox file agent. It is not a product module
and must not enter Core.

Two placements were considered for the independent repository:

- **A.** SwiftPM product `WorkspaceAgent` plus `WorkspaceAgentTests`
- **B.** `Examples/WorkspaceAgent` only

## Decision

Keep **scheme A**: a first-class SwiftPM product and test target named
`WorkspaceAgent`.

It is Generality Proof / Reference Host, not Core SDK. README, the public API
audit, and CONTRIBUTING must say so. Apps that want only the engine link
`AgentCore` (and the providers they need). They do not have to link
`WorkspaceAgent`.

## Why not Examples/

Moving the host into `Examples/` would make the default `swift test` miss the
generality proof, or force a second package manifest. That cost is not worth
a clearer folder name. Documentation is the positioning tool.

Do not relocate sources for this extraction. The current module layout already
matches the independent repository.

## Consequences

- macOS CI runs WorkspaceAgent tests.
- Linux CI compiles WorkspaceAgent through `apple/swift-crypto` (`Crypto`) and
  runs its tests. AgentCore does not depend on that package.
- Otoha stays out of this repository.
