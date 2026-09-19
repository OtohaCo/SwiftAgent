# SwiftAgent

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

SwiftAgent is a provider-neutral Agent runtime for Swift. It combines typed tools,
actor-isolated conversations, streaming events, Evidence-backed execution,
mutation receipts, durable journaling, crash recovery and provider adapters.

Use this README to choose a reading path. Detailed integration guides are currently
in English; the Chinese and Japanese READMEs provide the same navigation and scope.

## Start here

| What you are doing | Read first | Continue with |
| --- | --- | --- |
| Integrating SwiftAgent into an app | [App integration entry](INTEGRATION.md) | [Consumer recipes](docs/ai/consumer-recipes.md) |
| Asking Codex, Claude or another coding agent to build the integration | [AI integration guide](docs/ai/start-here.md) | [Acceptance checklist](docs/ai/acceptance-checklist.md) |
| Changing the SDK itself | [Contributing](CONTRIBUTING.md) | [Testing](docs/testing.md) and [security model](docs/security-model.md) |

**App integration and SDK development are different tasks.** A consuming app
should use public APIs, not modify the engine or copy internal executors to make
its UI work. For a coding agent, the reading order is: establish the dependency
revision, read `INTEGRATION.md`, choose a recipe, then apply the acceptance checks.
The checklist includes a fresh-context integration exercise, not just a review of
whether generated code looks plausible.

## Find the guide for your task

| Task | Guide |
| --- | --- |
| iOS/macOS UI, MainActor separation, Run ownership, Stop and navigation | [Apple UI integration](docs/guides/swift-agent-apple-ui.md) |
| Stream text and tool progress without parsing SSE in the UI | [UI streaming](docs/guides/swift-agent-ui-streaming.md) |
| Add a read tool, a mutation, restart recovery or a structured answer | [Consumer recipes](docs/ai/consumer-recipes.md) |
| Choose a conversational provider and check capability boundaries | [Provider matrix](docs/providers.md) |
| Use Noul, Choice and Score advice through TypeSafe Jev | [Decision Providers](docs/guides/swift-agent-decisions.md) |
| Run examples, configure keys and distinguish fixtures from real calls | [Examples and live qualification](docs/guides/swift-agent-examples-and-live.md) |
| Plan an app-owned speech, image, video or music service | [Host service tools](docs/guides/swift-agent-host-service-tools.md) — documentation only, not a media SDK |

Provider-specific contracts:
[Anthropic Messages](docs/guides/swift-agent-anthropic-provider.md) ·
[OpenAI Responses](docs/guides/swift-agent-openai-provider.md) ·
[DeepSeek Responses](docs/guides/swift-agent-deepseek-provider.md) ·
[Apple on-device/PCC](docs/guides/swift-agent-apple-provider.md).

## Version scope and installation

last-verified: 2026-09-19

The source-checked baseline for this README and its translations is
`c5f08c7520c989cf01234e19c1fd011b486ca76f` on the RC.2 development line.
This documentation is not a release announcement or a new test result. Always
read documentation from the same revision as the dependency installed in your app.

### Published rc.1

Pin the published release candidate when using its API:

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaPlayer/SwiftAgent.git",
        exact: "1.0.0-rc.1"
    )
]
```

The rc.1 anchor is `d2347f11c6a78f421708e897dae42a51a98d37ea`.
**Do not combine this rc.1 dependency with all the APIs described on the RC.2
line.** OpenAI/DeepSeek Responses, Decision/Jev and other next-RC additions need
the corresponding unreleased revision. Consult that revision's package and guides.

### Intentional next-RC evaluation

To reproduce the checked source baseline rather than follow a moving branch:

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaPlayer/SwiftAgent.git",
        revision: "c5f08c7520c989cf01234e19c1fd011b486ca76f"
    )
]
```

This is an explicit development pin, not a recommendation to ship an unaudited
revision or a claim that it is the latest commit. Add only the products your
target uses. The RC.2 development branch is `plan/swift-agent-rc2`; do not assume
that `main` contains those changes. See [versioning](docs/guides/swift-agent-versioning.md).

For a local package supplied by a Git submodule, the parent's gitlink pins the
SDK commit; the app's `Package.resolved` does not pin that local package.
Commit and push SDK changes first, validate the consuming app, then update its
gitlink. Do not silently follow a remote branch or upgrade to make guessed APIs compile.

