# ChatGPT-plan Responses adapter (#110)

Status: proposed; awaiting design approval. RC6 publication is paused by Host
instruction. No rc.6 tag or Release exists. Starting main is
`c0085211a176812c4c43723b5ed3851553ebb9e7`, tree
`98ad2df931c9cc1f095b564456b23a558f7633f0`. Its documentation-only CI and consumer
cannot qualify this new implementation.

## Goal and source contract

Add an explicitly selected SDK model source for OAuth-authorized ChatGPT plan
usage. The Host owns OAuth consent, account selection, secure storage, refresh,
UI, budgets and fallback decisions. SDK never signs in, refreshes credentials,
infers granted scopes or changes billing paths automatically. OtohaAI remains
outside this SDK task. No paid/live requests are authorized.

Official sources retrieved on 2026-10-13:

- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)
- [Namespace declaration](https://developers.openai.com/api/docs/guides/function-calling#defining-namespaces)
- [Responses reference](https://developers.openai.com/api/reference/resources/responses/methods/create)

The plan path uses public `POST https://api.openai.com/v1/responses` and
`GET https://api.openai.com/v1/models`, not ChatGPT backend-api. Every inference
has `store:false`, `stream:true`, and its necessary history in `input`.
Instructions use developer messages. Function tools are namespaced. All listed
unsupported fields, including `max_output_tokens` and `previous_response_id`,
are absent. Namespace is a separate optional field on function call items;
canonical tool names and call IDs must retain their exact bytes.

## Alternatives

1. **Separate public plan Provider and catalog (recommended).** Keep ordinary
   API-key initializer signatures/configuration untouched. Reuse bounded HTTP,
   SSE lifecycle/final-snapshot validation and canonical tool machinery through
   narrow internal configuration. Plan rules are explicit and independently tested.
2. Add a mode to every existing OpenAI initializer. This mixes fixed API keys
   and async Host credentials, cache/native qualification and wire rules; it
   creates more configuration combinations and initializer compatibility risks.
3. Add a Host transport/body rewriting shim. It cannot provide SDK preflight,
   namespace identity validation or safe stream error classification; excluded.

## Architecture and public boundary

Introduce `OpenAIChatGPTPlanProvider` and
`OpenAIChatGPTPlanModelCatalogProvider`. Both use a Host-supplied
`@Sendable () async throws -> String` access-token source. They call it exactly
once immediately before each HTTP dispatch, after local request validation.
Tokens are not cached in SDK, put into Codable values, logs, mirrors, model
events, errors or catalog scope. Cancellation before/after awaiting the source
prevents transport dispatch. Non-cancellation credential-source failures become
sanitized authentication/catalog failures; refresh remains Host-owned.

Endpoint is fixed to the official public route. Injection is limited to the
existing HTTP transport for offline fixtures, not an arbitrary credential target.
Use the `openai` ModelID provider namespace so existing Host model routing and
canonical tool identities remain usable; deployment/account ownership remains
the existing Host binding/route candidate contract. Plan-specific continuation
format distinguishes replay from ordinary API-key output, so incompatible opaque
state is rejected rather than silently replayed under a different request mode.

No new Journal format, Core authority, executor, settlement or retry mechanism.
No new provider-neutral compression protocol. Existing API-key Provider behavior
and old exact initializer function signatures remain unchanged.

## Request and continuation

The plan encoder uses an explicit allowlist of implemented fields. Preserve
instruction ordering by encoding each canonical `.system` as `.developer` in
the request view; canonical messages remain unchanged. Preserve developer,
user, assistant and legal tool-result ordering and supported image encoding.
Structured output uses the existing schema representation. Do not expose
unsupported tuning/cache/hosted-tool fields in the new configuration.

Declare the currently supplied SDK function tools in the fixed `swiftagent`
namespace. SDK deferred declarations still change the supplied tool set through
the normal Core loop; this does not emit `tool_search` or `defer_loading`.
Function-call wire history receives the namespace, while canonical names/call
IDs remain unqualified and unchanged. The response decoder validates expected
namespace on started/done/final snapshots before producing callable canonical
results; mismatched/missing/conflicting namespace, unknown calls or inconsistent
final snapshots fail closed. No stripping guessed prefixes from names.

Continuation preserves the validated native function-call namespace under a
plan-specific format and the existing content/call binding checks. The ordinary
Provider must reject that format; the plan Provider rejects incompatible opaque
API-key/native state. Neither path mutates canonical history or invents state.

The cited preview contract does not establish plan support for native compaction
or requesting/replaying encrypted reasoning. Initially omit `include`, expose
no native compaction witness, and locally refuse native checkpoints, conversation
controls and encrypted/compaction continuation. Unexpected encrypted reasoning
or compaction output is unsupported, not automatically discarded or retried.
Visible reasoning can use existing event validation, without claiming eligibility
for every plan model's continuation requirements. Native/encrypted support needs
separate qualification; no opt-in field asserts that a mock proves it.

## Errors, lifecycle and catalog

Reuse strict completion, usage, output validation and cancellation: delta text
or a clean EOF without `response.completed` is not success. A mid-stream
`response.failed` terminates with the classified error and no completed event.
Map `subscription_sharing_usage_limit_exceeded` to rateLimited and
`subscription_sharing_usage_unavailable` to unavailable, with fixed public
diagnostic reason codes so Host can distinguish plan limits from generic
failures. Existing authentication and permissionDenied kinds handle 401/403.
Other documented plan admission errors use a small allowlist, not arbitrary
vendor text. Preserve retry-after where applicable; never infer plan reset time.
No adapter retry, auto-refresh, billing fallback or tool replay.

Classify non-200 plan bodies through a bounded reader (64 KiB), retaining status
classification if malformed/oversized/interrupted. Sanitized errors exclude
vendor messages, response bodies and tokens. Cancellation is rethrown. Ordinary
HTTP/SSE error handling remains unchanged unless a shared correctness regression
is independently demonstrated and reviewed.

The catalog decodes the actual plan `models` array; keeps only
`visibility == "list"` in server order; ModelID/deploymentID use `slug`, UI label
uses `display_name`. Catalog scope distinguishes this dialect and the Host's
account authorization scope. It does not fabricate metadata, sort models,
assume ordinary API `data` shape or advertise unsupported detail/pagination.
Reject unsupported cursor/page-size requests locally. Apply existing 2 MiB
response bounds, token rotation/cancellation and catalog error semantics.

## Verification and renewed release seal

TDD uses captured outgoing Swift-encoded bodies and HTTP/SSE fixtures, not paid
live calls. First retain a compiling RED against the old encoder/decoder/catalog
contract; then test the new public adapter. Cover text/images/system/developer,
forbidden fields, namespace calls and full tool-result follow-up, namespace
tampering across start/done/final, incomplete/truncated/failed streams, two plan
failure codes, HTTP auth/permissions, sanitized token-source errors, token rotation,
late-token cancellation, no repeated tool execution, catalog order/filter/shape
and bounds. Include an external public-only consumer using a temporary Journal
and a deterministic transport; verify drain and close/reopen preserve execution
facts and canonical instructions/tools. Existing API-key contracts stay green.

Update Provider guide, source compatibility/versioning, CHANGELOG and RC6 release
and candidate acceptance documents. Independent review must inspect final diff
and actual tests. Merge via normal PR/checks; verify actual new main and full
applicable CI. Then repeat the publication gates against the newly fixed target:
anonymous cold revision consumer, immutable annotated tag, exact tag checkout CI,
cold exact-version consumer, published GitHub Pre-release. Historical green/failed/
cancelled evidence remains attributed to its actual source. #105 remains OPEN.

This acceptance establishes SDK wire/lifecycle behavior only. Real account/model
availability, current plan service qualification and OtohaAI product integration
remain explicit subsequent Host tasks.
