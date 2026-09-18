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

## Quick Start

These examples use only public types.

### 1. Read-only Agent

```swift
import AgentCore
import AgentModels
import AgentProviders
import AgentTools

let agent = try Agent(
    model: ModelID(provider: "anthropic", name: "claude-sonnet-4-6"),
    provider: try AnthropicProvider(apiKey: apiKey),
    configuration: AgentConfiguration(instructions: "Be concise.")
)
let session = try agent.makeSession()
let run = try await session.run("Summarize the last message.")
for await event in run.events {
    if case .model(.textDelta(let delta)) = event { print(delta, terminator: "") }
}
_ = try await run.wait()
```

Read-only Agents may omit a journal. Mutation tools cannot. A memory-only
`AgentJournal()` also fails for mutation Agents at `makeSession`.

### 2. Typed Tool

```swift
struct SearchTool: AgentTool {
    struct Input: Codable, Sendable { let query: String }
    struct Output: Codable, Sendable { let results: [String] }

    static let name = "search"
    static let description = "Search public records"
    static let inputSchema = ToolSchema.object(properties: ["query": .string], required: ["query"])
    static let outputSchema = ToolSchema.object(
        properties: ["results": .array(items: .string)], required: ["results"]
    )
    let search: @Sendable (String) async throws -> [String]
    let policy: ToolPolicy

    init(search: @escaping @Sendable (String) async throws -> [String]) throws {
        self.search = search
        policy = try .readOnly(authorization: .notRequired)
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        ToolResult(output: Output(results: try await search(input.query)))
    }
}
```

The runtime erases JSON for the model. Tool code decodes `Input` and returns
`Output`. Do not build argument dictionaries by hand.

### 3. Mutation Tool

```swift
struct UpdateListingTool: AgentTool {
    struct Input: Codable, Sendable { let id: String }
    struct Output: Codable, Sendable { let updated: Bool }

    static let name = "update_listing"
    static let description = "Update a listing"
    static let inputSchema = ToolSchema.object(properties: ["id": .string], required: ["id"])
    static let outputSchema = ToolSchema.object(properties: ["updated": .boolean], required: ["updated"])
    let policy: ToolPolicy

    init() throws {
        policy = try .mutation()
    }

    func resourceRequirements(for input: Input) throws -> [ToolResource] {
        [.named(.init(namespace: "listing", id: input.id))]
    }

    func evidenceRequirements(for input: Input) throws -> [EvidenceRequirement] {
        [.init(reference: .init(namespace: "listing", id: input.id), scope: .sameSession)]
    }

    func receiptExpectation(for input: Input) throws -> ToolReceiptExpectation? {
        try .init(targets: [.init(namespace: "listing", id: input.id)], revision: .present)
    }

    func authorize(_ input: Input, context: ToolContext) async throws -> ToolAuthorization {
        .allowed
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let receipt = ToolReceipt(
            operationID: context.idempotencyKey ?? "missing",
            status: .succeeded,
            confirmedTargets: [.init(namespace: "listing", id: input.id)],
            revision: "v2"
        )
        return ToolResult(output: .init(updated: true), receipt: receipt)
    }
}
```

`.mutation()` is exclusive, receipt-backed, and Evidence-required. Existing
resources should be observed in an earlier tool result before this runs.

### 4. Durable Session

```swift
let scheduler = ToolScheduler()
let journal = try AgentJournal(persistenceURL: journalURL)
let agent = try Agent(
    model: model,
    provider: provider,
    tools: [try UpdateListingTool()],
    configuration: AgentConfiguration(scheduler: scheduler)
)
let session = try agent.makeSession(id: sessionID, journal: journal)
_ = try await session.run("Update the listing").wait()

let restarted = try AgentJournal.load(from: journalURL)
for pending in await restarted.pendingMutations(sessionID: sessionID) {
    if pending.state == .needsReconciliation {
        try await restarted.abortMutation(pending)
    }
}
```

Two Sessions that mutate the same listing, player, or file store must share
`scheduler`. Crash recovery never replays a tool; the host reconciles or aborts.

## Module Boundaries

| Module | Internal dependencies | Responsibility |
| --- | --- | --- |
| AgentModels | None | Model data and provider contracts |
| AgentTools | AgentModels | Typed tools, validation and execution policy |
| AgentCore | AgentModels, AgentTools | The single agent loop, sessions and runs |
| AgentProviders | AgentModels | Native request and event conversion |
| AgentAppleProvider | AgentModels | Apple on-device structured planning; platform SDK isolation |
| WorkspaceAgent | AgentModels, AgentTools, AgentCore, AgentProviders | Non-player Reference Host for a sandbox file agent |

Providers receive model data, never a host tool executor. Execution belongs to
AgentCore and AgentTools. Domain policies remain in host adapters. WorkspaceAgent
is a second consumer of the public API; it must not feed file or path types back
into AgentCore.

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

[Tool Scheduling](../docs/guides/swift-agent-scheduler.md) covers parallel groups,
resource isolation, shared schedulers and executor lifetime after cancellation.

The [Agent Loop Contract](../docs/guides/swift-agent-loop.md) covers multi-turn tool
feedback, terminal outcomes, budgets, deadlines and run isolation.

For progress rendering, use the [Agent Event Stream](../docs/guides/swift-agent-events.md).

Use [Agent, Session and Run](../docs/guides/swift-agent-sessions.md) for conversation
history, independent sessions and explicit cancel/steer/wait control.

[Evidence](../docs/guides/swift-agent-evidence.md) defines trusted resource
observations, run/session scope, expiry and tool requirement binding.

[Receipts](../docs/guides/swift-agent-receipts.md) defines executor confirmations,
operation/target/revision binding and the remaining mutation admission requirements.

[Journal](../docs/guides/swift-agent-journal.md) defines typed lifecycle records,
durable checkpoints, crash-tail recovery and fail-closed persistence behavior.
It also defines durable mutation admission and explicit reconciliation without
automatic executor replay.

[Errors](../docs/guides/swift-agent-errors.md) lists the typed failure taxonomy.
Do not match `localizedDescription`.

[Concurrency](../docs/guides/swift-agent-concurrency.md) records the Swift 6.4
isolation audit. Core does not use MainActor.

[Versioning](../docs/guides/swift-agent-versioning.md) is the 1.0 compatibility
policy. Adding a public enum case is a source break.

The [Workspace File Agent](../docs/guides/swift-agent-workspace-host.md) is a second
Reference Host. It uses the same public Agent/Session/Run API with Anthropic or any
other conforming provider, and keeps sandbox file identity out of AgentCore.

The [public API audit](../docs/reviews/2026-09-18-swift-agent-public-api-audit.md)
is the freeze record for this branch.

[Apple Foundation Models](../docs/guides/swift-agent-apple-provider.md) documents
the on-device planning adapter, execution boundary and opt-in live verification.

[Anthropic Messages](../docs/guides/swift-agent-anthropic-provider.md) covers cloud
streaming, signed continuation, structured answers and opt-in gateway verification.
