# Issue #112 — native Gemini SDK candidate

Status: implemented; focused Swift / HTTP / public-client verification passed.
Final independent reviews, complete local/hosted PR/main CI and renewed release
consumer/tag gates are still required. This page does not declare publication,
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
- Focused Gemini plus affected existing ChatGPT-plan tests pass 32 tests / 4
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
- Public-only fixture initially passed 3 tests; an additional exact old binding /
  store function-type check supplements it. Full CI records the final count.
  Same projector and fixed binding project only once per new model request;
  two-model-step Run retains file/image, signed native parts and two tool results,
  executes each parallel call once, preserves Run terminal and canonical prefix
  through reopen/next Run. Late cancellation produces HTTP0 and drain waits for
  credentials. Explicit cache creation/use/delete is outside a Run.

The mixed body fixture encodes text/escapes/system/tool schema/image using actual
Swift JSON. Exactly its final byte count is accepted and sent unchanged; lowering
the configured limit by one byte rejects before credentials/HTTP. The precise
byte count is printed in the final test log. Default ceiling is conservative
100,000,000 bytes; no image constant substitutes for the final body check.

Initial test-harness failures are preserved, not labeled SDK RED: actor-isolated
assertion autoclosures, shared transport response index exhaustion and a JSON
inspection helper unavailable to an external client. Tests were corrected using
public JSON pattern matching/local helpers, without `@testable`, relaxed SDK
assertions or deleted gates. The native decoder/client build and original file
reader check passed on their first complete attempts. The real stream-error
finding was fixed rather than deferred.

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
