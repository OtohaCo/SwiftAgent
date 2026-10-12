# Issue #101 focused Host compaction acceptance

Status: prepared, unreleased. No tag, Release or Host integration is claimed.
The immutable final source/PR/main identities and platform CI result are recorded
in the PR acceptance comment after checks finish; this page describes the evidence
and does not substitute #99's historical acceptance.

## Baseline and scope

Actual fetched main: `4baa5afc8105d36275737a62bf8a20a10db216fb` (PR #100),
tree `a07567c07fa428ba5d845352951827338d98f3aa`.
Only SwiftAgent changed. OtohaAI/sub2api, pricing, OpenAI standalone, compaction
modes and schema versions are unchanged. The scope includes the small
[OAI-612 diagnostic request](https://github.com/OtohaCo/SwiftAgent/issues/101#issuecomment-6119081514).

## Confirmed defects and behavior

- Real public Session/Run/HTTP fixture RED: completed reminder + drain refused
  idle compact; pre-generation compaction with required reminder instead sent two
  HTTP requests and admitted input while losing that reminder. The same tests
  pass after narrowly permitting proven completed idle whole-history on-demand,
  and refusing the Run-local combination in initial preflight.
- File Journal proof uses existing lastRunID, Run admission ordinal, completed
  terminal, history head and empty pending state. Independent review found a
  metadata race: pending could change without changing history head during HTTP.
  A real File Journal/package fault-seam RED published a replacement checkpoint;
  GREEN preserves the old checkpoint and pending across reopen. Actual publication
  now rechecks the same Run-bound proof in its store transaction with history CAS.
- Memory retains one completed canonical revision, available only after existing
  physical drain/reservation. Reconstructed memory sessions lacking proof refuse.
  File sessions can reopen before first compact and after checkpoint, compact
  repeatedly, then continue with real new user/reminder. Persistent instructions,
  noncompleted/unknown terminals, pending/quarantine and through restrictions stay.
- Cancellation coverage releases a valid signed summary after cancel and requires
  CancellationError; malformed summary refusal cannot mask a cancellation failure.
- serviceDefault omits thinking across generation, controls and on-demand encoding;
  betweenTools has exactly type=between_tools on resolved Sonnet 5.5. Explicit
  mismatch/tail qualification and xhigh/max effort combinations refuse before HTTP.
  Ordinary signed progress blocks remain unchanged on tool continuation.
- Local Anthropic body overflow retains invalidRequest and gains the fixed public
  diagnostic requestValidation/requestBodyTooLarge; no payload is attached and
  the code does not imply an image-specific cause or authorize replay.

## Executed evidence

Local platform: macOS 27.2 (26B5101f), arm64, Swift 6.4, Xcode 27.0 (27A266a),
macOS SDK 27.0. Commands run from the repository root. Logs remain under
`.ci-logs/issue101/`; first failures were retained, not erased.

| Command/evidence | Result |
| --- | --- |
| `swift test --filter AnthropicHostCompactionTests`, host-path-red.log | Real RED: idle reminder rejection and Run-local missing reminder (5 issues) |
| same public counterexamples, host-path-green-2.log | GREEN: 2 tests, including File reopen |
| `swift test --filter 'AnthropicHost\|AnthropicConversationControl\|AnthropicNativeContext\|AnthropicThinkingCompaction\|NativeCompaction\|NativeMaintenance\|ModelCatalogProvider'`, targeted.log | GREEN: 47 Provider tests / 6 suites and 12 Core tests / 2 suites |
| `swift test --filter AnthropicReminderPublicationTests`, reminder-publication-red.log | Real RED: 3 issues, replacement persisted across reopen despite new pending |
| `swift test --filter 'AnthropicReminderPublicationTests\|AnthropicHostCompactionTests'`, reminder-publication-green-2.log | GREEN: 6 tests / 2 suites, including failure/cancel, repeat/reopen and unknown terminal |
| `swift test --package-path Examples/ExternalClient --filter NativeContextPublicClientTests`, external-host-green.log | GREEN: public compiled Host flow and legacy function signatures |

The final full macOS script, concurrency seal and remote Linux/macOS/Apple checks
are required before merge; their source-bound results belong in the final PR
acceptance comment. No pending check is represented here as passed. Full scripts
include existing usage, mutation/recovery, OpenAI automatic, old-reader rejection,
execution reporting and external qualification fixtures; those gates are retained.

Retained preliminary failures include incorrect test argument ordering/optional
model-name compilation and a mistakenly broad diagnostic test assertion, a test initially comparing formal Journal messages against
Session root instructions, and a summary fixture initially omitting a real trusted
tool addition. Each was corrected without weakening SDK checks; the successful
external compaction returns the corresponding native tool change. Complete raw
first logs remain available locally/CI artifacts where generated.

## Public API and limits

Two AnthropicThinking cases and Diagnostic.Reason.requestBodyTooLarge extend
public enums; downstream exhaustive switches must be updated. Exact existing
initializer signatures/default disabled behavior remain. The new stored Run
ordinal is package-only exposure of an already persisted field. No new disk DTO,
schema or reader compatibility requirement is introduced; native-context stores
remain opt-in schema 11, default legacy stores remain schema 3.

Threshold/reminder combination scheduling and Run-local reminder restoration are
not implemented. Trigger is not a cutoff; next-user restoration cannot protect an
answer already generated in the same automatic HTTP request. Vendor pause/reinsert
requires future explicit history/thinking design. New modes do not qualify managed
thinking-tail cuts or override continuation binding revisions.

Official six protocol entries were rechecked on 2026-10-12 and are linked in the
[Host guide](../guides/swift-agent-native-context.md). Fixture signatures are not
cryptographic qualification. No new paid service or sub2api smoke was performed.
OtohaAI must explicitly select omission/betweenTools, qualify its real deployment
and beta forwarding, exercise reminder/tool/compact/reopen, check native usage and
map the typed request-size diagnostic. SDK evidence is not product end-to-end proof.
