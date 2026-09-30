# RC6 Audited Authorization acceptance record

last-verified: 2026-09-30

This feature is unreleased. Baseline: `1.0.0-rc.5`, commit
`24447b8298ccea84f9f8056374857c5c47d8f64c`, tree
`f3fbd3297f5b776cbe0ad22681d89ebd2469d3bf`. The branch is
`codex/rc6-audited-authorization`; there was no open competing PR at baseline
inspection. It adds no release/tag, production Host dependency change or user
store migration. See [ADR 0009](../adr/0009-audited-authorization.md),
[Host guide](../guides/swift-agent-authorization-audit.md) and
[中文指南](../guides/swift-agent-authorization-audit.zh-CN.md).

## Reproducible acceptance

Run on a clean candidate checkout with Swift 6.4 / Xcode 27:

```sh
bash Scripts/ci-macos.sh
bash Scripts/ci-concurrency-seal.sh
# The macOS script includes the strict BoundedReplanningProbe, runtime-tools
# public tests, all ordinary regressions and the audit phase below.
bash Scripts/ci-audited-authorization.sh
bash Scripts/ci-apple-provider.sh
```

Linux uses `bash Scripts/ci-linux.sh`. Main CI invokes audit fixture, benchmark
and actual reader comparison after the full test suite, without rerunning that
suite. `.build/ci-logs/audited-authorization-checkout.json` records **actual**
checkout SHA/tree, compiler, run and attempt. The workflow checks out the actual
PR head rather than substituting the merge commit. `.build/ci-logs/` is included
in the macOS/Linux acceptance artifact. Final qualification is attached to the
PR for that head; these development tests do not transfer an older green result
to a newer head. Apple job metadata/check result must be inspected separately.
The additional evidence recording does not claim to fix unrelated CI flakes.

| Boundary | Deterministic evidence / development result |
| --- | --- |
| Missing authorizer, identity or audit-capable store | `AuditedAuthorizationTests`: rejected before history/provider; PASS |
| Allow / deny / user action; archived decision | `AuditedAuthorizationTests`: independent Host count, executor count, live challenge rejection and durable deny reopen; PASS |
| Enterprise allow / domain deny; Evidence not evaluated | `AuditExecutionRegressionTests`: both layers, no intent/executor; PASS |
| Exact material/revision/backend/account/definition/resources | Version-change cases reject previous permission; PASS |
| Corrected redispatch lineage | Fresh proposal/request/digest, original user-action fact unchanged; foreign Session/store lineage refused before provider/input; PASS |
| New Run/Session/store vs old live decision | `AuditBoundaryTests`: old decision invalid, only first executor entered; PASS |
| Read-only, dynamic, notRequired, model approval fields | All invoke Host; no forged permit/Receipt; observed failed read interrupted; PASS |
| Raw vs normalized JSON, concurrent history pairing | Two distinct raw payloads, existing equal normalized semantics, distinct request IDs, paired tool results; PASS |
| Duplicate/oversized model IDs and payload | Runtime invocation IDs distinct; bounded diagnostic, no permit for oversize; PASS |
| Intent/final admission vs revoke/cancel/expiry | Continuation barriers, retained intent and existing confirmed-no-effect API, no automatic abort; PASS |
| Captured raw proposal cleanup / budget or batch rejection | Owned body cleanup until physical exit, explicit notEvaluated/notExecuted for every unprepared instance; PASS |
| Slow authorizer, timeout and late allow | Owned until physical exit; cancelled drain waiter does not release lease/scope; PASS |
| Proposal / decision / application-intent / settlement failure | `AuditCommitFaultTests`: beforeAppend and afterCurrentReplace, counters and reopened root distinguish committed vs not; PASS |
| Commit response loss before or after CURRENT | `AuditPersistenceTests`: poisoned handle, reopen without blind retry; PASS |
| Separate-process denial / settlement / SIGKILL after file effect | `AuditProcessTests`: second executable reads typed facts; pending effect needs reconciliation, observed entry absence is not no-effect proof; PASS |
| Ordinary output imitating authorization JSON | Typed audit remains empty after reopen; PASS |
| Maintenance/GC/restricted payload, indexes/witnesses | Typed facts retained, no invented conversation; removing audit indexes/witnesses throws; PASS |
| Bounded pre-admission rejection coexistence | `AgentPreAdmissionReplanningTests.requiredAudit...`: read authorized, rejected mutation not evaluated, separate invocation, continuation same Run; PASS |
| Query paging/high water/view/filter | Fixed cursor scope, concurrent later facts excluded, no conversation revision advance; PASS |
| ACK loss, partial/duplicate/invalid/late ACK | `AuditExportTests` and stop barrier: prefix only, resend IDs stable, old ACK cannot advance; PASS |
| Export checkpoint failure/reopen | Actual root determines saved prefix, typed commitUnknown retained in status, no lost records; PASS |
| Destination/content/redaction changes; redaction throw | Old position rejected; failing view sends nothing and preserves restricted history; PASS |
| Slow/uncooperative sink and multiple waiters | Stop retains actual owner and Journal lease; late ACK ignored; PASS |
| Export backlog pressure | Reject new input; already admitted mutation still settles; PASS |
| Public SDK integration vs legacy | Separate-package `EnterpriseAuthorizationFixture`: real disposable file effects, human ID, deny/Evidence/changed action/replay/export/reopen; legacy execution unchanged; PASS |

