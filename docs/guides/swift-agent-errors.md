# SwiftAgent Error Taxonomy

## RC6 candidate: authorization errors

`AgentAuthorizationError` maps to `AgentFailure.authorization` in Run events and
execution reports. Missing audit prerequisites, Host deny/user action,
authorizer failure/timeout, stale or mismatched decision, changed action,
expiry/revocation, backlog and export errors stay typed. Actual store failures
remain `AgentJournalError` (including `commitUnknown`); audit failure never
silently grants execution. Host timeouts/errors are not recorded as deny.
See [Audited Authorization](swift-agent-authorization-audit.md).

last-verified: 2026-09-27

Match errors by type. Do not parse `localizedDescription`.

`run.wait()` throws the original error. `AgentEvent.runFinished(.failed)` carries
`AgentFailure` for the stream. Those cases are constructed by the runtime; clients
switch on them rather than wrapping arbitrary errors themselves.

| User meaning | Type | Typical source |
| --- | --- | --- |
| Model / provider failure | `ModelProviderError` | Adapter `kind` |
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
