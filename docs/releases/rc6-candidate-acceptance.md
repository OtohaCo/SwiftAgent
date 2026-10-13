# RC6 whole-candidate acceptance

Status: **earlier SDK scope accepted; #110 final-source acceptance and renewed publication gates recorded separately**.
Earlier SDK main `adc14bda5652ef5c61e4e934429c7736249cc1f6` / tree
`caa703b9ffa539db78b40d9fbf76627071e2ef31` has the same tree as PR #107's reviewed
head `7e565b5df1c1d9e60177cd2fb7b96539956d7c15`.
[Actual-main CI 38243487509](https://github.com/OtohaCo/SwiftAgent/actions/runs/38243487509)
passed Linux/macOS/Apple on the first attempt. Downloaded 60 clean exact-source
stage records (Linux 35, macOS 25), actual reader/reporting/seal logs and final
tree equality were independently reviewed:
[whole-candidate final report](https://github.com/OtohaCo/SwiftAgent/pull/107#issuecomment-6124095848).
It covers initial RC6/#98 plus #99/#101/#103, diagnostics #106 and approved #105
first scope. PR #107 was merged at the user's instruction while CI was pending;
its final head and main successes completed afterward, not before merge.

The documentation-only release-seal PR #109 merged as
`c0085211a176812c4c43723b5ed3851553ebb9e7` / tree
`98ad2df931c9cc1f095b564456b23a558f7633f0`;
[actual-main CI](https://github.com/OtohaCo/SwiftAgent/actions/runs/38382913379)
passed all Linux/macOS/Apple jobs on first attempt (60 exact-clean stage records,
actual reader/reporting/seal checks), and its anonymous cold revision consumer
passed. Before any tag/Release, the Host paused publication to add #110.
See [#110 scope/RED/GREEN](issue110-acceptance.md) for the new implementation.
Its new publication commit must pass independent review, applicable PR/main CI
and a fresh anonymous revision consumer;
the immutable annotated tag must pass tag CI and an exact-version public consumer.
The [GitHub Pre-release](https://github.com/OtohaCo/SwiftAgent/releases/tag/1.0.0-rc.6)
records the actual tag object/target/tree, publication time and final gate results
once published. No source page predeclares those results or a release date.

The initial closeout provenance below is historical. Subsequent merged native
context, #101 and #103 changes are covered by their linked acceptance records;
#105 first scope is in [PR #107](https://github.com/OtohaCo/SwiftAgent/pull/107),
with [its complete scope/evidence](issue105-acceptance.md). Actual main
`8b896eae05b5fd838e61e67a6cb69ca7c0e78458` / tree
`3c34571d48d65e6020434bc0e60d0bc794fed149` had macOS/Apple success but failed Linux
build CI [38229615849](https://github.com/OtohaCo/SwiftAgent/actions/runs/38229615849).
Diagnostic PR #106 merged as `d1834ebb686dbcd467e7b07641867f3ca904750e` / tree
`2d23d68b20ca7137a8f0d1f788b1f1dae3cce9a2`; its source PR/push checks passed, and
that new main's [CI](https://github.com/OtohaCo/SwiftAgent/actions/runs/38235773977)
passed all three jobs (exact clean-source Linux/macOS artifacts checked). This
is diagnostic-main acceptance; #105 final-main acceptance is linked above. Do not infer release
readiness from a historical green run. Final PR/main identities and outcomes
are recorded in the corresponding acceptance comments.

This page covers the whole RC5 → RC6 delta; the existing audited-authorization acceptance page
qualifies only its own historical scope. Publication is a separate release step.

## Provenance

| Role | SHA / tree / evidence |
| --- | --- |
| RC5 tag target | `24447b8298ccea84f9f8056374857c5c47d8f64c` |
| Starting actual main | `c07678292f515fdeb46f77c13ff611d278430ef7` |
| Starting main tree | `c26e6c3c8daed7e809e50b76ecfdf132bdea3005` |
| Historical baseline CI | [38057389035](https://github.com/OtohaCo/SwiftAgent/actions/runs/38057389035), success; does not certify RC6 |
| Development branch | `fix/rc6-candidate`; initially clean worktree |
| Tested source | `5ebbcb94be868a3d43578a1d0f97a11fb382b7b1` |
| Tested source tree | `81196a8e232d6c6c993f8404055e736ed01be7bb` |
| Acceptance documentation / PR head | This later documentation-only commit; exact head is recorded by [PR #98](https://github.com/OtohaCo/SwiftAgent/pull/98) checks |
| Source PR CI | [38148095076](https://github.com/OtohaCo/SwiftAgent/actions/runs/38148095076), launched for tested source; complete result must be checked |
| Source push CI | [38148091538](https://github.com/OtohaCo/SwiftAgent/actions/runs/38148091538), same source; complete result must be checked |
| Initial #98 merged main / CI | `34103af09baf0ecadfb27389803126ad0dd8f4ac`; [38153566812](https://github.com/OtohaCo/SwiftAgent/actions/runs/38153566812), passed; [historical attestation](https://github.com/OtohaCo/SwiftAgent/pull/98) |

Local environment: macOS 27.2 arm64, Xcode 27.0 (27A266a), SDK 27.0,
Apple Swift 6.4 (`swiftlang-6.4.0.34.1`, clang `2100.3.34.1`). Linux and
Apple-hosted validation are recorded independently from local macOS. New paid
live calls are **NOT RUN / NOT AUTHORIZED**. Constructed signatures and mocked
responses establish local policy only, never provider cryptographic validation.

## Findings and evidence

### Stale persistent Session baseline

The required sequential schema-3 scenario is tested with both a different next
input and byte-identical next input. Per-session history heads, rather than
actor conversation revisions or global maintenance versions, witness the
persistent baseline. The witness must be captured with restoration, checked
before projection/admission, and checked in startup publication. A stale actor
is rejected with `AgentJournalError.concurrentWriter`; the Host drains the old
Run and creates a fresh Session on the same Journal handle. Reconciliation
never rewrites an old Run's logical terminal or replays its mutation.

RED: `swift test --disable-sandbox --filter StaleJournalBaselineTests` against
baseline production code failed with 8 issues, including Provider input `three`
while Journal retained `two` + the new assistant answer. The identical `two`
input was also incorrectly admitted. GREEN: final focused command passes 3
tests / 6 cases: default schema 3 and Run records, distinct/identical text,
fresh actor + reopen, unrelated writes/maintenance, and a post-preflight
publication race. Stale rejection leaves correlation lookup `notAdmitted`.
The complete gate supplies existing tool-tail/mutation/no-effect/queue coverage.

### Anthropic final HTTP body and preserved thinking

The final encoded JSON body, including base64 images, escaping, system,
history and schemas, is checked before transport. Native image raw-byte
selection is independent of that bound. Swift encoder / HTTP fixture measurements:

| Body | Final bytes | Transport after fix |
| --- | ---: | ---: |
| Valid 8 PNGs, 24 MiB total raw | 33,555,209 | 0 |
| Valid 7 PNGs, default 20 MiB raw + 6M system text + tool schema | 33,962,859 | 0 |
| Image/text/system/schema/structured-output mixed boundary | 32,000,000 | 1 |
| Same mixed body + one byte | 32,000,001 | remains 1; new request rejected |

PNG fixture has a complete valid image, legal ancillary chunk/CRC and macOS
ImageIO decode. Single-image limits and total image counts are legal. Initial
RED: 3 tests / 11 issues; oversize requests and changed-tools thinking replay
entered transport. Final GREEN:
`swift test --disable-sandbox --filter 'Anthropic|ImageContentProvider'` passes
34 tests / 8 suites. MB is conservatively decimal because the official page
states 32 MB without defining the conversion.

Signed-thinking compatibility follows the local conservative policy documented
in the Anthropic guide. Fixed append-only native continuation passes. Actual deferred expansion fails
the next request with executor count 1 / transport count 1, preserving the
committed tool result on reopen. A subsequent Run restoring initial declarations
is refused before admission (history unchanged, executor 1 / transport 2).
Prior tool-result excerpts, old-history summaries and missing legacy witnesses
are refused; unsigned paths remain accepted. Current service/model/
account live qualification is not claimed.

### Context and external Host contract

The public ContextPipelineFixture uses a fixed projector object/binding whose
source-correct view changes on each new model round. Core validates source
coordinates, pairing, continuation and budgets; the Host does not certify its
own output. Preflight is reused for the first round. Cancellation ignores late
projection results for dispatch but waits for physical ownership to drain.
Canonical history and tool results survive close/reopen unchanged.

No automatic summary service, dynamic source-preparation interface or new
budget metadata API is inferred from this fixture. Built-in summaries/excerpts
remain preprepared and scoped to supported old closed history; reopened
read-only effect proof cannot come from a same-name current registry entry.
`swift run --package-path Examples/ExternalClient ContextPipelineFixture`
passes the dynamic/public/cancellation/reopen path and existing prepared summary,
read-only excerpt and final budget assertions. Same fixed projector sees two
sources and is invoked exactly twice for two requests; tool execution counts
remain one per Run. Cancellation during the second projection returns
CancellationError and no second Provider dispatch. Exact dynamic and cancelled
histories match after close/reopen. No @testable access is used by this consumer.

### Final-answer publication across deadline (#97)

A real File Journal publication barrier holds the final checkpoint across the
original deadline; release, wait, physical drain and close/reopen verify a
single preserved answer with consistent Run records. Definite failure and
commitUnknown must remain failures. No-answer timeout, steering reentry and
tool deadline behavior retain their existing gates.
`swift test --disable-sandbox --filter AgentSettledAnswerDeadlineTests` passes
6 tests, including 4 barrier/deadline/cancellation/Run-record combinations and
2 definite/unknown fault cases. Independent review found the first test held `afterCurrentReplace`, which only
proved delayed return. That P2 acceptance gap was corrected to
`beforeCurrentReplace`: Provider first checks the user-only checkpoint and
captures CURRENT; the test confirms entry before deadline and CURRENT remains
unchanged after deadline, then releases actual publication. The amended 6-test
suite passes with all 4 combinations and 2 failure cases. Prior wrong-barrier
logs are retained but are not final landing evidence. No new #97 runtime defect
was found; this is contract evidence, not an expanded timeout gate.

## Complete gates and independent review

Read commands from the repository scripts. Local full applicable gate:
`bash Scripts/ci-macos.sh`, `bash Scripts/ci-concurrency-seal.sh`, and
`bash Scripts/ci-apple-provider.sh`. The main script already executes audit,
reader/RC6 compatibility, per-call/Run-record/image readers, external consumers
and ProviderQualification; those are not redundantly certified by old runs.
Linux uses `Scripts/ci-linux.sh` and the five-attempt finite reporting
reproduction defined in `.github/workflows/ci.yml`. Failures are retained and
bounded follow-ups require an attributed reason; a cancelled attempt is not a
pass.

Final diff and real test result reviews are separate from implementation:
Session/Journal/admission/recovery; Provider/body/thinking; and runtime/context/
public API/docs. Core history was reviewed independently by the runtime/context implementer;
Provider changes by the history implementer; runtime/public fixture/docs by the
Provider implementer. Final source/tests and the actual targeted results are
reviewed, not only the proposed design. Final source seal:
`5ebbcb94be868a3d43578a1d0f97a11fb382b7b1` /
`81196a8e232d6c6c993f8404055e736ed01be7bb`. No unresolved P0/P1 or
release-blocking P2 remains in reviewed scope. The #97 P2 correction above is
recorded explicitly. [Focused logs and three review records](rc6-evidence/README.md)
retain failures, corrections and results.

Retained initial failures: a bounded interrupted SwiftPM planning attempt
(without --disable-sandbox; no RED claim), real stale/body/thinking RED, and a
new fixture missing-try compiler failure. The compiler failure was corrected
before the final focused GREEN; no runtime gate was weakened. Local raw logs
are retained in `.ci-logs/rc6/`, with sanitized focused copies in `rc6-evidence/`; hosted full gate artifacts preserve their own
SHA/tree/toolchain/command/exit metadata.

## Issues, limits and release separation

| Issue | Candidate disposition |
| --- | --- |
| #65 | Large ordinary no-effect fixed by #67; current complete tests pass, close with merge/evidence |
| #66 | In-process recovery docs/public comment and stale admission contract complete; close with merge/evidence |
| #47 | Default fail-fast + opt-in bounded async lock wait; OS window persists, keep open |
| #44 | Selected retry/diagnostic/pagination fixes merged; accumulation work deferred, keep open |
| #45 | Historical macOS timeout attribution unknown; keep open, preserve failures |
| #46 | Linux planner root cause unknown; narrow native workaround, keep open |
| #60 | Native Decisions protocol blocked; separate task, keep open |
| #61 | Jev full response allocation unbounded by runner limit; separate task, keep open |
| #86–#89 | Closed implementation/deployment evidence retained; no new paid requalification |

Provider local support does not equal paid live qualification. Historical cache
qualification in #89 is endpoint/account-specific; current thinking mode and
new signed-prefix checks have no new live proof. See the
[release notes](1.0.0-rc.6.md), versioning and provider guides for API, format,
reader and runtime compatibility.

OtohaAI follow-up: pin this accepted SDK only in a separate task; configure
Host-owned summaries/thresholds/model/cost/cache versioning, handle local
rejections and fresh actors after reconciliation, then qualify product UI and
end-to-end recovery. This delivery changes SwiftAgent only.

Local complete gates all passed with exit 0 on the exact tested source, clean
tracked workspace: `ci-macos.sh` (19 stage records, plus original report and
reader gates), `ci-concurrency-seal.sh` and `ci-apple-provider.sh` (20 fixture
tests). [Local stage identities/results](rc6-evidence/local-stage-results.json)
record commands, compiler and source SHA/tree. Existing large no-effect and
capacity/disk suites passed; no new service qualification was run.

Release conclusion: **SDK implementation, focused regressions, complete
actual-main acceptance and independent review are complete** at the final SDK
main identified above. The historical provenance remains intact. The subsequent
documentation-only publication commit, tag CI and anonymous consumers require
separate exact identities and results, recorded in the release-seal PR and GitHub
Pre-release. SDK acceptance, publication and OtohaAI integration are distinct.