## Requirements

| Surface | Requirement |
| --- | --- |
| Validated compiler / language mode | Swift 6.4 / Swift 6 |
| Core products | macOS 13+, iOS 16+, Linux |
| AgentDecisions / AgentJevProvider | macOS 13+, iOS 16+, Linux |
| Optional Apple Foundation Models adapter | macOS/iOS 26+; individual APIs, including PCC, have additional availability requirements |
| Other portable products | AgentModels, AgentTools, AgentProviders and WorkspaceAgent support Linux |

Check [Package.swift](Package.swift) and the Apple provider guide for exact
availability. `swift-tools-version: 6.0` is the manifest language floor, not the
compiler used for validation. Core does not depend on SwiftUI or Apple model SDKs.

## Run an existing example

From the **SwiftAgent repository root**:

```sh
swift test --package-path Examples/ExternalClient
swift run --package-path Examples/JevDecision JevDecision
```

[ExternalClient](Examples/ExternalClient) tests consumption through public API.
[JevDecision](Examples/JevDecision) is an executable fixture-first example of
Noul, Choice and Score. Its output is a proposal, not permission to execute a tool.
These are the executable entry points present at the checked baseline; the Apple
UI guides describe an integration pattern, not an already-shipped SwiftUI app.

For a real Jev call, inject `TYPESAFE_API_KEY` locally, then use a POSIX-compatible
shell:

```sh
: "${TYPESAFE_API_KEY:?Set TYPESAFE_API_KEY locally before a live run}"
export TYPESAFE_API_KEY
SWIFT_AGENT_JEV_LIVE=1 \
  swift run --package-path Examples/JevDecision JevDecision
```

`TYPESAFE_MODEL` optionally selects the model. The executable reads process
environment; creating a `.env` file does not load it automatically. From a parent
repository, prefix package paths with `SwiftAgent/`.

Keep credentials out of source, prompts, logs and shipped app binaries. Explicit
live mode must not be mistaken for a fixture run. Fixture checks, SDK CI, Host
integration and real-service qualification are separate evidence; missing keys
are not a passing live test. See the example guide for limits and acceptance.

## Async app integration and streaming

`Agent` holds Sendable configuration. `AgentSession` is an actor that owns
canonical conversation history and one active Run. `AgentRun` exposes `events`,
`cancel()`, `steer(_:)`, `wait()` and `waitForDrain()`.

A recommended app design separates a MainActor view model from an app-owned
conversation controller. Reserve startup before the first `await`, retain the
Run and its cleanup owner, and fence late callbacks by conversation/Run identity.
Async does not promise a dedicated background thread or indefinite iOS background
execution. These are host responsibilities described in the Apple UI guide.

**Consume `AgentRun.events` once.** Providers handle HTTP/SSE and emit normalized
model events; AgentCore emits the Run lifecycle used by the app. Multiple views
should use host-owned snapshots, not compete for the same single-consumer stream.
Deltas are provisional. Do not append the full answer again after displaying its
deltas, or treat a model response's completion as completion of the whole Run.
`ModelProviderRoute` intentionally buffers validated candidate responses and does
not advertise real-time streaming, even when the underlying network uses SSE.

Cancelling observation does not cancel the Run. `run.cancel()` requests execution
cancellation; `wait()` reports logical termination; `waitForDrain()` waits for the
SDK's resource-release lifecycle. Cancellation is not rollback or a guarantee of
remote cancellation. Follow the guides for failure cleanup and provider-drain limits.

## Trust boundaries

Conversation is not Evidence. A model proposal or Decision confidence is not
authorization. Providers never receive host tool executors; execution belongs to
AgentCore and AgentTools, with domain policy in the Host.

Mutation tools require a durable `AgentJournal` at Session creation, durable
intent before execution, a trusted validated Receipt and durable settlement before
success is claimed. Share a scheduler across sessions touching the same resources.
For retries of one logical mutation, retain the same non-empty `operationID`,
matching tool and semantic arguments, and shared journal. A new identity is a new
operation, not a safe retry.

Never fabricate a production Receipt or automatically abort an uncertain mutation
to clear the UI. Abort requires trusted confirmation that no external effect
occurred; otherwise reconcile. Recovery does not automatically replay an uncertain
executor. Read the security model and mutation recipes before implementing writes.

