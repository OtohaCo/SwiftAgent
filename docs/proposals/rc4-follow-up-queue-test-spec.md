# RC4 durable follow-up queue: acceptance and fault specification

Status: acceptance specification with active regression coverage on the RC4
queue branch. Final counts/benchmarks must be tied to the PR's exact head;
the initial parent PR #20 and PR #21 are integrated in `main` at
`44e48f0783be0c467d45ac4b7d9f98c42e01718e`; this is the implementation
baseline described in [ADR 0007](../adr/0007-durable-follow-up-queue.md).
Use synthetic inputs,
temporary stores/files and fixture Providers; no live credentials or real
business mutation. A `SIGKILL` test proves process-termination recovery only,
not power-loss durability.

`Tests/AgentCoreTests/AgentFollowUpQueueTests.swift` exercises indexed
enqueue/dedup/conflict/capacity, FIFO, schema-1/schema-2 rejection, the atomic startup
boundary, both publication outcomes, withdrawal races, fresh scopes, resolver
cancellation/drain, concurrent mutation settlement and maintenance interleaving.
`Tests/AgentJournalFileStoreTests/FollowUpProcessTests.swift` terminates a child
with `SIGKILL` **after** its real temporary-file mutation writes, then checks
the persisted admitted link and unresolved intent without replay. The
credential-free `FollowUpQueueFixture` is an external public-API consumer.

## Reference model and measured facts

Use a small pure in-memory model keyed by `(storeID, sessionID, inputID)` to
compare admissible event traces. Track the persisted queue ordinal, payload,
state and Run/formal-message association separately from actual Run outcomes.
Generate deterministic interleavings and crash points. Every assertion should
distinguish these counters:

| Fact | Instrumentation | Must not be inferred from |
| --- | --- | --- |
| Received | successful queue publication / same-ID lookup | HTTP/Host response |
| Admitted | one published `queued → admitted` + startup frame | resolver returning |
| Provider requests | fixture transport log | Run construction |
| Executor entered | first statement of real temp-file tool | admission ticket or tool proposal |
| External writes | file contents/length after close/reopen | executor entry or model text |
| Trustworthy settlement | Journal receipt/output + paired formal result | ordinary executor return |

For baseline traces, `received=1, admitted=1, formal input=1` after successful
dispatch; a repeated same-ID enqueue leaves all three unchanged. A withdrawn
item has `received=1, admitted=0, Provider=0, executor=0, writes=0`. A
published intent followed by revoke before executor entry has `admitted=1`
for the queue item, `executor=0, writes=0`, and retains the Journal's existing
unsettled/reconciliation responsibility. A settled replay under a newly
approved scope leaves the file-write count at one.

## Deterministic matrix

1. **Accept and FIFO.** Two callers enqueue concurrently under a held store
   publication barrier. The committed queue ordinals, not arrival timestamps
   or resolver completion order, determine dispatch. Verify A/B Session
   isolation, same `inputID`/same semantic payload replay, same ID/different
   text/operationID/configurationRef conflict, empty/oversized input and
   128-count/8-MiB capacity rejection without eviction. Keep terminal IDs
   queryable after extensive maintenance.
2. **Receive publication.** Inject failure before frame append, after append
   before index sync, before `CURRENT` replace, and immediately after replace
   or directory sync uncertainty. Test definite nonpublication, `commitUnknown`
   with safe stop, and recovery by reopening/querying the same ID. Simulate
   response loss after a confirmed commit; same-ID retry returns one item and
   original ordinal. Read-only opening/permission/ENOSPC errors never return an
   empty queue or fall back to memory.
3. **Atomic Run handoff.** Pause between resolver completion, Session
   reservation, preflight and the combined startup publication. At each
   fault point kill an isolated child or inject a deterministic store fault,
   then reopen: exactly one of `queued` with no formal input, or `admitted`
   with its original Run ID and exactly one matching formal user message ID.
   A corrupt committed frame/root fails explicitly. An admitted item without
   a live Run stays interrupted/needs Host action; no second Run appears on
   dispatcher restart. Ensure the `commitUnknown` path still constructs an
   owned failed Run and retains the lease through physical drain.
4. **Withdraw race.** Block a resolver and race withdrawal before startup;
   release it and prove `withdrawn` wins with zero Provider requests. Repeat
   with admission already published: withdraw returns `alreadyAdmitted(runID,
   formalMessageID)`, and cancellation uses `AgentRun.cancel`. With the store
   barrier parked immediately before/after publication, ensure only one
   side wins. Unknown publication is queried, never guessed.
5. **Rebind current authority.** Enqueue only a configuration label; revoke
   the earlier capability and change model/context versions before dispatch.
   The resolver must produce a fresh same-Session binding; a returned old
   scope/generation, mismatched Session, stale conversation revision,
   over-budget context, disallowed resource or missing durable Journal fails
   before Provider/executor and pauses dispatch. No default-tool or credential
   fallback. A queued text/Skill reference is not Evidence or authorization.
   Resolver timeout starts from dispatch preparation; no persisted
   `ContinuousClock.Instant` is accepted on reopen.
