# Contributing to SwiftAgent

last-verified: 2026-09-18

This package is a provider-neutral Agent engine. Otoha, music tools, playback,
and Tingting product code do not belong here.

## Layout

| Path | Role |
| --- | --- |
| `Sources/AgentModels` | Model data and `ModelProvider` |
| `Sources/AgentTools` | Typed tools, Evidence, Receipt, scheduler |
| `Sources/AgentCore` | Agent / Session / Run / Journal |
| `Sources/AgentProviders` | Anthropic and HTTP transport |
| `Sources/AgentAppleProvider` | Apple Foundation Models adapter |
| `Sources/WorkspaceAgent` | Reference Host, not Core SDK |

## Commands

From this directory, Swift 6 toolchain:

```sh
swift build
swift test
swift build --triple arm64-apple-ios16.0
```

Apple live model tests stay opt-in (`SWIFT_AGENT_APPLE_LIVE=1`,
`SWIFT_AGENT_ANTHROPIC_*`). Ordinary CI must not require live calls.

## Rules

- Non-UI engine behavior uses TDD.
- Do not put `MainActor` in Core, Models, Tools, or portable Providers.
- Mutation tools need `AgentJournalStorage.durable` at `makeSession`.
- Public API changes belong in `docs/reviews/` and `docs/guides/swift-agent-versioning.md`.
- WorkspaceAgent may use CryptoKit. Core must not.

See [docs/extraction.md](docs/extraction.md) for the independent-repository plan
and [docs/security-model.md](docs/security-model.md) for trust boundaries.
