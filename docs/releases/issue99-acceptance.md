# Issue #99 implementation acceptance

Status: prepared SDK implementation. Platform and landing qualification are recorded
against exact commits in [PR #100](https://github.com/OtohaCo/SwiftAgent/pull/100);
scoped results here do not imply unexecuted checks passed.
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
- Public examples/reader gate: `a74004c`; reporting fixture/docs: `d34f9866`.
- Final test/code revision: `9cf9d505b4d15ce97542012a221540915e1d9a3b`, tree
  `84202d44770c5c7ca819b1f9249fbc2a25c0c938`. This document follows that source
  revision. PR head and actual merge/main identity are recorded in PR #100, so
  documentation and source identities are not conflated.
- Platform: macOS 27.2 (26B5101f), arm64, Apple Swift 6.4
  (swiftlang-6.4.0.34.1), Xcode 27.0 (27A266a), macOS/iPhoneOS SDK 27.0.

## Requirement mapping and local evidence

The focused logs below are retained locally under `.ci-logs/issue99/`. CI uploads
its own runner-generated logs; this does not upload local historical RED/GREEN logs. A filename containing “green” is not itself evidence of success; explicit
results below supersede names. Tests are Swift encoder/decoder/transport and real
File Journal fixtures where stated. No paid live calls were made.

| Requirement | Implementation / evidence |
| --- | --- |
| Four native modes, qualification, exact wire boundaries | AnthropicNativeContextTests, OpenAINativeContextTests; `native-provider-stage-corrected-seal.log`: 49 Provider/6 suites +1 Models +1 Core targeted test GREEN; `openai-final-stage.log`: 30 tests/3 suites GREEN |
| Canonical/effective state, atomic accepted tools/mutations/no-effect | NativeCompactionOperationTests plus existing mutation/tool publication suites; `native-atomic-seal.log`: 48 tests/7 suites GREEN, 31.721s |
| Independent lifecycle, EOF/no-summary, maintenance deadline | NativeCompactionOperationTests/NativeMaintenanceDeadlineTests; summaries remain nonfinal; no entire-Run replay |
| Append-only controls, deferred discovery, same-name updates/removal, reopen | `controls-final-scoped-corrected-fixture.log`: 17 Provider/2 suites +16 Core/2 suites GREEN; actual encoder RED retained in `controls-http-red-executed.log` |
| Reminder parallel/retry/steering/no-new-user | AnthropicConversationControlTests: gated two parallel executions complete before the next HTTP, optional real steering coalesces one wire user turn; adapter-level 503→200 replay has identical body and one reminder; threshold/pause+reminder and invalid unanswered continuation reject locally. `reminder-boundary-final.log`: 11 tests/1 suite GREEN. Core/Route automatic qualified retries remain unsupported. |
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

Final docs/public fixture review passed in all three scopes. Provider review also
closed the reminder integration coverage gap after inspecting the 11-test GREEN
result. The conditional FoundationNetworking import is a portable test prerequisite.
Full applicable CI and actual main require their own results; scoped review is not
a substitute. [Independent review record](https://github.com/OtohaCo/SwiftAgent/pull/100#issuecomment-6118403959).

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

Required gates remain the complete macOS script, concurrency seal, Apple-provider
compile, Linux CI (including five bounded reporting reproductions), normal PR merge
and corresponding actual main CI. See [PR checks](https://github.com/OtohaCo/SwiftAgent/pull/100/checks)
and the PR's final acceptance record for immutable head/main SHA/tree and CI URLs.
No tag or Release is created by this task.

The first local complete-script attempt stopped at core-tests: three missing imports
required by the ExternalClient architecture guard, and a schema-3 compact test
rejected an absent deployment binding before reaching its intended unsupported-store
guard. Both prerequisites were corrected; the original refusal assertions remain.
Focused architecture and Journal tests passed (`full-gate-findings-scoped.log`).
The subsequent local full script passed core tests and public client tests before
this documentation revision; complete results are recorded separately in the PR.

The first [PR CI run](https://github.com/OtohaCo/SwiftAgent/actions/runs/38208452800)
at `4249387c52f848f8f3f4a7bff49a65c23f5da0af` reported Linux compile failure:
new reminder transport lacked FoundationNetworking's URLRequest import. The exact
failure is retained in `linux-first-ci.log`; `9cf9d50` adds the conditional import.
Apple provider compile passed on that first head. These partial results cannot
qualify the corrected final head; final-head checks must all pass before merge.

The next complete local script passed core, iOS, external/public-native and qualification
stages, then caught AppleChat's exhaustive switches missing additive events.
ConversationDisplay now ignores maintenance/transformations/progress as answer or
terminal content; `apple-chat-event-final.log` reports 32 tests/4 suites GREEN,
including an explicit no-answer/no-terminal diagnostic regression. Final corrected
head CI must include this consumer fix, not qualify the preceding head.
