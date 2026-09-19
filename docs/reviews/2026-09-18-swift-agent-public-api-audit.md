# SwiftAgent Public API Audit

last-verified: 2026-09-19
status: 1.0.0-rc.1 freeze plus audited post-rc.1 additive provider surface

This inventory is the SAI-026 freeze record, updated by SAI-026B hardening,
SAI-039 recoverable read-only tool failures, and the SAI-047 RC audit.
Symbols stay public only when a third-party SDK user needs them. Host tests
in another package are not a sufficient reason to keep a type public.

WorkspaceAgent is a Reference Host. It is not part of the Core SDK product
surface even though it ships in this package.

## Summary

| Decision | Core SDK types | Notes |
| --- | --- | --- |
| KEEP | 86 | Includes data contracts, errors, journal storage, and host-facing recovery |
| NARROW / PACKAGE | 13 | Loop, journal writes, mutation admission, schema validator, durability enum, tool runtime erase/registry/prepared call |
| RENAME | 0 | Cosmetic renames deferred; `AgentLoopResult` stays the run result type |
| REMOVE | 1 | Flattened `Agent` initializer that duplicated `AgentConfiguration` |
| DEFER | 5 | See deferred list; none block 1.0 |

Counts are types (struct/enum/protocol/actor/class), not every property. Members
follow the type decision unless noted. SAI-047 separately generated and
reviewed the complete 956-symbol `1.0.0-rc.1` public member graph. The current
post-rc.1 branch has 1,013 public member symbols and 105 public top-level types:
57 precise identifiers were added and none removed. See
[the generated member inventory](2026-09-19-swift-agent-public-api-members.md).
Every current member is KEEP, with NARROW/REMOVE already absent from the public
graph.

## Breaking changes made now

These belong in 1.0-pre, not after a tagged SDK:

1. `Agent.makeSession` throws. Mutation tools without a **durable** journal fail
   at Session creation with `AgentSessionError.durableJournalRequired`.
2. `AgentLoop` is package-only. Apps use `Agent` / `AgentSession` / `AgentRun`.
3. Journal write, lease, admit, and executor-settlement APIs are package-only.
   Hosts inspect, recover, reconcile, or abort. They cannot append a settlement
   event.
4. `AgentJournalDurability` is package-only.
5. `ToolMutationAdmission` / `ToolMutationAdmissionRequest` are package-only.
6. `ToolSchemaValidator` is package-only. `ToolSchemaValidationError` stays
   public because registry errors expose it.
7. New enum cases: `AgentSessionError.durableJournalRequired`,
   `AgentFailure.session`, `AgentFailure.scheduler`. Swift exhaustive switches
   must update.
8. `abortMutation` is added as the public abort path for quarantined intents.
9. SAI-026B: memory-only `AgentJournal()` is no longer accepted for mutation
   Sessions. `AgentJournalStorage` is the capability API.
10. SAI-026B: the flattened `Agent(model:provider:tools:instructions:structuredOutput:maxModelTurns:maxToolCalls:runTimeout:scheduler:)` initializer is removed.
11. SAI-026B: `AnyAgentTool`, `ToolRegistry`, and `PreparedToolCall` are package-only.

`AgentConfiguration`, `ToolPolicy.readOnly()` / `.mutation()`, and
`AgentJournalStorage` are additive. The remaining `Agent` convenience is
`Agent(model:provider:tools:instructions:)`.

## AgentModels

| Symbol | Current | Decision | Reason | Breaking? |
| --- | --- | --- | --- | --- |
| JSONValue | public | KEEP | Model content, schemas, Evidence metadata | No |
| ResponseInfo | public | KEEP | Stream identity | No |
| ModelResponse | public | KEEP | Terminal model payload | No |
| ModelEvent | public | KEEP | Provider streaming contract | No |
| ModelEventAccumulator | public | KEEP | Provider implementers validate streams | No |
| ModelStreamError | public | KEEP | Typed stream failures | No |
| ModelEventStream | public | KEEP | Provider helper; cancellation ownership | No |
| ModelRole / ModelContent / ModelMessage | public | KEEP | Canonical history | No |
| ToolCallID / ToolCall / ToolResultMessage | public | KEEP | Model-facing tool I/O | No |
| ModelCapabilities / ModelUsage / StopReason | public | KEEP | `StopReason.unknown` is the extension point | No |
| ModelProvider | public | KEEP | App and adapter requirement | No |
| ModelProviderRunDrain | public | KEEP | Host drain after cancel | No |
| ModelProviderMutationBoundary | public | KEEP | Fallback routes after an effect | No |
| ModelProviderDescriptor / ModelProviderError | public | KEEP | Identity and taxonomy | No |
| ModelProviderContinuation | public | KEEP | Opaque provider state, not parsed by Core | No |
| ModelID / ModelToolDefinition / StructuredOutputSchema / ModelRequest | public | KEEP | Request contract | No |

