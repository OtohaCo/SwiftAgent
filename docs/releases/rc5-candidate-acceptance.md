# RC5 candidate acceptance record

This record describes the RC5 candidate. It runs from the immutable RC4 tag
(`1.0.0-rc.4` → `3f01599ef3d0923659226025a7d34d4144ed1800`) to the
release-metadata commit on `main`.

This file is part of that commit, so it cannot record that commit's own
results. The GitHub Pre-release records the final commit, its tree and the
gate results. No PR's green checks count as final-main approval.

## Changes in scope

| PR | Merge | Content |
| --- | --- | --- |
| #26 | `45260a2` | Tests-only RC4 baseline and strict probe for bounded correction |
| #27 | `837748f` | Opt-in bounded pre-admission replanning; schema-4 capable stores |
| #28 | `27d10df` | Offline-first replanning evaluation runner (dry-run only) |
| #29 | `3f0b05f` | Tools defined at runtime (`AgentTool.definition`, `RuntimeAgentTool`) |
| #30 | `74a6f56` | Pending-operations index, maintenance budget, symlinked create, checkpoint adoption, typed failures |
| #31 | `dfdfe6c` | Runtime-tools public API regressions (ExternalClient) |
| #32 | `5591bc7` | Route continuation isolation |
| #33 | `0400fb8` | Retained steering durability; closing gate for follow-up work |
| #34 | `5ddb19b` | Rotation publication, backpressure and open-budget bounds |
| #35 | `6433d2d` | Writer lock close-on-exec, with a spawn-path regression |
| #36 | `7b0c2aa` | Execution-reporting CI logs, per-case timeout and evidence upload |
| #37 | `2fd63e2` | Bounded child waits in `FollowUpProcessTests` |
| #38 | `f5a73e0` | Rotation backpressure test waits for the faulted maintenance pass |
| (this PR) | release metadata | RC5 release note, CHANGELOG, versioning, README and this record |

For each merge-queue step:

- the PR head was locked with `--match-head-commit`;
- every hosted job's actual checkout was checked against the push head and
  the `refs/pull/N/merge` commit, with the tree of each checkout.

Where a PR was not re-synced after an earlier merge, its changes are disjoint
from that merge: #37 and #38 change only test files. The combined result is
qualified only by the final-main gates.

## Defects confirmed in this wrap-up

- **Writer-lock inheritance (#35).**
  - A deterministic test holds the store, starts a long-lived child, closes
    the store and reopens it from an independent process. It checks the
    child's descriptor table.
  - Before the fix, on hosted macOS and Linux (run 36533684174): a
    `posix_spawn` child with default attributes held `.writer.lock`, and the
    reopen failed with `storeInUse` (exit 42). A Foundation `Process` child
    did not hold it.
  - After the fix (runs 36534196156 and 36534218664), both launch paths
    report `not held` and reopen with status 0.
- **Rotation backpressure test race (#38).**
  - `requestMaintenance()` joins a running automatic pass, so it can report
    a fault that pass saw before the test cleared the fault.
  - A scratch probe reproduced this deterministically. The fix changes the
    test only.

## Attributed, not fixed

- **Transient `storeInUse` while spawning ([#47](https://github.com/OtohaCo/SwiftAgent/issues/47)).**
  - A child copies the parent's descriptor table while it is being spawned,
    until it execs.
  - On macOS, with four spawning threads, 45 of 3000 immediate reopens were
    refused. With no spawners, 0 were refused.
  - This explains the `storeInUse` failures seen under
    `swift test --parallel`, both before and after #35. CI runs with
    `--no-parallel`.
  - The refusal is fail-closed and nothing is leaked. It is documented as a
    limitation.

## Failure and rerun history (not counted as passes)

Hosted macOS jobs reached the 30-minute limit and were cancelled in these
runs:

| Commit | Run | Result |
| --- | --- | --- |
| `4c4f210` (PR) | 36423949258 | cancelled |
| `345bf35` (push) | 36424100142 | cancelled |
| `27d10df` (main) | 36509900742 | cancelled |
| `ebc6097` (PR) | 36514073035 | cancelled |
| `a35c19a` (#32) | 36522549914 | attempt 1 cancelled; attempt 2 passed |
| `e73727c` (#33) | 36523224955 | cancelled |
| `0400fb8` (main) | 36527345995 | cancelled; not rerun, superseded |
| `5ddb19b` (main) | 36528840034 | attempt 1 cancelled; attempt 2 passed |

- **Hosted Linux segfault.** #33's run 36523229250 segfaulted once in
  `ExecutionReportingSupportTests`.
- **Local hang.** A local full gate on `837748f` hung in `FollowUpProcessTests`
  and was terminated.
- **Status.** These remain unattributed
  ([#45](https://github.com/OtohaCo/SwiftAgent/issues/45),
  [#46](https://github.com/OtohaCo/SwiftAgent/issues/46)).

One round-3 probe rerun ran stale `dfdfe6c` code under a newer name. Its log
is kept with an INVALID label and is not used as evidence.

## Gates for the final release commit

Run these on a clean checkout of the fixed final SHA:

- `bash Scripts/ci-macos.sh` and `bash Scripts/ci-concurrency-seal.sh`;
- `swift run --package-path Examples/ExternalClient BoundedReplanningProbe`,
  which must exit 0;
- `RuntimeToolPublicAPITests` (ExternalClient);
- `WriterLockLifetimeTests` and `FollowUpProcessTests`;
- `bash Scripts/verify-pr27-compatibility.sh` against an RC4 checkout, for
  the reader matrix;
- hosted macOS, Linux and Apple jobs on the exact commit, with each job's
  checkout verified;
- a public SwiftPM consumer with no credentials and an empty cache, pinned to
  the revision and then to `exact: "1.0.0-rc.5"`. It resolves, builds and
  runs with a temporary store.

Every attempt is reported, including failures. A timeout or crash is not a
pass, and a rerun does not replace the failed attempt in the record.

## Not run or not claimed

- Paid live Provider requests.
- Real-model replanning evaluation.
- A production Host dependency update.
- User-store migration.
- OS sandbox qualification.
- Power-loss testing.

The only live evidence is a local LM Studio check with `qwen/qwen3.8-27b`: 6
ProviderQualification cases and 10 requests, on `5ddb19b`. The
[release note](1.0.0-rc.5.md) states its exact scope.
