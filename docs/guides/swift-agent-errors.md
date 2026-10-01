# SwiftAgent Error Taxonomy

## RC6 candidate: authorization errors

`AgentAuthorizationError` maps to `AgentFailure.authorization` in Run events and
execution reports. Missing audit prerequisites, Host deny/user action,
authorizer failure/timeout, stale or mismatched decision, changed action,
expiry/revocation, backlog and export errors stay typed. Actual store failures
remain `AgentJournalError` (including `commitUnknown`); audit failure never
silently grants execution. Host timeouts/errors are not recorded as deny.

If publishing failure audit also fails, `AgentAuditPersistenceError` preserves
`original` and `audit` as typed `AgentFailure` values; events and execution reports
use `AgentFailure.auditPersistence`. Required mutation quarantine still runs.
If quarantine also fails, `AgentMutationPersistenceError.settlement` contains
that composite and `quarantine` contains its separate failure. No failed
quarantine is reported as successfully persisted; reopen a poisoned handle.
Unknown Host errors remain `unclassified` without private error strings.
See [Audited Authorization](swift-agent-authorization-audit.md).

last-verified: 2026-10-02

Match errors by type. Do not parse `localizedDescription`.

`run.wait()` throws the original error. `AgentEvent.runFinished(.failed)` carries
`AgentFailure` for the stream. Those cases are constructed by the runtime; clients
switch on them rather than wrapping arbitrary errors themselves.

| User meaning | Type | Typical source |
| --- | --- | --- |
| Model / provider failure | `ModelProviderError` | Adapter `kind` |
| Request does not fit the model's context window | `ModelProviderError` with `kind == .contextWindowExceeded` | The provider rejected the request; see below. Never retried |
| Stream protocol error | `ModelStreamError` | Accumulator / incomplete stream |
| Tool schema or unknown tool | `ToolRegistryError` | Preparation |
| Tool invocation / authorization | `ToolInvocationError` | `authorizationDenied`, invalid arguments |
| Stale or missing Evidence | `EvidenceError` | `unavailable`, `staleEvidence` |
| Receipt rejected | `ToolReceiptError` | Binding against the expectation |
| Mutation blocked / needs host action | `AgentJournalError` | `mutationRequiresReconciliation`, `storeInUse`, `sessionLeaseUnavailable` |
| Scheduler timeout | `ToolSchedulerError` or `AgentLoopError.toolTimedOut` | Lease wait / tool deadline |
| Run budget / deadline | `AgentLoopError` | `invalidBudget`, `deadlineExceeded`, turn/call limits |
| Session contract | `AgentSessionError` | `emptyInput`, `runInProgress`, `durableJournalRequired` (nil or memory journal on a mutation Agent) |
| Future input / dispatch | `AgentFollowUpError` | `inputConflict`, `queueFull`, `dispatchOwned`, `needsInspection`, `durableJournalRequired` |
| Cancellation | `CancellationError` | `AgentFailure.cancelled` |
| Persistence failure | `AgentJournalError.persistenceUnavailable` | Durable journal I/O |
| Unknown or unsupported store | `AgentJournalError.unsupportedLegacyFormat`, `unsupportedFormat`, `invalidHeader` | Open rejects old/unknown formats without creating a new ledger |
| Damaged published state | `AgentJournalError.invalidFrame`, `checksumMismatch`, `invalidRecord` | Stop writes and investigate; never roll back then mutate |
| Uncertain commit | `AgentJournalError.commitUnknown` | The Run owns the startup outcome through drain; reopen and inspect before retry |
| Maintenance pressure | `AgentJournalError.maintenanceRequired` | New mutation admission pauses until maintenance progresses; while a failed rotation is pending, new Run input and follow-up enqueue pause too |
| Maintenance budget smaller than retained data | `AgentJournalError.maintenanceBudgetTooSmall(requiredWorkBytes:)` | Open refuses the store unchanged; reopen with at least that `maxWorkBytes` |
| Settlement and quarantine both failed | `AgentMutationPersistenceError` | `AgentFailure.mutationPersistence`; both sides stay typed |
| Model binding / projected token budget | `AgentModelBindingError` | `AgentFailure.modelBinding`; for example `staleConversationRevision` or `contextBudgetExceeded` |
| Run capability scope | `AgentCapabilityError` | `AgentFailure.capability`; for example `revoked` or `resourceOutsideScope` |
| Context pipeline or projection | `AgentContextPipelineError`, `AgentContextProjectionError` | `AgentFailure.contextPipeline` / `.contextProjection`; for example `staleSummary` |
| Oversized input / projected request | `AgentContextError` | `inputTooLarge` vs `historyTooLarge`. No canonical-history compactor runs. An over-budget projected request fails before provider execution. |
| Programmer / configuration | `AgentLoopError.invalidBudget`, `ToolPolicyError`, `ModelProviderError.invalidRequest` | Construction |

`AgentFailure.unclassified` is a last resort for foreign errors on the event
stream. It does not carry the original payload.

Journal `errorDescription` exists for logs. Recovery and UI branches must switch
on the enum.

Hosts reconcile quarantined mutations with `recoverPendingMutations`, then
`reconcileMutation` or `abortMutation(_:confirmedNoEffect:)` with trusted
no-effect evidence. There is no public API to mark an intent
settled without a validated receipt.

## Provider context overflow

`ModelProviderError.Kind.contextWindowExceeded` (raw value
`"contextWindowExceeded"`) means the provider refused the request because the
prompt does not fit the model's context window. Tell the user the conversation
is too long and offer to shorten it, start a new conversation, or load the model
with a larger context. `AgentContextError` is different: SwiftAgent's own budget
rejected the request before any provider call.

The kind is not retryable: `ModelProviderFallbackPolicy` rejects it in
`retryableKinds`, and `ModelProviderRoute` neither retries nor falls back.
Adapters set it only from these signals, and drop the provider's message:

| Provider | Signal |
| --- | --- |
| OpenAI Responses | `code` `context_length_exceeded` in an HTTP 400 body, an `error` stream event, or `response.failed` |
| LM Studio (Local Responses) | Matched by message, since the code is only `unknown`: HTTP 500 body or `error` / `response.failed` event starting "The number of tokens to keep from the initial prompt is greater than the context length"; older servers' "Trying to keep the first N tokens when context the overflows." |
| llama.cpp server (Local Responses) | Error `type` `exceed_context_size_error` |
| Anthropic Messages | `invalid_request_error` whose message starts "prompt is too long" (HTTP 400 or `error` event) |

Error bodies are read only for HTTP 400 and 500, up to 64 KiB; other statuses,
longer or malformed bodies keep the status classification. DeepSeek and Apple
Foundation Models have no documented signal and are not classified; Anthropic's
successful stop reason `model_context_window_exceeded` remains `StopReason.unknown`.
