# Start here: build an app with SwiftAgent

last-verified: 2026-09-19

Audience: a developer or coding agent integrating the SDK into another app.
Executable-example baseline: `c17adeb86f5ea086e9ac9f2d454a41fbe7f85455`.
The fixture and explicit-live entry points at this baseline are recorded in the
acceptance checklist. Each provider and platform has its own evidence boundary;
iOS cross-build is not iOS simulator/device UI acceptance.

## 1. Establish the version before writing code

Inspect the consuming app's resolved dependency, local package or submodule
commit. Read the SDK sources and guides at that revision. Do not combine an
`exact: "1.0.0-rc.1"` dependency with unreleased Decision, Jev or Responses
examples from a later branch. Do not upgrade a dependency merely to make a
speculative API compile.

For a submodule consumer, the parent's gitlink is the integration pin; a local
package reference is not pinned by a remote SwiftPM entry. Keep SDK source
commits and host integration commits separate. Never run a remote-following
submodule update as an implicit integration step.

Record the Swift toolchain, language mode, default actor isolation and deployment
target of the app. At this SDK baseline the validated compiler is Swift 6.4;
portable products target macOS 13+, iOS 16+ and Linux. Optional Apple model APIs
have higher availability requirements; see [Package.swift](../../Package.swift)
and [the provider matrix](../providers.md).

## 2. Choose the correct integration surface

| Need | Existing surface | What it does not do |
| --- | --- | --- |
| A conversation that may propose and execute registered host tools | `Agent`, `AgentSession`, `AgentRun` from `AgentCore`, with `AgentModels` and `AgentTools` as needed | It is not a UI framework |
| One conversational model turn without a host tool executor | `ModelProvider` from `AgentModels`; adapters in `AgentProviders` or `AgentAppleProvider` | A provider must not own an agent loop |
| Typed Noul, Choice and Score advice | `DecisionProvider` from `AgentDecisions`; `JevDecisionProvider` from `AgentJevProvider` | Advice is not authorization or evidence |
| An app-owned operation, including an external service call | An app-defined `AgentTool` | Tool declarations are not permission to act |

Do not make Jev conform to `ModelProvider`. Do not put a speech/image/music
service in `AgentCore`. Do not register SwiftAgent executors with a vendor's
native agent loop. Add only the products the consuming target needs.

## 3. Follow a recipe instead of inventing API

- Apple chat or assistant: [UI ownership](../guides/swift-agent-apple-ui.md),
  then [event rendering](../guides/swift-agent-ui-streaming.md), with
  [AppleChatApp](../../Examples/AppleChatApp) as the executable reference.
- Linux HTTP service: [server ownership, streaming and deployment](../guides/swift-agent-server.md).
- Android app: choose [remote service or native embedding](../guides/swift-agent-android.md)
  before designing the bridge or declaring platform support.
- Read-only tool, mutation, restart or typed decision:
  [consumer recipes](consumer-recipes.md).
- Credentials and executable examples:
  [examples and live qualification](../guides/swift-agent-examples-and-live.md).
- A future external AI service: [host service tools](../guides/swift-agent-host-service-tools.md).

`AppAgentController`, `RenderSnapshot`, `ServiceJobRecord` and similarly named
objects in these guides are proposed **app-owned** types, not SDK exports.
Lifecycle pseudocode is marked as such. Inspect public declarations before
introducing a call; do not guess helpers such as `run.subscribe()`,
`agent.executeProposal()` or `decision.authorize()`.

The public Run operations are `events`, `cancel()`, `steer(_:)`, `wait()` and
`waitForDrain()`. See [AgentRun.swift](../../Sources/AgentCore/AgentRun.swift).
Host configuration belongs on `AgentConfiguration`; do not invent extra Agent
initializer parameters. Examples import public API, not `@testable` or package
internals.

## 4. Preserve these boundaries

Conversation and provisional model text are not Evidence. Tool proposals and
Decision confidence are not authorization. Executor return is not durable
mutation success. An uncertain effect must be reconciled, not silently retried.

Mutation tools require a durable journal at Session creation. Share a scheduler
across sessions that can touch the same host resources. Create a stable operation
identity for attempts of one logical mutation; do not assign a new identity on
every UI retry. Never fabricate a successful Receipt to keep a demonstration
moving. See [the security model](../security-model.md).

The SDK's canonical conversation belongs to the Session. A UI draft and a
rendered transcript are projections, not a replacement authority. Opaque
continuation belongs to its provider; do not show, modify or repurpose it as
trusted state.

## 5. Ask an integration agent to deliver observable evidence

A useful app-side task is:

> Use this exact SwiftAgent revision and its public API. Implement one owner for
> each conversation, one consumer of each Run event stream, platform-appropriate
> display delivery (MainActor for Apple UI), explicit Stop, and guarded replacement
> after drain. Keep fixtures
> separate from live mode. Do not edit the SDK or bypass tool policy to make the
> app compile. Report the build configuration, exercised scenarios, actual
> results and unverified items.

Require a build and the [acceptance checks](acceptance-checklist.md), not merely
a plausible diff. If a required public capability is absent, report the gap and
choose a supported host design rather than creating an undocumented SDK API.

For a server, also specify authenticated ownership, disconnect policy and the
client protocol. For Android, record whether SwiftAgent runs remotely or inside
the app. A Linux build does not qualify the Android bridge or a server deployment;
use the chosen platform guide's acceptance gates as well.

## Evidence and maintenance

The linked source and existing contract guides establish SDK behavior. The
controller and display projection in `Examples/AppleChatApp` are example-owned
reference code, not new AgentCore API. Future examples must be linked only after
they exist and pass their stated checks. After API or lifecycle changes, update
the affected recipe and its source-checked revision; do not copy old review
verdicts as new test evidence.
