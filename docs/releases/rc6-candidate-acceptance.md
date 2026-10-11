# RC6 whole-candidate acceptance

Status: **prepared candidate; acceptance in progress**. This page covers the
whole RC5 → RC6 delta; the existing audited-authorization acceptance page
qualifies only its own historical scope. No tag or GitHub Release is created.

## Provenance

| Role | SHA / tree / evidence |
| --- | --- |
| RC5 tag target | `24447b8298ccea84f9f8056374857c5c47d8f64c` |
| Starting actual main | `c07678292f515fdeb46f77c13ff611d278430ef7` |
| Starting main tree | `c26e6c3c8daed7e809e50b76ecfdf132bdea3005` |
| Historical baseline CI | [38057389035](https://github.com/OtohaCo/SwiftAgent/actions/runs/38057389035), success; does not certify RC6 |
| Development branch | `fix/rc6-candidate`; initially clean worktree |
| Tested source / tree | Pending final source commit |
| Acceptance documentation / PR head | Pending final head |
| PR CI | Pending |
| Actual merged main / tree / CI | Pending; not yet merged |

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
2 definite/unknown fault cases. No new #97 runtime defect was found; this is
additional evidence and contract documentation, not an expanded timeout gate.

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
reviewed, not only the proposed design. Findings and disposition will be
attached to the final head before merge.

Retained initial failures: a bounded interrupted SwiftPM planning attempt
(without --disable-sandbox; no RED claim), real stale/body/thinking RED, and a
new fixture missing-try compiler failure. The compiler failure was corrected
before the final focused GREEN; no runtime gate was weakened. Local raw logs
are retained in `.ci-logs/rc6/`; hosted full gate artifacts preserve their own
SHA/tree/toolchain/command/exit metadata.

## Issues, limits and release separation

| Issue | Candidate disposition |
| --- | --- |
| #65 | Large ordinary no-effect fixed by #67; verify merged tests before closure |
| #66 | In-process reconciliation docs and fresh-Session contract; close after merge/evidence |
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

Release conclusion: **not yet ready; final implementation, independent review,
exact-head complete CI and actual-main CI remain required**. Merging main,
completing candidate acceptance and creating tag/Release are distinct steps.
