# Contributing to SwiftAgent

last-verified: 2026-09-20

This package is a provider-neutral Agent engine. Product UI, domain tools, and
host-specific policy do not belong in the portable modules.

## Layout

| Path | Role |
| --- | --- |
| `Sources/AgentModels` | Model data and `ModelProvider` |
| `Sources/AgentTools` | Typed tools, Evidence, Receipt, scheduler |
| `Sources/AgentCore` | Agent / Session / Run / Journal |
| `Sources/AgentProviders` | Anthropic and HTTP transport |
| `Sources/AgentCatalog` | Optional model/deployment discovery and bounded metadata cache |
| `Sources/AgentAppleProvider` | Apple Foundation Models adapter |
| `Sources/AgentDecisions` | Vendor-neutral typed decisions |
| `Sources/AgentJevProvider` | TypeSafe Jev adapter |
| `Sources/AgentUsage` | Optional in-memory usage aggregation |
| `Sources/WorkspaceAgent` | Reference Host, not Core SDK |

## Commands

Primary compiler: Swift 6.4. `swift-tools-version: 6.0` is the manifest floor.

From this directory:

```sh
bash Scripts/require-toolchain.sh --apple   # macOS
bash Scripts/ci-macos.sh
```

Linux:

```sh
bash Scripts/install-linux-swift.sh
bash Scripts/ci-linux.sh
```

Apple live model tests stay opt-in (`SWIFT_AGENT_APPLE_LIVE=1`,
`SWIFT_AGENT_ANTHROPIC_*`). Ordinary CI must not require live calls.

WorkspaceAgent may import `Crypto` from `apple/swift-crypto`. Core must not.

## Rules

- Non-UI engine behavior uses TDD.
- Do not put `MainActor` in Core, Models, Tools, or portable Providers.
- Mutation tools need `AgentJournalStorage.durable` at `makeSession`.
- Public API changes belong in the release checklist, a stable guide or ADR,
  and `docs/guides/swift-agent-versioning.md`; one-time review evidence stays
  in the parent project's Kanban records.
- WorkspaceAgent may use CryptoKit or `Crypto` from swift-crypto. Core must not.

See [docs/extraction.md](docs/extraction.md) for repository provenance
and [docs/security-model.md](docs/security-model.md) for trust boundaries.