6. **Resolver ownership.** A cooperative resolver's cancellation handler fires
   when paused/stopped. An uncooperative resolver records cancellation but
   waits behind a continuation; `waitForDrain`, Session identity and
   `journal.close` do not complete prematurely. Releasing that continuation
   discards its late result using attempt generation. Two independent waiters
   see the same drain; cancelling one does not cancel cleanup. A resumed
   dispatcher has a new attempt identity and cannot accept a predecessor's
   response.
7. **One consumer / direct Run conflict.** Two dispatchers for one Session
   and store race at a barrier: exactly one claims the head. Direct `run` while
   dispatch owns that Session returns `dispatchOwned` before changing history,
   even if the dispatcher is paused. Another Session sharing the Journal and
   scheduler can run; direct Run and dispatch do not perform separate
   optimistic active-Run checks. No polling `runInProgress`/sleep loop.
8. **Physical drain and halt conditions.** Keep a tool executor, projector or
   estimator blocked *after* logical Run termination. The next queued item
   has zero Provider calls until actual drain. After `.completed` + drain,
   advance one head. For refusal, incomplete, error, cancellation,
   `commitUnknown` and recovered uncertainty, assert no later admission;
   pending entries remain. `pause` leaves the current Run alone; `cancelCurrent`
   delegates to it; `stop` owns the resolver until it exits. Paused/stopped
   drain does not wait for the whole backlog. `journal.close()` succeeds only
   for a sole-user store after the dispatch claim, resolver and Run release;
   it rejects close while another Session is still active.
9. **Concurrent receipt and enqueue.** Block an active Session's tool result
   checkpoint or trusted mutation settlement, then enqueue a follow-up for
   that Session and another Session. Both publications succeed or fail for
   their actual reason: queue-only writes cannot bump conversation revision
   or create a false stale-Session conflict. Reopen and verify stable formal
   message IDs, call/result pairing, trusted receipt/replay output, current
   context projection revision and untouched mutation identity.
10. **Maintenance and process restart.** Rotate/pack/GC through small test
    thresholds across queued, withdrawn and admitted records. Check every
    `inputID` index, FIFO ordinal, queued body and admitted Run/message link
    before/after. The store must actually reclaim obsolete process files
    without deleting these facts. Terminate a child during receiving and
    startup publication, reopen in another process, and verify the same
    admitted-versus-queued split and mutation no-replay. Do not call this a
    power-loss test.

Use the existing `AgentContextSourceReferencing` and scope/Run cancellation
fixtures to guard #20/#21 semantics. A supplied `onRun` callback receives the
actual queued Run and owns its single `AgentRun.events` consumer; headless
dispatch consumes and discards bounded progress. The dispatcher waits on
`run.wait()` and `waitForDrain()` without competing for that stream. The public
ExternalClient regression feeds the Host stream into `ExecutionReportReducer`
and verifies that a presentation error cannot erase the tool's Receipt. Assert the
Host's domain-fulfillment result separately from Runtime completion.

## ExternalClient executable acceptance

A new no-key executable in `Examples/ExternalClient` uses the public API and a
real temporary Journal: while the first Run is physically active, enqueue
three stable IDs (two to process and one to withdraw); stop/pause and close
with one item queued; reopen, observe it still queued without a Provider
request; explicitly start a fresh resolver/capability binding and verify FIFO
dispatch. In a second scenario, the first dispatched item makes a real
temporary-file mutation; crash/reopen/retry with its original `operationID`
must never write twice. Print independent received/admitted/Provider/executor/
write counts. Fixture model responses are deterministic, not a live Provider
qualification.

## Performance and final gate

Use Release, fixed fixture seed and final SHA/toolchain/hardware. Measure:

| Growth axis | Read/decoding and write expectation |
| --- | --- |
| One Session: many queued/terminal IDs, small current conversation | Small enqueue and one paged head lookup touch bounded index/tail, not all queue bodies. |
| Other Sessions: many queued IDs, current Session small | Current Session receive/lookup does not decode others' payloads. |
| Active Run + concurrent enqueue | Queue-only batch writes input delta, preserves conversation revision and tool settlement latency; include lock wait. |

Record new-process open/head query, queue receive and atomic handoff latency
distribution, bytes read/decoded/written, maximum unmerged tail, maintenance
time/reclaimed bytes and peak RSS. State OS page-cache limitations and include
maintenance in amortized cost; a one-off example time is not a performance
claim. Show exact storage metrics and indexed read ranges rather than claiming
all operations O(1).

On a **clean checkout of the final implemented SHA**, run
`bash Scripts/ci-macos.sh`, `bash Scripts/ci-concurrency-seal.sh`, the new
queue/fault/process suites, Journal/Context/Capability regressions, the
ExternalClient executable and Provider fixtures. Verify hosted macOS, Linux
and Apple push/PR jobs by *actual checkout SHA and tree*, not workflow
`head_sha`. If the integrated base or queue code changes after testing, rerun
the affected gates. Even a complete fixture matrix does not claim live
Provider, network filesystem, power-loss or OS sandbox qualification.
