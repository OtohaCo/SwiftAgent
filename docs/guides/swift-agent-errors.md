# SwiftAgent Error Taxonomy

last-verified: 2026-09-18

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
| Mutation blocked / needs host action | `AgentJournalError` | `mutationRequiresReconciliation`, `sessionLeaseUnavailable` |
| Scheduler timeout | `ToolSchedulerError` or `AgentLoopError.toolTimedOut` | Lease wait / tool deadline |
| Run budget / deadline | `AgentLoopError` | `invalidBudget`, `deadlineExceeded`, turn/call limits |
| Session contract | `AgentSessionError` | `emptyInput`, `runInProgress`, `durableJournalRequired` (nil or memory journal on a mutation Agent) |
| Cancellation | `CancellationError` | `AgentFailure.cancelled` |
| Persistence failure | `AgentJournalError.persistenceUnavailable` | Durable journal I/O |
| Corrupt journal tail | `AgentJournalError.repairRequired` | Last complete frame invalid; call `discardCorruptTail()` |
| Settlement and quarantine both failed | `AgentMutationPersistenceError` | `AgentFailure.mutationPersistence`; both sides stay typed |
| Oversized input / uncompactable history | `AgentContextError` | `inputTooLarge` vs `historyTooLarge`. Default policy has no compactor, so accumulated history fails closed instead of inventing a summary. |
| Programmer / configuration | `AgentLoopError.invalidBudget`, `ToolPolicyError`, `ModelProviderError.invalidRequest` | Construction |

`AgentFailure.unclassified` is a last resort for foreign errors on the event
stream. It does not carry the original payload.

Journal `errorDescription` exists for logs. Recovery and UI branches must switch
on the enum.

Hosts reconcile quarantined mutations with `recoverPendingMutations`, then
`reconcileMutation` or `abortMutation`. There is no public API to mark an intent
settled without a validated receipt.