JSONValue is model data, not a tool-author API. Ordinary tools use Codable
Input/Output. Internal runtime erasure still uses JSONValue.

## AgentTools

| Symbol | Current | Decision | Reason | Breaking? |
| --- | --- | --- | --- | --- |
| AgentTool | public | KEEP | Tool authors | No |
| ToolAuthorization / ToolResult | public | KEEP | Authorize and return typed output | No |
| ToolMutationAdmission* | package | PACKAGE | Runtime admission seam | Yes |
| AnyAgentTool | package | PACKAGE | Runtime type-erase. Hosts pass `[any AgentTool]` | Yes |
| ToolInvocationError | public | KEEP | Typed invocation failures | No |
| Evidence* / EvidenceLedger / EvidenceError | public | KEEP | Hosts and tools record/validate observations. Ledger stays public because hosts may unit-test evidence without a Session | No |
| ToolContext | public | KEEP | Session/run/call identity for tools | No |
| ToolPolicy / ToolPolicyError | public | KEEP | Recoverable read errors are explicit and default fail-closed | Additive members; error enum expansion is source-breaking |
| RecoverableToolError / RecoverableToolErrorValidationError | public | KEEP | Tool authors explicitly construct the only business failure Core may expose to the model | Additive types; validation enum requires switch handling when used |
| ToolReceipt* / ToolReceiptValidator / ToolReceiptError | public | KEEP | Mutation confirmation | No |
| ToolRegistry / PreparedToolCall | package | PACKAGE | Registry and prepared invocation are runtime seams | Yes |
| ToolRegistryError | public | KEEP | Appears on `AgentFailure.toolRegistry` | No |
| ToolResource / ToolResourceError | public | KEEP | Scheduler identity | No |
| ToolResourceCoordinator | package | PACKAGE | Scheduler internals | No |
| ToolScheduler / ToolSchedulerError | public | KEEP | Must be shared across Sessions that touch the same resources | No |
| ToolSchema | public | KEEP | Typed schema builder | No |
| ToolSchemaValidator | package | PACKAGE | Runtime validator | Yes |
| ToolSchemaValidationError | public | KEEP | Wrapped by registry errors | No |

## AgentCore

| Symbol | Current | Decision | Reason | Breaking? |
| --- | --- | --- | --- | --- |
| AgentConfiguration / Agent | public | KEEP | Long-lived factory. Configuration is the advanced surface | Flattened init removed |
| AgentBudget | public | KEEP | Per-run override | No |
| AgentRunInfo / AgentEvent / AgentRunTermination | public | KEEP | Observability. `toolStarted` means runtime admission, reserved for SAI-030 telemetry without redefining the case | Additive cases |
| AgentFailure | public | KEEP | Switchable taxonomy | New cases |
| AgentToolReceipt | public | KEEP | Validated receipt on the run | No |
| AgentCompactionSummary | public | KEEP | Journal event payload | No |
| AgentJournalRunOutcome / AgentMutationState / AgentMutationSettlementSource | public | KEEP | Recovery vocabulary | No |
| PendingMutationRecovery / PendingMutationIntent | public | KEEP | Host reconciliation | No |
| AgentJournalEvent / AgentJournalRecord | public | KEEP | snapshot() is host-readable | No |
| AgentJournalRecovery | public | KEEP | Crash-tail signal | No |
| AgentJournalStorage | public | KEEP | Durable mutation capability | Additive |
| AgentJournalDurability | package | PACKAGE | Write-path detail | Yes |
| AgentJournalError / AgentJournal | public | KEEP | Hosts load, inspect, recover, reconcile, abort; SAI-040 adds pending/replay-unavailable cases and output-aware reconciliation | Write APIs package; enum expansion is source-breaking |
| AgentLoop | package | PACKAGE | Orchestration detail | Yes |
| AgentLoopOutcome / AgentLoopResult / AgentLoopError | public | KEEP | Run result and limits | No |
| AgentRun / AgentRunError | public | KEEP | events / cancel / steer / wait / waitForDrain | Additive `waitForDrain` |
| AgentSession / AgentSessionError | public | KEEP | History and run ownership | New error case |

