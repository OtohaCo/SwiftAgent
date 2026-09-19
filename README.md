# SwiftAgent

SwiftAgent is a provider-neutral Agent runtime for Swift with typed tools,
durable sessions, Evidence-backed execution, mutation receipts, crash recovery,
idempotent retries, and provider adapters.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and
[the security model](docs/security-model.md) for trust boundaries.

## Requirements

- Swift 6.4 validated compiler
- Swift language mode 6
- macOS 13+ or iOS 16+ for Core products
- macOS/iOS 26+ for the optional Apple Foundation Models adapter
- Linux support for AgentModels, AgentTools, AgentCore, AgentProviders, and WorkspaceAgent

## Installation

The current release candidate is `1.0.0-rc.1`:

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaPlayer/SwiftAgent.git",
        exact: "1.0.0-rc.1"
    )
]
```

Then add only the products the target uses, for example `AgentModels`,
`AgentTools`, and `AgentCore`. Release builds should pin a version rather than
follow `main`.

The `main` branch contains development for the next release candidate. Use it
only when intentionally testing unreleased changes:

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaPlayer/SwiftAgent.git",
        branch: "main"
    )
]
```

## Build and Test

Primary compiler: **Swift 6.4**. Jobs fail if `swift --version` is not 6.4.
`// swift-tools-version: 6.0` only declares the Package.swift language used by
the manifest, not the compiler CI must run.

From this directory:

```sh
bash Scripts/ci-macos.sh
```

AgentCore has no extra package dependencies. WorkspaceAgent uses
[swift-crypto](https://github.com/apple/swift-crypto) for SHA-256 so Linux can
compile the Reference Host without putting an encryption library in Core.
Apple deployment minimums are declared in [Package.swift](Package.swift).
Platform providers may impose higher availability requirements within their
adapters.

The repository workflow is [.github/workflows/ci.yml](.github/workflows/ci.yml).
It validates macOS, Linux, the optional Apple adapter, ExternalClient, iOS
cross-compilation, and the named concurrency seal without live credentials.

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
try await run.waitForDrain()
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
        policy = try .readOnly(
            authorization: .notRequired,
            recoverableErrors: .modelVisible
        )
    }

    func execute(_ input: Input, context: ToolContext) async throws -> ToolResult<Output> {
        let results = try await search(input.query)
        guard !results.isEmpty else {
            throw try RecoverableToolError(
                code: "not_found",
                message: "No result was found."
            )
        }
        return ToolResult(output: Output(results: results))
    }
}
```

The runtime erases JSON for the model. Tool code decodes `Input` and returns
`Output`. Do not build argument dictionaries by hand. Both the read-only policy
opt-in and `RecoverableToolError` are required. The
runtime sends a structured `ToolResultMessage` with `isError == true`, then
continues the model loop. Ordinary errors, malformed calls, authorization or
Evidence failures, cancellation, deadlines, mutations, receipts, and journal
failures remain fail-closed.

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

For Host retries, pass the same non-nil `operationID` to every attempt of one
logical mutation. A shared durable journal deduplicates by operation ID, tool,
and canonical arguments: pending or uncertain attempts fail closed, while a
settled retry reuses the original receipt and durable schema-valid tool output
without running the executor again.
Generating a new operation ID for every HTTP or UI retry disables cross-run
deduplication.

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
let run = try await session.run("Update the listing")
_ = try await run.wait()
try await run.waitForDrain()

let restarted = try AgentJournal.load(from: journalURL)
for pending in await restarted.pendingMutations(sessionID: sessionID) {
    if pending.state == .needsReconciliation {
        try await restarted.abortMutation(pending)
    }
}
```

Two Sessions that mutate the same listing, account, or file store must share
`scheduler`. Crash recovery never replays a tool; the host reconciles or aborts.

`wait()` resolves at logical Run termination. `waitForDrain()` waits for
provider/tool physical drain and Session identity release. Cancelling one drain
waiter does not cancel the Session-owned drain.

## Provider Model

`ModelProvider` is the provider-neutral request and event contract.
`AgentProviders` supplies Anthropic, OpenAI Responses, and DeepSeek Responses
transports plus validated routing; `AgentAppleProvider` is an optional Apple
Foundation Models adapter. Provider continuations are opaque and
provider-specific, not conversation memory or portable trusted state. See the
[provider matrix](docs/providers.md) and the
[DeepSeek guide](docs/guides/swift-agent-deepseek-provider.md) for the declared
capability and live-test boundaries.

## Evidence and Mutation Safety

Conversation memory is not Evidence, and a model proposal is not authorization.
Mutation execution requires durable intent before the executor, a validated
Receipt, and durable settlement before success is claimed. Crash recovery never
automatically replays an uncertain mutation.

Cross-Run retry safety requires the same non-nil `operationID`, the same tool,
canonical semantic arguments, and a shared durable `AgentJournal`. A new
operation ID represents a new logical mutation.

## Platform Support

| Surface | Platforms |
| --- | --- |
| Core products | macOS 13+, iOS 16+, Linux |
| AgentAppleProvider | macOS/iOS 26+ |
| Validated compiler | Swift 6.4 |

