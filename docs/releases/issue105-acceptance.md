# Issue #105 first-scope candidate acceptance

Status: prepared, unreleased. This is an SDK candidate, not OtohaAI integration
or product end-to-end qualification. No tag/Release or paid live calls.

## Identity and scope

Baseline main `8b896eae05b5fd838e61e67a6cb69ca7c0e78458`, tree
`3c34571d48d65e6020434bc0e60d0bc794fed149`, PR #104. Actual main CI
[38229615849](https://github.com/OtohaCo/SwiftAgent/actions/runs/38229615849)
passed macOS and Apple; Linux exited 139 in `core-build-AgentTools` before
running tests. No attribution to an SDK runtime bug or full-main success follows.
The diagnostic-only [PR #106](https://github.com/OtohaCo/SwiftAgent/pull/106)
records real stack availability and verifies hosted debugger attachment; it does
not claim to repair the upstream planner crash.

Storage source `b336cd505eb56de2d848759c38adc176d8b23a42`; runtime/tests/docs source
`dd5317efe38982e33d1bef84cd984295200ad6cc`, tree
`1be36e1ab8fed70b938b0f4713e6c8fc24f4fa55`.
[PR #107](https://github.com/OtohaCo/SwiftAgent/pull/107) contains both. They must
ship together: an intermediate schema-12 reader unaware of retirement would
ignore optional authority retirement metadata. Acceptance-only documentation
commits and later main/merge identities are recorded separately in PR comments.

Approved scope: durable explicit native→ordinary exit and queued per-Run reminder.
Long tool-loop and between-queued-replies maintenance remain open in #105. The
unsafe Run-local required-reminder combination remains refused. No automatic
summary service, arbitrary current-tool-output excerpts, hidden reasoning
recovery, new cryptographic validation or vendor-universal compression protocol.

## Targeted evidence

Executed on macOS 27.2 arm64, Xcode 27.0 (27A266a), Apple Swift 6.4
(swiftlang-6.4.0.34.1), SDK 27.0. Logs retained in `.ci-logs/issue105/` in the
isolated issue105 worktree; full gates upload structured metadata to CI artifacts.

- New public API compile RED is a feature-absence check, not proof of a prior
  runtime bug. `format-red.log`, `handoff-red`, `queue-red` retain that distinction.
- A concrete weak raw-payload-only reinjection guard was independently rejected:
  replaying that predecessor produced two assertion failures in
  `reinjection-predecessor-red.log`; the full-value/count future-only allowlist
  passes `reinjection-allowlist-green.log`. Same-origin whitespace-reencoded old
  continuation is refused before user admission/HTTP; later target thinking
  remains intact. Fixtures do not verify any vendor signature.
- `handoff-operation-final.log`: eight tests, including parameterized definite
  failure/commitUnknown, cancellation/deadline and noncooperative projector,
  capability revoke/drain, stale actor/queue ownership, completion and pending-only
  metadata races with unchanged history head, old schema 3/11 refusal, hard budget
  rejection and future-only continuation allowance. Definite failure preserves
  old authority; unknown uses actual reopened state and poisons the old actor.
- `handoff-green-new-native-chain.log`: actual public File Journal + Swift HTTP
  encoder, source-bound deterministic summary, target binding, new reminder and
  fresh native checkpoint generation 1 / previous nil / different ID; close/reopen
  continues the new chain, retaining canonical history.
- `handoff-green-reinjection-http.log`: changed tool registry/model, same-origin
  malicious projector refusal, future signed thinking and reopened normal Run;
  old completed discovery is not reexecuted by handoff/projection.
- `queue-tool-loop-corrected.log`: two queued real users, two different reminders,
  four HTTP requests across two tool loops, exactly two executor calls, canonical
  two users/four assistants/two tool results, reopened identical history. The
  cancellation case holds preflight, stops/drains the dispatcher, sends zero HTTP,
  admits neither queued input and reopens without a fabricated checkpoint.
- Upgrade tests include actual child-process SIGKILL after reader gate and CURRENT,
  exact bridge recovery, altered/missing target refusal without byte changes,
  stale opener rejection, existing ownership fail-fast and unsupported schema-3
  refusal before unpublished-tail truncation. The sequential 11-test format/native
  suite passed; its earlier parallel `storeInUse` result is retained and not
  overwritten or described as a product bug fix.

Early failures remain: reopened retirement was initially absent from the disk
header (fixed in both encode/decode directions); fixture reused a historical
call ID (corrected to distinct call IDs); `beforeCurrentReplace` was initially
misclassified as definite failure (corrected test to existing `beforeAppend`
definite semantics); queued fixture initially used an incorrect public label
(corrected to `inlineToolChanges`). No failed log is counted as passing merely
because its filename includes “green”.

## Compatibility and remaining limits

Default schema 3 and existing opt-in native schema 11 remain unchanged. New
explicit schema 12 and writer-exclusive offline 11→12 upgrade preserve store/session
identity and facts. Existing creation/queue initializer signatures are exercised
as exact public function references. No protocol requirement is added.
`AgentJournalEvent.contextHandoff` is a prerelease enum case delta, requiring
exhaustive switches to adapt. Old readers must refuse schema 12 before writes;
new readers enforce the retirement even after maintenance and reopen.

Host chooses the target binding, selected tools, budgets, prepared summaries and
semantic fallback. Core validates original source, pairing, final budgets and
publication witnesses; it does not validate summary meaning. Persistent
instructions and unproven completion/pending boundaries refuse. Cancellation is
possible until publication seal; wait and physical drain differ. Reconciliation
still requires verified facts and a fresh same-ID Session on the same handle.
See [Host guide](../guides/swift-agent-context-handoff.md).

OtohaAI follow-up: pin only an accepted actual main, explicitly opt into or offline
upgrade schema 12, rebuild Sessions with the target binding after handoff, pass
queued controls through its resolver, handle refusal/unknown/drain, and perform
its own real endpoint/account/model and product end-to-end qualification. Native
compaction must not be re-enabled solely on these fixtures.

## Complete local gate and independent review

`bash Scripts/ci-macos.sh` exited 0 on the clean runtime source dd5317e above:
Provider 340 tests / 48 suites (172.440s), Core 465 / 66 (77.086s), ExternalClient
39 / 8 (9.122s); iOS cross-builds, all examples/fixtures, audited authorization,
execution reporting and all old-reader gates passed. The new retirement matrix
contains 18 prior-schema11 refusal checks with unchanged bytes and four actual
`retirement=1 nativeCheckpoint=none canonical=preserved` checks, including upgrade
and maintenance. `bash Scripts/ci-concurrency-seal.sh` separately exited 0
(11 concurrency tests plus five final-completion tests).

Core/Journal, Provider and runtime/publicAPI independent reviewers each inspected
the final diff and actual exact-source metadata/logs and found no remaining scoped
P0/P1/blocking P2. The archived [evidence](issue105-evidence/raw-evidence-manifest.json)
distinguishes focused failures from corrected passes. The later acceptance/test
commit additionally checks imported closed history without completed Run proof
and persistent-instruction refusal (nine operation tests GREEN, 0.661s); it changes no SDK implementation. Remote
exact-head and actual merge/main CI remain separately required, with results
recorded in PR #107 acceptance comments.