History is `public private(set)`. Callers cannot assign it. `activeRunID` is
readable and not assignable.

## AgentProviders / AgentAppleProvider

| Symbol | Current | Decision | Reason | Breaking? |
| --- | --- | --- | --- | --- |
| AnthropicProvider / AnthropicThinking | public | KEEP | Optional cloud adapter | No |
| OpenAIResponsesProvider / OpenAIReasoningEffort / OpenAIReasoningSummary | public | KEEP | Stateless Responses adapter and extensible vendor reasoning values | Additive types |
| DeepSeekResponsesProvider / DeepSeekReasoningEffort | public | KEEP | Independent stateless Responses adapter with explicit validated effort values | Additive types; future enum case would be source-breaking |
| ModelProviderRoute / fallback policy types | public | KEEP | Validated fallback among adapters sharing one provider namespace | `candidateProviderIDMismatch` is a 1.0-pre enum expansion |
| ProviderHTTPTransport / URLSessionProviderHTTPTransport / ProviderHTTPEvent | public | KEEP | Custom transports and deterministic fixtures without linking Apple | No |
| AppleFoundationProvider | public | KEEP | Isolated in its own target because of FoundationModels; additive on-device/PCC factories and model IDs | Additive members |

Apple stays a separate target. Anthropic stays in AgentProviders: no heavy SDK,
FoundationNetworking only on Linux. Do not split further until a provider adds a
heavy dependency.

## WorkspaceAgent (Reference Host, not Core SDK)

| Symbol | Current | Decision | Reason | Breaking? |
| --- | --- | --- | --- | --- |
| WorkspaceAgentHost | public | KEEP (host) | Second-app constructor | makeSession throws |
| WorkspaceFileStore / WorkspacePath / WorkspaceFileError / listing types | public | KEEP (host) | Sandbox file identity | No |
| Workspace*Tool types | internal | KEEP internal | Created through `makeTools` | No |

## SAI-026B Freeze Hardening

This round closes contracts that would be expensive to change after 1.0.

### Journal capability API

Public:

```swift
public enum AgentJournalStorage: Sendable, Equatable {
    case memory
    case durable
}

public actor AgentJournal {
    public nonisolated var storage: AgentJournalStorage { get }
}
```

`AgentJournal()` advertises `.memory`. `init(persistenceURL:)` and
`load(from:)` advertise `.durable`. Successful `persist(to:)` upgrades
`.memory` to `.durable`. The name is a capability, not `hasPersistenceURL`.
`.durable` means persistence mode is configured so crash-tail recovery can be
attempted. It does not mean every later write will succeed; intent appends can
still throw. A future database, remote, or encrypted journal should also
advertise `.durable` when it can keep an admitted mutation intent across
process death.

`makeSession` for a mutation Agent:

| Journal | Result |
| --- | --- |
| `nil` | `AgentSessionError.durableJournalRequired` |
| `AgentJournal()` | `AgentSessionError.durableJournalRequired` |
| `AgentJournal(persistenceURL:)` | success |
| memory journal after `persist(to:)` | success |

Read-only Agents still accept `nil`, memory, and durable journals. Fail-fast
happens before any model call, journal event, tool invocation, Evidence write,
or session history append.

### Agent initializer freeze

Keep:

```swift
Agent(model:provider:tools:configuration:)
Agent(model:provider:tools:instructions:)
```

Remove the flattened initializer that repeated every `AgentConfiguration`
field. Two complete configuration surfaces would drift. Otoha and
WorkspaceAgent now pass `AgentConfiguration` for limits, structured output,
and scheduler. The `instructions:` convenience stays because it is the common
read-only path and cannot drift independently of configuration defaults.

This is a 1.0 freeze decision. Pre-1.0 compatibility is not a reason to keep
the worse entry.

### AnyAgentTool

**Package.** Ordinary hosts pass `[any AgentTool]` into `Agent`. The runtime
erases. A third-party framework does not need to construct `AnyAgentTool`.
Same-package tests still see it.

### ToolRegistry

**Package.** Inspecting definitions, validating registration, and preparing
calls is the runtime's job. `ToolRegistryError` stays public because
`AgentFailure.toolRegistry` exposes it.