`WorkspaceAgent` is a Reference Host and generality proof. AgentCore does not
depend on it.

## Testing

```sh
bash Scripts/ci-macos.sh
bash Scripts/ci-concurrency-seal.sh
```

On Ubuntu 24.04, install/verify Swift 6.4 and run:

```sh
bash Scripts/install-linux-swift.sh
bash Scripts/ci-linux.sh
```

The ExternalClient package under `Examples/ExternalClient` imports public API
only. Live Anthropic, OpenAI, and Apple model tests remain explicit operator
opt-ins. DeepSeek currently has deterministic fixture/schema coverage only.

## Module Boundaries

| Module | Internal dependencies | Responsibility |
| --- | --- | --- |
| AgentModels | None | Model data and provider contracts |
| AgentTools | AgentModels | Typed tools, validation and execution policy |
| AgentCore | AgentModels, AgentTools | The single agent loop, sessions and runs |
| AgentProviders | AgentModels | Native request and event conversion |
| AgentAppleProvider | AgentModels | Apple on-device and PCC structured planning; platform SDK isolation |
| WorkspaceAgent | AgentModels, AgentTools, AgentCore, AgentProviders | Domain-neutral Reference Host for a sandbox file agent |

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

For streaming, follow the [Model Event Contract](docs/guides/swift-agent-model-events.md).
It defines event ordering, cumulative usage, terminal validation and the conditions
under which the agent loop may consider a tool batch for execution.

`ModelProviderRoute` provides validated retry and fallback among adapters that
share one provider namespace. Candidate responses are buffered until their
terminal event validates, so a route intentionally does not advertise realtime
streaming. Candidate descriptor IDs must match the route ID, and same-provider
retries honor a classified `retryAfter` delay.

Tool authors can start with the [Typed Tool Contract](docs/guides/swift-agent-tools.md)
for Swift input/output types, schema declarations, authorization and execution policy.

[Tool Scheduling](docs/guides/swift-agent-scheduler.md) covers parallel groups,
resource isolation, shared schedulers and executor lifetime after cancellation.

The [Agent Loop Contract](docs/guides/swift-agent-loop.md) covers multi-turn tool
feedback, terminal outcomes, budgets, deadlines and run isolation.

For progress rendering, use the [Agent Event Stream](docs/guides/swift-agent-events.md).

Use [Agent, Session and Run](docs/guides/swift-agent-sessions.md) for conversation
history, independent sessions and explicit cancel/steer/wait control.

[Evidence](docs/guides/swift-agent-evidence.md) defines trusted resource
observations, run/session scope, expiry and tool requirement binding.

[Receipts](docs/guides/swift-agent-receipts.md) defines executor confirmations,
operation/target/revision binding and the remaining mutation admission requirements.

[Journal](docs/guides/swift-agent-journal.md) defines typed lifecycle records,
durable checkpoints, crash-tail recovery and fail-closed persistence behavior.
It also defines durable mutation admission and explicit reconciliation without
automatic executor replay.

[Errors](docs/guides/swift-agent-errors.md) lists the typed failure taxonomy.
Do not match `localizedDescription`.

[Sessions](docs/guides/swift-agent-sessions.md) freeze `wait()` as logical
termination and `waitForDrain()` as physical resource release.

[Context Policy](docs/guides/swift-agent-context.md) separates runtime
configuration, conversation transcript, and trusted Evidence. Default
compaction is fail-closed; hosts opt in to lossy summaries.

[Concurrency](docs/guides/swift-agent-concurrency.md) records the Swift 6.4
isolation audit. Core does not use MainActor.

[Versioning](docs/guides/swift-agent-versioning.md) is the 1.0 compatibility
policy. Adding a public enum case is a source break.

The [security model](docs/security-model.md) states what the SDK can and cannot
guarantee. Model output is never authorization.

The [Workspace File Agent](docs/guides/swift-agent-workspace-host.md) is a second
Reference Host. It uses the same public Agent/Session/Run API with Anthropic or any
other conforming provider, and keeps sandbox file identity out of AgentCore.

The [public API audit](docs/reviews/2026-09-18-swift-agent-public-api-audit.md)
is the freeze record for this branch.

The [conformance matrix](docs/reviews/2026-09-18-swift-agent-conformance-matrix.md)
compares SwiftAgent to Pi's agent tests and records what is Covered, backlog, or
not applicable. [Testing](docs/testing.md) is the command entry;
[named regressions](docs/testing-regressions.md) index production bugs.

[Apple Foundation Models](docs/guides/swift-agent-apple-provider.md) documents
the on-device planning adapter, execution boundary and opt-in live verification.

[Anthropic Messages](docs/guides/swift-agent-anthropic-provider.md) covers cloud
streaming, signed continuation, structured answers and opt-in gateway verification.

[OpenAI Responses](docs/guides/swift-agent-openai-provider.md) covers stateless
conversation replay, function calls, structured output, reasoning, and usage.

[DeepSeek Responses](docs/guides/swift-agent-deepseek-provider.md) covers
stateless replay, legal incomplete output, plaintext reasoning continuation,
and fixture-only verification scope.
