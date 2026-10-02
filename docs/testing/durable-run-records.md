# Durable Run record validation (Issue #75)

The implementation is stacked on Issue #74, without duplicating its identity
format. ADR 0014 defines the admission and terminal boundaries before API tests.
No network, credentials, scheduler, automatic replay or Host business completion
is involved.

| Counterexample / boundary | Deterministic check |
| --- | --- |
| Host prepared; SDK startup has not published | Held startup gate; key query is `notAdmitted`, Provider calls zero. |
| Concurrent duplicate startup | Same actor and replacement Session object return `admissionInProgress`; exactly one Provider request/admission. |
| Same supplied digest, different actual text | `conflict`, before Provider; changing declared digest or operation mode also conflicts. |
| SDK admitted before Host learns Run ID | Actual SIGKILL child; key retrieves original Run/formal message ID. |
| Model checkpoint before terminal transaction | SIGKILL at terminal boundary; reopening returns `admitted`, with final model message. |
| Terminal root published before return | SIGKILL after CURRENT; reopening returns terminal completed by key and ID. |
| Five logical outcome families | Completed/refused/max-output, budget limit/deadline, actual Run cancellation, sanitized Provider failure. |
| Cancelled waiter | Waiter throws CancellationError; actual Run stays admitted, then completes with one request. |
| Slow noncooperative executor | Logical cancellation/deadline queryable while close still fails for owned lease; bounded gate then drains. |
| Terminal publication error/commitUnknown | Definite failure remains admitted; unknown store throws, reopening reads committed terminal. No retry. |
| Retained steering failure | Definite failure terminal is failed(journal); unknown store is poisoned and receives no terminal append. |
| Audit proposal/decision/application/settlement failures | Both old and Run-record stores; no false completion or unearned permission; existing pending/settled effects preserved. |
| Trusted settlement after terminal | Cancelled mutation executes once; Host verifies the real file and reconciles; cancelled fact remains unchanged through maintenance/reopen. |
| Settled mutation + terminal failure | Both per-call and operation modes: one actual file effect, no pending, duplicate admission on reopen never executes again. |
| Corrupt published indexes | Delete admission/correlation/terminal/message files: key and ID throw invalidRecord, never absence. |
| Pack/maintain/reopen | Rotated segments, maintained index and formal message IDs still match. |
| Follow-up queries | Both identities; query before dispatch makes zero requests; Run ID lookup after dispatch/reopen preserves input link. |
| Session isolation | Same key in two Sessions; cancelling/querying one does not change the other terminal. |
| Unavailable storage | Memory/old format throws unsupportedFormat, closed throws storeClosed, poisoned throws commitUnknown. |
| Offline Host decision | Public RunRecordFixture queries cancelled read-only work, then Host creates a distinct new Run; old fact unchanged. |

Tests are in `AgentRunRecordTests`, `RunRecordProcessTests` and the extended
`AuditCommitFaultTests`. Synchronization uses controlled async continuations and
bounded observations. Deliberate crash parking happens only on the owned I/O
queue of a child process that the test SIGKILLs; it does not block a shared
cooperative executor.

TDD evidence: the initial public API probe failed to compile without these
interfaces (`/tmp/swiftagent-75-red.log`). A deliberate mutation omitting exact
text from the SDK fingerprint made both different-text conflict assertions fail
(`/tmp/swiftagent-75-mutation.log`), incorrectly reporting alreadyAdmitted. The
binding was restored and the tests passed. One new startup fault fixture first
armed before store creation and therefore injected into format initialization;
it now arms immediately before Run startup to test the intended boundary.

`Scripts/verify-run-record-compatibility.sh` builds the actual immutable schema-8
SDK at d3a8ef964aecd440934d51b7cd00f6552fe22002, without modifying its sources.
The new reader preserves schema-8 per-call input but explicitly rejects Run
queries on it. The old reader rejects empty and populated schema-9 stores for
open/append/maintenance, both before and after new maintenance. File digests
prove rejected operations did not erase facts. New key/ID terminal queries
continue to agree after maintenance. Existing schema-3–7 compatibility remains
covered by the earlier matrix.

Local platform commands: `bash Scripts/ci-macos.sh`,
`bash Scripts/ci-concurrency-seal.sh`, `bash Scripts/ci-apple-provider.sh`.
The portable Linux script runs on the corresponding CI runner, not on this
macOS workstation. Acceptance must name the actual commit, event, attempt and
jobs; an earlier green commit is not evidence for this patch. Public fixtures
do not certify a live skill_run, compiler task, remote service, travel workflow,
automatic Host recovery or OAI-319 integration.
