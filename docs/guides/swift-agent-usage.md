# Usage accounting

last-verified: 2026-09-20

`AgentUsage` is an optional, Linux-portable product for aggregating usage that a
Host can observe through public events. It depends only on `AgentModels`.
`AgentCore` does not depend on it, and accounting diagnostics never change a
Run outcome, tool settlement, Evidence, Receipt, or journal state.

## What is counted

`ModelUsage` remains a single response's cumulative provider report:

- `inputTokens` and `outputTokens` are response totals.
- `cachedInputTokens` and `cacheWriteInputTokens` are input subsets.
- `reasoningTokens` is an output subset.
- `nil` means unreported. An explicit `0` means reported as zero.
- `totalTokens` is exact only when every selected response reports both input
  and output. Cache and reasoning subsets are never added again.

Within one response, later snapshots replace earlier reported values. A sparse
snapshot keeps fields reported earlier for that same response. Across responses,
the ledger adds each response's final known value and preserves per-field
`reportedCount`, `missingCount`, and `complete`.

`UsageSummary` exposes three views of the same accounting window:

- `observedUsage`: every visible response, including provisional responses.
- `finalizedUsage`: only responses that reached `responseCompleted`.
- `provisionalUsage`: started responses that did not reach completion.

The convenience fields such as `summary.inputTokens` and `summary.totalTokens`
refer to `observedUsage`. Check the finalized and provisional views separately
when a Run failed or was cancelled.

## Identity and recording

Create one `UsageObservation` for each cumulative snapshot or final confirmation.
Its `UsageRecordIdentity` binds source, Session, Run, invocation, provider/model,
and an optional provider response ID. A provider response ID alone is not a
global deduplication key.

`model` is part of that identity and must stay stable for every observation of
one invocation. Event consumers should use `ResponseInfo.model` from the
started response rather than switching between a requested alias and a resolved
model name mid-response.

The first release accepts two explicit sources: `.modelResponse` and
`.decision`. Decoding an unknown source preserves its raw value for inspection,
but recording it returns `invalidIdentity` until the Host wires and classifies
that source. This prevents an unintegrated internal model call from being
silently reported as covered.

```swift
import AgentModels
import AgentUsage

var usage = UsageAccumulator()

let identity = UsageRecordIdentity(
    source: .modelResponse,
    sessionID: sessionID,
    runID: runID,
    invocationID: "\(runID):turn-1",
    providerResponseID: responseInfo.id,
    model: responseInfo.model
)

let result = usage.record(.init(
    identity: identity,
    usage: responseUsage,
    status: .finalized
))

if let diagnostic = result.diagnostic {
    // Mark the report incomplete; do not change the Agent Run result.
    report(diagnostic)
}

let runUsage = usage.summary(sessionID: sessionID, runID: runID)
let sessionWindow = usage.summary(sessionID: sessionID)
```

Use `UsageAccumulator` inside an actor or another existing synchronization
owner. Use the actor-isolated `UsageLedger` when the Host does not already own
serialization. `removeAll()` starts a new explicit accounting window.

## Event ownership

Map `AgentEvent` to observations in the Host's existing single consumer:

1. `runStarted` supplies Session, Run, and model identity.
2. `turnStarted` supplies a new invocation identity.
3. `responseStarted` records an empty provisional response.
4. `usage` records a cumulative provisional snapshot.
5. `responseCompleted` records the final snapshot exactly once.

Do not open a second `for await` over `AgentRun.events`, and do not add
`AgentLoopResult.response.usage` again after consuming `responseCompleted`.
Join the observer before reading the final accounting summary; `wait()` alone
does not prove that the observer processed the last event.

## Scope definitions

- **Response**: one provider or decision invocation identity.
- **Run**: all visible response identities with one Session ID and Run ID.
- **Case**: a Host-defined window that may contain multiple Runs.
- **Session window**: records retained by one explicit ledger window for a
  Session. It is not automatically the Session's lifetime total.

Conversation checkpoints contain messages, not a usage ledger. Reloading a
journal cannot reconstruct historical usage. Keep or persist records separately
if a product needs a longer accounting window; this package does not provide a
crash-safe usage database.

Observations and summaries are `Codable` for Host-owned export. Encoding them
does not make the accounting window durable or transactionally coupled to the
Agent journal.

## Diagnostics and limits

Exact duplicate observations are idempotent. Conflicting finalized data,
counter regressions, negative values, invalid subset relationships, and checked
integer overflow return a typed `UsageDiagnostic` and leave the last valid state
unchanged.

Coverage is limited to public events integrated by the Host. Provider-route
candidates hidden behind fallback, transport attempts, implicit retries, and
unwired summarizer or tool-internal model calls are not counted. Response counts
must not be presented as HTTP send attempts; ProviderQualification keeps its
budget ledger separate.

No tokenizer, context-size estimator, price catalog, currency conversion, or
billing reconciliation is included. Cost remains unknown unless a consuming
product implements and labels a separate pricing/accounting system.
