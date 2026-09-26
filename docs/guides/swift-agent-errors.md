# SwiftAgent Error Taxonomy

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
| Cancellation | `CancellationError` | `AgentFailure.cancelled` |
| Persistence failure | `AgentJournalError.persistenceUnavailable` | Durable journal I/O |
| Unknown or unsupported store | `AgentJournalError.unsupportedLegacyFormat`, `unsupportedFormat`, `invalidHeader` | Open rejects old/unknown formats without creating a new ledger |
| Damaged published state | `AgentJournalError.invalidFrame`, `checksumMismatch`, `invalidRecord` | Stop writes and investigate; never roll back then mutate |
| Uncertain commit | `AgentJournalError.commitUnknown` | The Run owns the startup outcome through drain; reopen and inspect before retry |
| Maintenance pressure | `AgentJournalError.maintenanceRequired` | New mutation admission pauses until maintenance progresses |
| Settlement and quarantine both failed | `AgentMutationPersistenceError` | `AgentFailure.mutationPersistence`; both sides stay typed |
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
