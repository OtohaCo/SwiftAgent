# Issue #99 implementation acceptance

Status: prepared implementation; final platform/PR/main acceptance pending.
No next version, tag or GitHub Release is assigned. This is after the RC6 candidate,
not a replacement RC6 report. OtohaAI and sub2api production code are unchanged.

## Baseline and source identity

- Base main: `34103af09baf0ecadfb27389803126ad0dd8f4ac`.
- Base tree: `1a00400a9142184973a2453dc5b1841494d094f2` (merged PR #98).
- Issue: <https://github.com/OtohaCo/SwiftAgent/issues/99>.
- Last published release/tag remains 1.0.0-rc.5, target
  `24447b8298ccea84f9f8056374857c5c47d8f64c`; no tag moved or created.
- SDK source through `75f88100e527c61ebea83755c0e9824042080007`, tree
  `0e3dc9ded859cc1e5cb4badf11450b3f0d80ddfb`.
- Public examples/reader gate: `a74004c` (subsequent docs and reporting fixture
  correction recorded separately; final source/PR/main identities to be filled).
- Platform: macOS 27.2 (26B5101f), arm64, Apple Swift 6.4
  (swiftlang-6.4.0.34.1), Xcode 27.0 (27A266a), macOS/iPhoneOS SDK 27.0.

## Requirement mapping and local evidence

All filenames below are retained under `.ci-logs/issue99/` locally and uploaded by
CI. A filename containing “green” is not itself evidence of success; explicit
results below supersede names. Tests are Swift encoder/decoder/transport and real
File Journal fixtures where stated. No paid live calls were made.

| Requirement | Implementation / evidence |
| --- | --- |
| Four native modes, qualification, exact wire boundaries | AnthropicNativeContextTests, OpenAINativeContextTests; `native-provider-stage-corrected-seal.log`: 49 Provider/6 suites +1 Models +1 Core targeted test GREEN; `openai-final-stage.log`: 30 tests/3 suites GREEN |
| Canonical/effective state, atomic accepted tools/mutations/no-effect | NativeCompactionOperationTests plus existing mutation/tool publication suites; `native-atomic-seal.log`: 48 tests/7 suites GREEN, 31.721s |
| Independent lifecycle, EOF/no-summary, maintenance deadline | NativeCompactionOperationTests/NativeMaintenanceDeadlineTests; summaries remain nonfinal; no entire-Run replay |
| Append-only controls, deferred discovery, same-name updates/removal, reopen | `controls-final-scoped-corrected-fixture.log`: 17 Provider/2 suites +16 Core/2 suites GREEN; actual encoder RED retained in `controls-http-red-executed.log` |
| Compact→real user→Chinese reminder→tool loop | Public NativeContextHostExample, no @testable; `public-native-context-compat-seal.log`: 2 tests (one compatibility test, one test with two HTTP/FileStore flows) GREEN |
| OpenAI automatic compaction and call in one response, same/next Run/reopen | Same public fixture; actual compacted body and function_call_output checked, execution once, canonical full source retained |
| Thinking-tail exact cut, two compactions, immutable tail, reopen | `thinking-tail-final-scoped-seal.log`: 7 Provider/2 suites +1 Models proof +11 Core native operation tests GREEN |
| Thinking-tail final projection protection | `thinking-protected-tail-red.log` real failure; fixed whole kept-tail equality/digest after final projection/image handling |
| Thinking compact actual prefix budget | `thinking-tail-budget-red.log` real 400>350 failure; fixed compact prefix100/result310 within350; old full proof encode is not a dispatched budget |
| Managed proof cannot use error/drop fallback | `thinking-tail-explicit-policy-red.log` 2 policy failures; strict old-prefix validation GREEN in final scoped seal |
| Post-summary uncooperative estimator cancellation | actual HTTP/File Journal candidate-validation barrier; logical cancellation retains same/fresh actor reservation until physical drain, no late checkpoint, next Run works |
| Maintenance limit/ordinary late iterations/TTL lower bounds | `final-review-policy-usage-red.log`: Provider 12 failed assertions (9 late-accounting, 3 maintenance) +3 TTL failures; `final-review-policy-usage-green.log`: 11 Provider +10 Models/2 suites +11 Core GREEN |
| Decimal tiers/service scope/sampling model/unknown totals/cache TTL | `public-pricing-exact-numeric-green.log`: 21 tests/2 suites incl all17 old Host router regressions; numeric precision real RED in `public-numeric-decimal-precision-red.log` |
| Schema-11 reader boundary | `native-context-reader-corrected.log`: schema3 read/append, schema10 inspect/append/maintain refuses empty/populated schema11, bytes unchanged before/after maintenance |
| Legacy public precise signatures / old Provider | NativeContextPublicClientTests, native diagnostic and iteration compatibility tests; optional fields nil on old exports |
| New diagnostic/reporting event consumption | ExecutionReportReducerTests; maintenance/transformation/progress do not become answers or effects |

Initial compile/fixture failures are retained, including incorrect type/argument
labels, missing OpenAI sequence numbers and duplicate tool call IDs. These were
corrected in fixtures without weakening decoder, duplicate-ID or timeout guards.
`route-native-owner-green.log` contains an earlier failure and must not be cited as
passing. A real baseline isolated fallback run and corrected comparison exist in
`main-baseline-fallback.log` and `route-pin-current-comparison.log`. The earlier
pre-admission broad run had a tool timeout under load; final full gate must confirm
its outcome. No indefinite rerun-until-green policy is used.

## Independent review

Three read-only reviewers examined actual diff and retained execution results:

- Core/Journal: atomic publication, mutation/no-effect/audit, source/CAS/recovery,
  admission, deadline/cancellation/drain. Closed two managed-tail P1s (illegal
  ancestral same-cut rebase, explicit fallback bypassing old proof), actual tail
  protection and configured automatic-maintenance P2. No remaining scoped blocker.
- Provider: all four wire modes/SSE/complete terminal, Route owner, signed-thinking
  continuation, controls/reminders, transformations and accounting. Closed retained
  tail projection and ordinary late-iterations scope P2. No remaining scoped blocker.
- Catalog/Usage/public clients: exact Decimal/services, sampling identity/coverage,
  TTL/legacy signatures/Codable and public fixture. Closed numeric precision and
  known-TTL lower-bound P2. No remaining scoped blocker.

Final documentation, full applicable CI and actual merged main still require their
own result; scoped review is not a substitute.

## Supported scope and remaining limitations

The [Host guide](../guides/swift-agent-native-context.md) is the public support
matrix. Four modes are implemented for explicitly qualified concrete deployments;
metadata alone never enables them. Managed thinking tail is direct Anthropic
on-demand with explicitly qualified preserved thinking, fixed root/tools, real
SDK request selectors, unchanged tail and no nonempty historical controls.
Historical-controls tail transforms, arbitrary cuts, generic proxy capability,
threshold plus required reminders, active/permanent instruction erasure and
system→user continuation after an unanswered controlled request are locally
refused. A future resume/handoff/expanded-transform capability needs independent
protocol design and proof.

Unknown token estimates, sampling identities or prices stay unknown. Ordinary
Anthropic streams cannot change to iteration accounting after publishing parent
counts. Inline client definition counts/serialized bytes are bounded; service
private rendered-tool limits and deployment behavior need qualification. Ciphertext
is not a tokenizer, local digests do not verify vendor signatures or summary semantics.

Live qualification was not run. OtohaAI follow-up should configure actual account
scope and strict error policy, exercise discovery/schema update/removal, Chinese
reminders, parallel tools, multiple compactions, cancellation and reopen, and confirm
actual routed beta/usage/tariffs and no unexpected thinking_dropped. SDK fixture
acceptance does not mean OtohaAI product integration or end-to-end acceptance.

## Full gates and landing

Pending final records: complete macOS script, concurrency seal, Apple-provider
compile, Linux CI, protected PR checks, normal PR merge and actual main SHA/tree/CI.
No tag or Release will be created. Final status is not ready until these records
are filled and all blocking findings resolved.
