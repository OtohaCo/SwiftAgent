# Issue #112 — native Gemini SDK candidate

Status: implementation, focused Swift / HTTP / public-client verification and
complete local macOS / concurrency-seal gates passed. Three independent scoped
source reviews found no remaining blocker. Final hosted PR/main CI and renewed
release consumer/tag gates are still required. This page does not declare publication,
live Google/gateway/account qualification or OtohaAI integration.

Approved [design](../superpowers/specs/2026-10-13-gemini-native-provider-design.md)
and [Host guide](../guides/swift-agent-gemini-provider.md) define the bounded scope.
Starting accepted main is `7085740f92498a2cbe6aad0423074e8cf41d2e12`, tree
`6aa33ed8a95bedb58cf012a2f69a8e1c94ee800b` (#110 via
[PR #111](https://github.com/OtohaCo/SwiftAgent/pull/111)). Its own
[main CI](https://github.com/OtohaCo/SwiftAgent/actions/runs/38395997590) passed;
that result is baseline evidence, not #112 acceptance.

## Actual focused evidence

Apple Swift `6.4.0.34.1`, arm64 macOS 27.2; no paid live calls.
Logs are retained under `.ci-logs/issue112/` and included in final source-bound
PR/issue/publication evidence. Whole-candidate historical failures remain intact.

- File contract RED at `cd4496c` (full source/tree in retained metadata): actual
  Swift compilation succeeded, then a typed canonical file decode failed
  (1 test / 1 issue). GREEN uses the real SDK encoder/decode, validated URI/MIME/
  bounds, Core policy/budget/admission/correlation and real schema13 Journal.
- First Gemini missing-Provider RED was a **compile failure**, not an executed
  service or runtime failure. It is recorded separately from these executed REDs.
- Exact UTF-8 RED at `e08bd222230e395518ff5fafd4e15c89e1a62c2e`, tree
  `4cc1c5ae76a74a0d724c616a3e313da60ab27b3c`: 2 executed tests / 3 failed
  assertions. Swift's canonical Unicode equality accepted changed visible native
  text and a changed account cursor scope. Exact encoded-byte comparisons fix
  both; GREEN rejects before replay HTTP or cross-scope catalog dispatch.
- Independent Provider review's P2 stream-error RED at
  `ca7412b3205268e6078ba01fa1395066cd114b87`, tree
  `0d3a74da04cae2f8c9605a5a2b5d23b15632b9cc`: 1 test / 5 cases / 5 failed
  assertions. HTTP-200 SSE error codes 400/401/403/429/503 were all incorrectly
  `invalidResponse`; bounded structured allowlist classification now preserves
  request/auth/permission/rate-limit/unavailable kinds with sanitized text.
  Incremental text can arrive first; calls/completion remain withheld on failure.
- Focused Gemini plus affected existing ChatGPT-plan tests pass 33 tests / 4
  suites before the final documentation seal. Includes streaming/nonstreaming,
  signed/unsigned profiles, empty signed parts, parallel/sequential batches,
  deferred expansion/next Run, exact body limit, sparse usage, safety/truncation/
  malformed/EOF, local configuration/continuation refusals, cache/client/catalog,
  rotating credentials and cancellation/deadline physical drain.
- File + existing image/Run-record focused verification passes Models 3,
  Journal 3, Core 38 tests (44 total / 5 suites). Actual schema12 reader
  `7085740f92498a2cbe6aad0423074e8cf41d2e12` rejects schema13 inspect/append/
  maintenance 12 times: empty/populated stores before/after maintenance,
  every refusal byte preserving. New reader reads/appends schema3 and schema12;
  schema13 files survive maintenance and separate-process reopen. The new gate
  is added to both CI scripts without removing existing gates.
- Public-only fixture initially passed 4 tests, including exact old binding /
  store function-type references. Full CI records the final-source results.
  Same projector and fixed binding project only once per new model request;
  two-model-step Run retains file/image, signed native parts and two tool results,
  executes each parallel call once, preserves Run terminal and canonical prefix
  through reopen/next Run. Late cancellation produces HTTP0 and drain waits for
  credentials. Explicit cache creation/use/delete is outside a Run.

The first complete local macOS invocation was stopped with SIGTERM (exit143)
during core-tests after independent review confirmed a new P2: a post-terminal
usage-only frame bypassed responseId validation and could authorize an ended
function batch with another response's totals. Its initial source was
`89690deb28c8c412dc9bca35a4014f2a81e23df9`, tree
`fcdb5e1ce6bcfd0de03589efef415e117b1ddd17`; partial stage/log/stop reason are
retained, not counted as a passing gate. The added HTTP regression (original RED at
`d73ef616fb18b5c980e4ce89c2e409d8a2870814`, tree
`badaf767e6730f3543abce6d2e9bd1e8ce2cf135`, 1 test / 2 cases / 2 failed
assertions) requires mismatched IDs to fail without completed calls and matching or absent IDs to
retain the normal path. Validation now precedes the post-terminal usage branch;
the complete local gates below qualify the fixed code source. Hosted gates must
qualify the final PR/documentation head.

The mixed body fixture encodes text/escapes/system/tool schema/image using actual
Swift JSON. Exactly its final byte count is accepted and sent unchanged; lowering
the configured limit by one byte rejects before credentials/HTTP. The measured mixed body is 4,909 bytes: limit4,909 sends once, limit4,908
rejects without a new dispatch; final test logs retain the count. Default ceiling is conservative
100,000,000 bytes; no image constant substitutes for the final body check.

Initial test-harness failures are preserved, not labeled SDK RED: actor-isolated
assertion autoclosures, shared transport response index exhaustion and a JSON
inspection helper unavailable to an external client. Tests were corrected using
public JSON pattern matching/local helpers, without `@testable`, relaxed SDK
assertions or deleted gates. The native decoder/client build and original file
reader check passed on their first complete attempts. The real stream-error
finding was fixed rather than deferred.

## Complete local code-source seal

Tested code commit: `781d5addf480fd70037d54e86bb5ccae83bad3e7`.
Tree: `92bcc3045a0213046cbfe1d774a85e50622db8e2`.
Clean tracked workspace, Apple Swift `6.4.0.34.1`, arm64 macOS 27.2:

- `bash Scripts/ci-macos.sh`: exit0, 833.279 seconds, all 20 source-bound stage
  records pass; complete existing reader/audit/qualification/external-client and
  new file compatibility gates passed. Schema12 reader rejects schema13 12 times
  with byte-preserving refusal; new reader reads/appends schema3/12 and retains
  file refs through maintenance/reopen.
- `bash Scripts/ci-concurrency-seal.sh`: exit0, 28.369 seconds; both existing
  11-test and 5-test suites pass. No timeout relaxation or new paid live call.

Independent Session/Journal, Provider and runtime/public-API reviewers examined
this exact code/tree and executed RED/GREEN evidence. Their source-scoped verdicts
are PASS, including both corrected Provider P2s. Final gate attestation remains
separate from this source review. The final documentation-only seal updates this
page, README and Provider matrix; it changes no Sources/tests/build behavior.
Local tested code, final documentation/PR head and actual merge/main are recorded
separately in the closure/publication evidence. A passing old source is never
reported as a new commit's executed CI.

## Contracts and limits

The increment adds public `.file` and `.fileInput`, `ModelFileReference`, immutable
`AgentRunInput`, file policy, required-label binding/store overloads and typed run
entry points. Old String/initializer function types and text-only correlation
representation remain unchanged. Explicit schema13 stores include prior
capabilities; default schema3 and schema11→12 upgrade remain unchanged. No 3–12→13
migration, new ledger or public protocol requirement is added. `.file` is an
acknowledged exhaustive-switch source change; no ABI stability is promised.

Native generateContent Provider/cache/catalog use existing runtime contracts.
Received ordered parts/signatures are retained, correspondence is checked, and
calls are executable only after clean completion. This is local policy, not vendor
cryptographic validation. Explicit caches bind actual local prefix/system/tools/
model/endpoint/account/expiry, never effect authority; mismatch fails locally,
missing remote resources remain classified errors and no automatic retry/replay
occurs. Core still budgets the full context including cached/file tokens.

Unsupported: URI file tool results, queued/steered attachment inputs, file upload/
conversion, audio/video/image output, hosted tools, native compaction/controls,
Interactions/Vertex/Live APIs, OAuth UI/refresh and automatic summary services.
Unqualified: all new live Google/gateway/model/account/cache paths. Existing
provider qualification records #86–#89 are preserved and not generalized. #105
remaining long-tool-loop maintenance and #44–#47/#60/#61 follow-ups remain open.
SDK acceptance does not complete OtohaAI or product end-to-end acceptance.

## Final-source closure

The final PR head, source/tree, local commands/results, three independent reviews,
PR/push/main CI URLs and actual main/tree equality must be recorded in the
source-bound PR and [issue #112](https://github.com/OtohaCo/SwiftAgent/issues/112)
closure report. Publication requires fresh anonymous fixed-revision consumer,
immutable annotated tag, corresponding complete tag CI and independent exact-tag
consumer. Actual tag object/peeled commit/tree/time/assets belong to the authorized
GitHub Pre-release after these gates, not an invented date in this source page.