### PreparedToolCall

**Package.** This object is the post-schema, post-resource-resolution
invocation seam for the scheduler. Third-party apps should not construct or
hold it. Otoha profile tests that previously prepared a call now run the
wrapped tool through `Agent` / `AgentSession` and assert public receipts.

Tingting and SwiftAgent are not the same Swift package, so `package` is
invisible to Otoha. That is correct: the host should not reach runtime
internals. Tests changed instead of re-publicizing the types.

### Why now, not after 1.0

A tagged 1.0 would make each of these a major version. Memory journals
silently accepted at `makeSession` contradicted `durableJournalRequired`.
Two Agent initializers would freeze a dual surface. Public prepared-call
types would freeze a scheduler seam.

## Deferred to 1.x

1. Renaming `AgentLoopResult` to `AgentRunResult`.
2. Packaging `EvidenceLedger` once hosts stop constructing it in unit tests.
3. SAI-030 admission vs executor telemetry. Do not add public event cases now.
4. Per-file mutation concurrency. Global exclusive mutation on a shared scheduler
   is the frozen correct semantics.
5. Packaging `JSONValue` away from tool authors. Model content still needs it.

## Host ergonomics

Otoha and WorkspaceAgent both construct `Agent` + `makeSession` + `AgentRun`.
Shared `ToolScheduler` and `AgentJournal` are explicit, which is correct. Otoha
still wraps Session in `OtohaEngineRunRuntime` for MainActor conversation UI;
that adapter is host-specific and must not become Core API.

Both hosts needed `try` on Session creation after fail-fast. That is a Core
contract fix, not a domain leak.

## Event freeze

Public `AgentEvent` cases are business semantics:

- `runStarted` exactly once
- zero or more turns
- `model` wraps the Model Event Contract
- `toolStarted` is runtime admission, including authorization, not executor-start
- `toolCompleted` / `toolFailed` / `toolReceiptValidated`
- `steeringApplied`
- exactly one `runFinished`

Do not add scheduler-lease or HTTP-frame cases to this enum. SAI-030 may add a
diagnostic channel later without redefining `toolStarted`.

## SAI-038 additive freeze

These belong in 1.0-pre. Exhaustive switches must update:

1. `AgentRun.waitForDrain()` — physical provider/tool drain and Session identity
   release. SAI-042 changed it from `async` to `async throws`: cancelling one
   observer throws `CancellationError`, while the Session-owned physical drain
   and other waiters continue. This is an intentional 1.0-pre source break;
   callers add `try`. Same owner as `AgentSession.waitForRunToDrain(runID:)`.
   `wait()` is only the logical terminal.
2. `AgentJournalRecovery.corruptTail` and `AgentJournalError.repairRequired`.
   Hosts inspect the valid prefix, then call `discardCorruptTail()` before
   another durable write.

3. `AgentMutationPersistenceError` and `AgentFailure.mutationPersistence`.
4. `AgentContextPolicy`, `AgentContextCompactor`, `AgentRetainedTurnCompactor`,
   `AgentContextError`, and `AgentFailure.context`.
5. `AgentConfiguration.contextPolicy` default.

Do not treat checkpoint `system` messages as active runtime configuration.
Restore always applies the current Agent instructions. Physical journal
rollover is internal and automatic after safe checkpoints; it adds no public
Journal mutation API.

## SAI-039 additive freeze

`RecoverableToolError` is a new public, `Sendable`, `Equatable` error with a
stable non-empty `code`, non-empty model-visible `message`, and optional
`JSONValue` details. `ToolPolicy.RecoverableErrors` and the
`recoverableErrors` policy field are additive; their default is `.failClosed`,
including when decoding a policy written before SAI-039.

Only `.readOnly` plus `.modelVisible` plus a thrown `RecoverableToolError`
creates an `isError == true` model result. Mutation policies reject that opt-in
with the new `ToolPolicyError.mutationCannotExposeRecoverableErrors` case.
Adding that public enum case is source-breaking for exhaustive switches. The
default behavior of existing source remains fail-closed, so this is not a
behavior break for existing tools. No journal schema or provider capability
changes were made.

## SAI-043 additive freeze

Conversation context is a 1.0-pre contract:

1. Default `AgentContextPolicy.compactor` is `nil`. Crossing the active history
   bound without a host compactor throws `AgentContextError.historyTooLarge`.
