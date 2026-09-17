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
Apple deployment minimums are declared in [Package.swift](Package.swift). Platform
providers may impose higher availability requirements within their adapters.
Apple/Linux portability is a design constraint; platform validation results live in
the task acceptance records.

## Module Boundaries

| Module | Internal dependencies | Responsibility |
| --- | --- | --- |
| AgentModels | None | Model data and provider contracts |
| AgentTools | AgentModels | Typed tools, validation and execution policy |
| AgentCore | AgentModels, AgentTools | The single agent loop, sessions and runs |
| AgentProviders | AgentModels | Native request and event conversion |
| AgentAppleProvider | AgentModels | Apple on-device structured planning; platform SDK isolation |

Providers receive model data, never a host tool executor. Execution belongs to
AgentCore and AgentTools. Domain policies remain in host adapters.

`swift test` runs [DependencyGuardTests](Tests/ArchitectureTests/DependencyGuardTests.swift).
The guard checks the resolved package graph and scans Swift sources, including
inactive conditional branches. Core tests are scanned too. Domain tokens and
MainActor are rejected in the portable modules, including comments and fixtures.
Import rules are a conservative source guard, not a Swift parser or a proof of loop
ownership; architectural review remains required. New platform adapter imports
must be added explicitly with matching guard tests.

## Model Data

Start with [ModelRequest](Sources/AgentModels/ModelRequest.swift) and
[ModelMessage](Sources/AgentModels/ModelMessage.swift). Messages retain ordered
content parts, assistant tool calls and result-to-call identities. Requests carry
tool declarations and structured output schemas; run budgets and execution
callbacks belong to orchestration.

All model values are Sendable and Codable. Their Codable representation is package
data, not a provider wire format or a frozen journal format. Provider adapters own
wire conversion. `JSONValue` emits native JSON and uses Foundation Decimal's
precision and range; raw tool arguments preserve their original text.

Tool call completeness records transport state only. A complete call still needs
registry validation and authorization. `ToolResultMessage` is model-facing content,
not an execution receipt. Usage fields distinguish unreported counts from zero;
see [ModelMetadata](Sources/AgentModels/ModelMetadata.swift) for accounting semantics.

For streaming, follow the [Model Event Contract](../docs/guides/swift-agent-model-events.md).
It defines event ordering, cumulative usage, terminal validation and the conditions
under which the agent loop may consider a tool batch for execution.

Tool authors can start with the [Typed Tool Contract](../docs/guides/swift-agent-tools.md)
for Swift input/output types, schema declarations, authorization and execution policy.

The [Agent Loop Contract](../docs/guides/swift-agent-loop.md) covers multi-turn tool
feedback, terminal outcomes, budgets, deadlines and run isolation.

For progress rendering, use the [Agent Event Stream](../docs/guides/swift-agent-events.md).

Use [Agent, Session and Run](../docs/guides/swift-agent-sessions.md) for conversation
history, independent sessions and explicit cancel/steer/wait control.

[Evidence](../docs/guides/swift-agent-evidence.md) defines trusted resource
observations, run/session scope, expiry and tool requirement binding.

[Receipts](../docs/guides/swift-agent-receipts.md) defines executor confirmations,
operation/target/revision binding and the remaining mutation admission requirements.

[Apple Foundation Models](../docs/guides/swift-agent-apple-provider.md) documents
the on-device planning adapter, execution boundary and opt-in live verification.
