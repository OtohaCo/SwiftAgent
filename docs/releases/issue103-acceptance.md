# Issue #103: automatic compaction final answer acceptance

Status: prepared, unreleased. No tag, Release, Host integration or new paid live
qualification is claimed. Exact final source/PR/main identities and full platform
results belong in the PR acceptance comment after execution.

## Baseline and defect

Isolation started from actual main `4baa5afc8105d36275737a62bf8a20a10db216fb`,
tree `a07567c07fa428ba5d845352951827338d98f3aa` (PR #100). PR #102's independent
gates were still running. Only SwiftAgent is changed; OtohaAI remains untouched.

`ResponsesStreamDecoder.consumeCompleted` examined messages only after the final
compaction item when selecting maintenance. Thus `[compaction, message,
compaction]` and `[message, compaction]` discarded the genuine completed answer
classification and entered the bounded continuation loop. Five valid repeated
SSE responses reproduced `Native maintenance did not converge within its bounded
continuation budget.` No threshold adjustment can correct this classification.

The fix uses the entire validated completed output for response classification.
The latest compaction index remains the transition/replay boundary. Existing item
identity, completeness, native window, source binding and publication validation
remain in place; no Host-created stop reason or native-state deletion is needed.

## Targeted execution

macOS 27.2 arm64, Apple Swift 6.4 / Xcode 27.0. From the isolated worktree:

- `swift test --filter OpenAIAutomaticFinalAnswerTests --disable-sandbox --no-parallel`:
  genuine RED, two public File Journal cases failed with the fifth-response
  maintenance error; the compaction-only control passed. Retained log:
  `.ci-logs/issue103/answer-red.log`.
- Same command after the minimal decoder fix: GREEN, two tests / three cases.
  A completed answer uses one HTTP request and one model turn. Canonical answer,
  both native compaction items, usage and the latest transition are retained.
  Close/reopen preserves the checkpoint and history; a true next user replays
  the latest opaque item and completes in one request. The strengthened test
  also checks the completed Run terminal across reopen.
- Targeted decoder/native/deadline/completion regressions retain the existing
  automatic tool loop, partial/malformed stream refusal, standalone window,
  provider-route ownership, cancellation, final publication and maintenance
  deadline gates. Logs: `answer-green.log`, `targeted-green.log`.

Full macOS, concurrency seal, independent final review and corresponding remote
Linux/macOS/Apple checks are required before merge. Pending gates are not passed
evidence; final source-bound results are recorded in the PR acceptance comment.

## Compatibility and follow-ups

No public initializer, enum, protocol, schema or reader compatibility change.
Default legacy schema 3 and opt-in native schema 11 retain their contracts.
This is an HTTP/SSE fixture regression using genuine SDK encoder, decoder,
Session/Run and File Journal APIs, not a new service/model/account qualification.
The issue's live report is external evidence, not a paid call executed here.

The [official OpenAI guide](https://developers.openai.com/api/docs/guides/compaction)
was rechecked 2026-10-12: stateless chaining appends native output and may prune
before the latest compaction item. Canonical history and checkpoint payload are
not that pruned request view.

Queued follow-ups retain exclusive ownership while paused. The issue records
the accepted delivery behavior: finish the queue, close/drain its dispatcher,
then compact before a direct reply. A between-queued-replies maintenance hook is
deferred to a separate ownership/cancellation design, not part of this decoder
fix. OtohaAI should retain its containment until it pins the accepted main and
requalifies the real automatic-compaction path; SDK fixture success alone does
not authorize re-enabling the product feature.