2. `AgentContextPolicy.lossyRetainedTurns` is the explicit opt-in for
   `AgentRetainedTurnCompactor`. It is lossy and does not preserve dropped
   tool results.
3. Compaction summaries remain synthetic `.user` messages with the
   `Conversation summary:` prefix so restore will not strip them as runtime
   configuration.
4. Evidence is not restored from transcript. Conversation restart and Evidence
   restart are separate contracts.

Do not add host-domain fields such as last search results to AgentCore.

## SAI-040 compatibility freeze

Durable mutation deduplication is a 1.0-pre contract. It adds public
`AgentJournalError.mutationPending` and `mutationReplayUnavailable` cases plus
output-aware `reconcileMutation` overloads. Public enum expansion is
source-breaking for exhaustive switches. No new public type is added. The
journal schema advances from version 2 to version 3; version 1 and version 2
records remain readable.

The deduplication domain is one shared durable `AgentJournal`. A non-nil
`operationID` is the logical operation identity reused across retry attempts.
The durable key combines that stable operation ID, the tool name, and canonical
semantic JSON arguments. Tool call ID, Session ID, and Run ID are not part of
the key. Nil or blank `operationID` retains per-call behavior and provides no
cross-run deduplication.

Admission follows the latest durable state:

1. `intent` fails closed with `AgentJournalError.mutationPending`.
2. `needsReconciliation` fails closed with
   `AgentJournalError.mutationRequiresReconciliation`.
3. `settled` revalidates and returns the original receipt without invoking the
   executor. The original canonical JSON output is durable and is validated
   against the current tool output schema. Transcript and `AgentToolReceipt`
   use the current tool call ID. Legacy settlements without output fail closed
   with `mutationReplayUnavailable`.
4. `aborted` allows a new durable lifecycle only after the trusted Host has
   explicitly confirmed that the previous attempt produced no side effect.

Authorization and Evidence currently run before replay admission. Settled and
aborted identities remain durable indefinitely; there is no expiry or terminal
identity pruning in this contract.

## SAI-047 RC freeze

The generated symbol graphs contain 100 public top-level types across the six
products: AgentModels 26, AgentTools 26, AgentCore 32, AgentProviders 8,
AgentAppleProvider 1, and WorkspaceAgent 7. The audit result is KEEP 100,
NARROW 0, REMOVE 0. WorkspaceAgent remains an optional Reference Host product;
its seven public types are not part of the Core SDK compatibility promise.

`ModelProviderRoute` is a validated fallback adapter, not a cross-provider
model-name rewriting layer. Every candidate must use the route descriptor ID.
The new `ModelProviderFallbackPolicyError.candidateProviderIDMismatch` case is
an intentional pre-1.0 source break for exhaustive switches. A route buffers a
candidate turn until terminal validation, so it no longer advertises
`.streaming`; same-provider retries honor `ModelProviderError.retryAfter`.

The throwing `RecoverableToolError` initializer is frozen for 1.0. Validation
failure is a typed construction error rather than a precondition trap or silent
normalization. `AgentRun.waitForDrain()` is also frozen as `async throws`:
caller cancellation removes only that waiter and does not cancel physical drain.

Journal v3 remains the write schema. SAI-047 adds no schema version. Legacy v1
record semantics survive canonical rewrite, valid v2 session-scoped identity
collisions load conservatively, and all new v3 admissions retain journal-wide
identity scope.

## Post-rc.1 provider additions

The published `1.0.0-rc.1` graph contains 956 public member symbols and 100
public top-level types. The current branch contains 1,013 and 105 respectively.
The exact precise-identifier comparison reports 57 additions and zero removals.
The five new top-level types are:

1. `OpenAIReasoningEffort`
2. `OpenAIReasoningSummary`
3. `OpenAIResponsesProvider`
4. `DeepSeekReasoningEffort`
5. `DeepSeekResponsesProvider`

OpenAI reasoning values are extensible raw-value structs so newer vendor wire
values do not require an enum expansion. DeepSeek reasoning effort is a closed
enum for the currently validated vocabulary. Adding a new case later is a
source break for exhaustive client switches and must be treated accordingly.

The remaining additions are provider members and synthesized conformances, the
Anthropic alias-aware initializer, and Apple Private Cloud Compute members. No
AgentCore, AgentModels, AgentTools, or WorkspaceAgent public symbol changed in
this remediation round. No Journal schema or continuation format version was
changed.
