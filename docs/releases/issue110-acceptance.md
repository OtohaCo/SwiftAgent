# Issue #110 — ChatGPT-plan SDK contract

Status: implemented and focused offline verification passed; complete final-source
PR/main and publication evidence is recorded in [#110](https://github.com/OtohaCo/SwiftAgent/issues/110)
and the [RC6 Pre-release](https://github.com/OtohaCo/SwiftAgent/releases/tag/1.0.0-rc.6)
when those gates actually complete. This page does not predeclare live service
qualification or release publication.

The Host explicitly paused RC6 publication to add this scope. Earlier accepted
SDK baseline `adc14bda5652ef5c61e4e934429c7736249cc1f6` / tree
`caa703b9ffa539db78b40d9fbf76627071e2ef31` and documentation-only release main
`c0085211a176812c4c43723b5ed3851553ebb9e7` / tree
`98ad2df931c9cc1f095b564456b23a558f7633f0` remain historical evidence. The latter's
[actual CI](https://github.com/OtohaCo/SwiftAgent/actions/runs/38382913379) passed
all three jobs, with 60 verified exact-clean stage records and actual reader/
reporting/seal checks. Anonymous cold fixed-revision public consumer passed.
No rc.6 tag or Release was created for that superseded publication target.
Neither earlier result qualifies #110.

## Actual RED/GREEN

Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) on arm64 macOS; no paid/live service.

- Compiling old-contract RED: source
  `40cd814c5a774b977af5ffc2b4b8fd038e102c4f`, tree
  `ce855dd022da856f827b070a4b7e2ecc6706c57a`.
  `swift test --disable-sandbox --no-parallel --filter ChatGPTPlanContractTests`
  executed 3 tests and failed with 7 issues: max_output_tokens present, system
  instead of developer, flat tools instead of namespace/name, two plan SSE codes
  classified invalidResponse, and the plan models array rejected by the API-key
  catalog. These are route differences, not bugs in ordinary API-key encoding.
- Additional real drain RED: source
  `ef7131eef7b262c448ae50a1e13b4e6b1b198807`, tree
  `4ca0fef2de65cb8950c0d635cd5832adf017e243`.
  The cancellation test returned physical drain while the non-cooperating token
  callback was still pending (1 test, 2 failed assertions). Fix uses existing
  ModelProviderRunDrain plus synchronous producer registration; no Core change.
- Focused GREEN:
  `swift test --disable-sandbox --no-parallel --filter ChatGPTPlan` passed 19
  tests in 3 suites. Request body, image/schema, tool loop and continuation,
  namespace/name tampering, missing/incomplete/failed completion, error privacy,
  HTTP bounds/status, token rotation/preflight/late cancellation and deadline/
  physical drain (both cases reject a replacement Session until drain, then
  permit a fresh Run with the same ID),
  catalog dialect/filter/order/metadata/pagination/bounds all passed.
- Public-only GREEN:
  `swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel --filter ChatGPTPlanPublicClientTests`
  passed. Real temporary Run-record File Journal, 3 actual adapter HTTP fixtures,
  rotating token headers, 1 read-only executor invocation; close/reopen retains
  full canonical messages, original Run fact and tool-result pairing, then a new
  Run continues without executing the old tool again. Root instructions remain
  configuration-derived system messages in Session and developer only on wire.

Initial local harness failures are retained separately: inaccessible test JSON
inspection import, missing throwing drain annotations, an actor-isolated macro
autoclosure, incomplete hand-written SSE fixture lifecycle/sequence numbers, and
an incorrect assumption that runtime root instructions belong in the persisted
checkpoint. The tests were corrected against existing source/protocol contracts;
no SDK stream/history assertion was weakened. Logs are kept under
`.ci-logs/issue110/` and summarized in the final source-bound PR/issue report.
Historical Swift planning crashes and cancelled CI remain in whole-candidate
provenance; these test-harness failures are not relabeled SDK RED.
The first local full macOS invocation was deliberately stopped during core
tests to add the independent review's deadline/reservation test supplement;
its partial log is retained, not counted as a passing full gate. The supplement
passed all 19 focused tests, including both cancellation/deadline cases.
The first complete local core-test stage then failed the existing ExternalClient
architecture guard: the new public fixture omitted four required public module
imports. Those imports were added without changing the guard or its assertions;
the failed source/log remains separate from final-source full acceptance.

## Support and limits

Approved [design](../superpowers/specs/2026-10-13-chatgpt-plan-responses-design.md)
and [Host guide](../guides/swift-agent-chatgpt-plan-provider.md) define the explicit
plan route. New public Provider/catalog/credential types and two diagnostic reason
cases; old API-key signatures/defaults unchanged, no Journal/schema or Core
executor/settlement change. Default/native/handoff schema 3/11/12 and reader
gates remain applicable. SDK cannot force a Host token callback to finish;
physical drain waits for it, and a late result cannot dispatch after cancellation
or deadline expiry.

The allowlisted body uses developer instructions, namespaced function calls,
stream:true/store:false and full input. SDK does not send max_output_tokens,
previous_response_id, include or unsupported tuning/cache fields. Native
compaction/checkpoints/controls and encrypted replay/output explicitly refuse;
their plan capability remains unqualified. Hosted tools/custom free-text/file/
audio/video surfaces are not implemented by this adapter. Visible reasoning
does not establish every model's continuation requirements.

Current OAuth integration deployment approval, scopes, account/model availability,
token refresh, model picker, actual plan service and OtohaAI product integration
are Host acceptance tasks. Fixtures are not live qualification; no paid requests,
Host code/pin/switch changes or user-store migration occurred. #105 remains OPEN
for its previously deferred maintenance scope.
