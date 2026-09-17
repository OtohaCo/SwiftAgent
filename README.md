# SwiftAgent

A standalone Swift package for provider-neutral agent infrastructure. See the
[implementation plan](../docs/plans/2026-09-17-swift-agent-engine-kanban.md) for task scope.

## Build and Test

From this directory, using a Swift 6 toolchain:

```sh
swift build
swift test
```

The package has no external dependencies and does not require the host Xcode project.
Apple/Linux portability is a design constraint; platform validation results live in
the task acceptance records.

## Module Boundaries

| Module | Internal dependencies | Responsibility |
| --- | --- | --- |
| AgentModels | None | Model data and provider contracts |
| AgentTools | AgentModels | Typed tools, validation and execution policy |
| AgentCore | AgentModels, AgentTools | The single agent loop, sessions and runs |
| AgentProviders | AgentModels | Native request and event conversion |

Providers receive model data, never a host tool executor. Execution belongs to
AgentCore and AgentTools. Domain policies remain in host adapters.

`swift test` runs [DependencyGuardTests](Tests/ArchitectureTests/DependencyGuardTests.swift).
The guard checks the resolved package graph and scans Swift sources, including
inactive conditional branches. Core tests are scanned too. Domain tokens and
MainActor are rejected in the portable modules, including comments and fixtures.
Import rules are a conservative source guard, not a Swift parser or a proof of loop
ownership; architectural review remains required. New platform adapter imports
must be added explicitly with matching guard tests.
