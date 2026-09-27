# Consumer recipes: supported paths and trust boundaries

last-verified: 2026-09-19

Use with [the version and API entry](start-here.md). These are app integration
recipes using existing public concepts, not new SDK helper implementations.

## A. A conversation with no host effects

Products: `AgentModels`, `AgentCore`, plus the chosen provider product. Import
`AgentTools` when declaring tools or scheduler configuration.

Create an `Agent` with the selected `ModelID`, conforming provider and
`AgentConfiguration`. Retain a Session for the conversation; call its async
`run(...)`; retain the returned Run and one event consumer. Handle terminal
outcome and drain according to [the UI owner protocol](../guides/swift-agent-apple-ui.md).
Use the same Session for a later turn. Do not reconstruct another Session on
every SwiftUI body evaluation or copy displayed strings into a private history
replacement.

A read-only Agent may omit the Journal. This does not promise persistence after
process death. Model namespace and capabilities must match the configured
adapter; unsupported capability is not permission to fall back silently.

Source: [Agent.swift](../../Sources/AgentCore/Agent.swift),
[AgentSession.swift](../../Sources/AgentCore/AgentSession.swift).

## B. A local or network-backed read tool

Define an app-owned `AgentTool` with typed Codable/Sendable input and output,
input/output schemas, resource declarations and an explicit policy. Register it
when constructing the Agent. Only mark authorization not required when the
actual host operation is public and the app policy permits it; do not do so to
remove a test failure.

Return evidence only from trusted observations, not model-supplied assertions.
If an expected read failure should be shown to the model, use the supported
recoverable-error policy and typed `RecoverableToolError`. Do not convert ordinary
authorization, evidence, cancellation, malformed output or persistence errors
into fabricated successful results.

The UI can show proposed arguments but must not invoke the tool from those
events. See [Tools](../guides/swift-agent-tools.md),
[Evidence](../guides/swift-agent-evidence.md) and
[Events](../guides/swift-agent-events.md).

## C. A mutation with a real external result

Supply a durable `AgentJournal` when making the Session. Share one scheduler for
the relevant real resources. The tool declares resources, current Evidence
requirements, authorization and a receipt expectation before executor entry.
Do not impose an invented universal ordering on these checks; use the existing
runtime's admission and scheduling path.

The host executor performs the actual operation. A trusted response establishes
the operation identity, targets and revision used to construct its Receipt.
`status: .succeeded` is not a value to invent just because the model requested
success. A mock-only tool may fabricate a mock result for a clearly labelled
fixture, but that code must not be presented as a real storage/network adapter.

The runtime validates the Receipt and durably settles the operation. If execution
may have occurred but the result/settlement is uncertain, preserve reconciliation
state. Do not retry an executor directly, downgrade the tool to read-only, or
remove receipt validation to make the UI continue.

For attempts of one logical mutation, retain the same non-empty `operationID`
and the same open store handle. Deduplication also binds the tool and semantic arguments;
changing them changes the operation's meaning. An idempotent replay still needs
current policy/evidence. See [Sessions](../guides/swift-agent-sessions.md),
[Receipts](../guides/swift-agent-receipts.md) and
[Journal](../guides/swift-agent-journal.md).

## D. Restart and reconciliation

Reopen the journal and recreate the Session with its intended stable identity
and current configuration. Inspect pending operations before initiating new
mutations. Restored conversation may mention a resource, but process-local
Evidence is not reconstructed from that prose; rediscover when required.

Reconciliation is a trusted host procedure: query the authoritative external
system, establish whether the admitted effect occurred, and bind the verified
Receipt and canonical replay output to that operation. Use
`reconcileMutation(_:receipt:output:)`.

Only abort after confirming that no external side effect occurred. An unknown
outcome, Cancel button, timeout, lost network response or convenient empty receipt
is not evidence for abort. Recovery never automatically executes the original
tool. Test process restart independently of page navigation.

Do not parse error-description strings to choose recovery. See
[typed errors](../guides/swift-agent-errors.md) and
[context restoration](../guides/swift-agent-context.md).

## E. A structured answer

Pass the supported `StructuredOutputSchema` through `AgentConfiguration` and
choose a provider whose configured capabilities support it. The wire encoding
belongs to the adapter; avoid a second HTTP client in the UI.

Streamed text is still provisional. Do not execute an action based on a parseable
prefix or repair truncated JSON to force a domain result. Check the Run outcome
and apply the app's domain validation to the accepted complete response. Handle
refusal and incomplete outcomes explicitly. Do not invent a public typed-patch
stream that this SDK does not expose.

See [ModelRequest.swift](../../Sources/AgentModels/ModelRequest.swift),
[the provider matrix](../providers.md) and
[UI streaming](../guides/swift-agent-ui-streaming.md).

## F. Decision/Jev advice

Products: `AgentModels`, `AgentDecisions` and `AgentJevProvider` for Jev.
Construct a `DecisionRequest`, then await `JevDecisionProvider.decide(...)`.
For other vendors, implement the actual `DecisionProvider` contract rather than
pretending the result is a conversational ModelEvent.

Noul, Choice and Score have distinct meanings. Preserve question and candidate
identity and use the requested score rubric. A probability/confidence of 1 does
not authorize an action. Public result values are advice; do not assume arbitrary
third-party or decoded persisted values have passed the Jev decoder. Validate
what the host needs against the corresponding request; do not call a guessed
`validate(against:)` API without checking its existence.

A UI can display advice directly. To turn it into a possible tool operation,
use a supported normal Agent path and the existing policy/evidence/receipt
boundary; do not introduce a second trusted executor loop. See
[Decisions](../guides/swift-agent-decisions.md) and the existing
[JevDecision source](../../Examples/JevDecision/Sources/JevDecision/main.swift).

## Common integration failures

| Symptom | Investigate first |
| --- | --- |
| `runInProgress` | Active/draining ownership or a duplicate startup; do not create another Session with the same ID |
| `durableJournalRequired` | A registered mutation tool with missing or memory-only journal |
| No incremental text through a route | The route intentionally buffers; check its descriptor |
| Missing history after navigating back | The app destroyed the owner or expected event replay |
| Duplicate final answer | The UI appended both deltas and the full terminal response |
| Second request cannot replay | Provider/model identity, continuation ownership, supported history and exact adapter contract |
| Stop appears successful but a file changed | Cancellation is not rollback; inspect trusted mutation state |
| Jev example prints fixture results | Live opt-in was not enabled; environment configuration is not implicit |

Report a minimal reproduction using public API before modifying the SDK. An app
integration task should not silently change the library's safety contract.