Existing Journal, Capability, Context, follow-up, mutation recovery, Provider
mapping and execution-report tests remain in the full scripts. Their final
status comes from the actual candidate run, not this targeted-test table.
Interleaving tests use barriers/continuations; the timeout case waits on a real
bounded timeout after an entered barrier. Process tests use bounded exit/output
waits. SIGKILL is **not** power-loss validation.

## Actual old/new reader matrix

`Scripts/verify-rc6-compatibility.sh RC5_CHECKOUT CANDIDATE_CHECKOUT` builds the
same external reader source twice against independent SDK revisions.
`verify_audit.py` checks the RC5 SHA, prints both SHA/tree pairs, checks disk
content hashes around rejected operations and runs this matrix (development
run PASS):

| Store | RC5 reader | RC6 candidate reader |
| --- | --- | --- |
| RC5/candidate ordinary schema 3 | Open, append, maintain | Open, append, maintain |
| RC5/candidate rejection schema 4 | Open, append, maintain | Open, append, maintain |
| Candidate empty schema 5 | Reject open/append/maintain unchanged | Open, maintain |
| Candidate typed denial schema 5 | Reject open/append/maintain unchanged | Query typed denial, maintain, query same facts |
| Existing schema 3/4 with requiredAudit | Feature absent | Reject protected Run before provider/input; no migration |

The last row is a runtime test, not an old binary containing the new API.
No automatic migration, downgrade or deduplication transfer exists. New source
adds `AgentFailure.authorization`, requiring exhaustive switches to change;
`AgentTool.authorizationBinding(for:)` has a default but existing same-signature
members must satisfy its public requirement. JournalStore remains package-only.

## Performance and counters

`swift run -c release AuditAuthorizationBenchmark 20` creates disposable local
stores. For each scenario it records Run plus physical-drain milliseconds,
read/written bytes, decoded/encoded/committed batch counts, Host calls and
executor entries. Legacy, automatic allow, deny, 100 unrelated Sessions,
60 prior mutation Runs in one long conversation, and 100 unexported audited
Runs are included. Each scenario then samples 20 new Runs. A new operation and
runtime call are used for each sample; denial has zero executor entries.

Batch encoding counts exclude index encoding, arbitrary Host serialization and
other JSON work. Byte counters include SDK storage operations and maintenance,
not kernel physical-device I/O or remote sink bytes. OS cache is uncontrolled;
these are local finite-workload observations, not a throughput/SLO guarantee.
The benchmark does not promise zero overhead or fixed disk usage.

A preliminary macOS arm64/Xcode 27.1 release-build development sample produced
these totals for 20 measured Runs (with another debug-test build concurrently
active; use final clean CI artifact for qualification):

| Scenario | p50 ms | p95 ms | Read bytes | Written bytes | Encode / commit | Decode | Host / executor |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| legacy | 39.81 | 44.75 | 2,180,679 | 292,443 | 80 / 80 | 591 | 0 / 20 |
| required allow | 183.50 | 1,096.39 | 7,428,210 | 2,145,615 | 180 / 180 | 752 | 20 / 20 |
| required deny | 93.80 | 111.23 | 2,344,965 | 857,645 | 100 / 100 | 171 | 20 / 0 |
| unrelated 100 | 193.50 | 305.39 | 7,678,971 | 2,035,155 | 180 / 180 | 816 | 20 / 20 |
| long session 60 | 168.54 | 201.99 | 7,859,118 | 2,153,648 | 180 / 180 | 765 | 20 / 20 |
| export behind 100 | 160.56 | 181.70 | 7,851,453 | 2,161,538 | 180 / 180 | 754 | 20 / 20 |

The final per-head artifact is
`.build/ci-logs/audited-authorization-performance.json`, generated by the audit
phase. Normal submissions update incremental association indexes; unrelated
Session/history scans are not added by audit. Maintenance and real history growth
still have costs. All typed facts and execution identities are retained by
default, including successfully uploaded facts.

## Deliberate limits and not-run cases

No real enterprise/cloud account, mail service, remote IAM/SSO, production Host,
network export transport, storage migration or release deployment is exercised:
**NOT RUN / outside scope**. The local sink tests exercise the protocol and
receiver fsync/deduplication; they do not certify a Host's future database adapter.
Power-loss, network filesystems, adversarial administrator tampering and a
malicious executor are **NOT RUN / not guaranteed**. The digest detects bound
input/version changes but does not isolate Host code. Host viewing permission,
identity authenticity, security-domain separation, immutable reads/conditional
writes, received policy changes and remote authentication remain Host duties.
Tool authorization does not cover all Provider requests or data egress.

A disk error after admission can still leave an unknown external effect.
Uncooperative authorization/sink work retains owners until real exit. No old
archival approval restores live permission. Uploading is neither execution
settlement nor authorization, and JSONL is not a complete Journal backup.