`DecisionProvider` is a separate, non-conversational contract. Jev output remains
untrusted advice and cannot create Evidence, grant permission, execute a tool,
create a trusted Receipt or settle the Journal.

## Products and dependencies

| Product | Internal dependencies | Responsibility |
| --- | --- | --- |
| AgentModels | None | Model values and provider contracts |
| AgentTools | AgentModels | Typed tools, validation and execution policy |
| AgentCore | AgentModels, AgentTools | The single agent loop, sessions and runs |
| AgentProviders | AgentModels | Anthropic, OpenAI Responses, DeepSeek Responses and validated routing |
| AgentAppleProvider | AgentModels | Apple on-device/PCC planning and platform SDK isolation |
| AgentDecisions | AgentModels | Typed, vendor-neutral decision requests and responses |
| AgentJevProvider | AgentModels, AgentDecisions | TypeSafe Jev adapter; no execution authority |
| WorkspaceAgent | AgentModels, AgentTools, AgentCore, AgentProviders | Sandbox-file Reference Host; not a Core dependency |

WorkspaceAgent also uses [swift-crypto](https://github.com/apple/swift-crypto) for
SHA-256; it does not introduce that dependency into Core. Media service clients,
job storage and assets belong in the consuming app or optional extensions, not
in AgentCore. The multimedia guide does not add a service implementation.

## Contract and evidence index

| Area | Detailed references |
| --- | --- |
| Model data and wire conversion | [ModelRequest](Sources/AgentModels/ModelRequest.swift), [ModelMessage](Sources/AgentModels/ModelMessage.swift), [ModelMetadata](Sources/AgentModels/ModelMetadata.swift), [model event contract](docs/guides/swift-agent-model-events.md) |
| Runtime and progress | [Agent loop](docs/guides/swift-agent-loop.md), [Sessions/Runs](docs/guides/swift-agent-sessions.md), [Agent events](docs/guides/swift-agent-events.md) |
| Tools and effects | [Typed tools](docs/guides/swift-agent-tools.md), [Evidence](docs/guides/swift-agent-evidence.md), [Receipts](docs/guides/swift-agent-receipts.md), [scheduling](docs/guides/swift-agent-scheduler.md) |
| Persistence and lifetime | [Journal](docs/guides/swift-agent-journal.md), [mutation recovery](docs/guides/swift-agent-mutation-recovery.md), [context policy](docs/guides/swift-agent-context.md), [concurrency](docs/guides/swift-agent-concurrency.md) |
| Errors and compatibility | [Typed errors](docs/guides/swift-agent-errors.md), [versioning](docs/guides/swift-agent-versioning.md) |
| Another app using the public API | [Workspace File Agent](docs/guides/swift-agent-workspace-host.md) |
| Verification records | [Testing commands](docs/testing.md), [named regressions](docs/testing-regressions.md), [review records](docs/reviews), [release records](docs/releases) |

Model Codable data is not a vendor wire format or a frozen journal format.
Usage is cumulative; unreported is not zero, and cache/reasoning subsets must not
be added to totals. Match typed errors instead of `localizedDescription` strings.
Read each review record's baseline and scope; a historical clean review is not
new evidence for a different commit.

## Developing and testing the SDK

Read `CONTRIBUTING.md` before changing the library. From the SDK root, use the
repository's scripts and actual supported environment:

```sh
bash Scripts/ci-macos.sh
bash Scripts/ci-concurrency-seal.sh
bash Scripts/ci-apple-provider.sh
```

On Ubuntu 24.04:

```sh
bash Scripts/install-linux-swift.sh
bash Scripts/ci-linux.sh
```

[DependencyGuardTests](Tests/ArchitectureTests/DependencyGuardTests.swift) check
package boundaries. [.github/workflows/ci.yml](.github/workflows/ci.yml) defines
SDK CI; it is not the consuming app's UI or live-service acceptance. Ordinary CI
is credential-free. Record builds, actual executions, skips and limits separately.
This README update does not claim to have run those commands.

## Translation maintenance

The English README is the translation source. Keep `README.md`, `README.zh-CN.md`
and `README.ja.md` synchronized when navigation or scope changes. Public API
identifiers, dependency revisions and executable commands stay unchanged between
languages. The translations cover this README; linked detailed guides remain in
English. If prose conflicts with the installed revision's public API or contract,
check that source and correct the documentation rather than invent an API.

License: [MIT](LICENSE).
