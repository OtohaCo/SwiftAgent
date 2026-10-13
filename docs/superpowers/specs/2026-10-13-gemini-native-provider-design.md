# Native Gemini generateContent provider — issue #112

Status: proposed design, awaiting user review. RC6 publication remains paused.

## Goal and baseline

Implement issue [#112](https://github.com/OtohaCo/SwiftAgent/issues/112) in SwiftAgent only, then repeat candidate acceptance before publishing RC6. The starting implementation is PR #111 head `0a6f6d5e09502347c0545d42d896e4027f5a1222`, tree `6aa33ed8a95bedb58cf012a2f69a8e1c94ee800b`. PR #111 must finish qualification and merge independently before this implementation is submitted against main.

The Host's Claude-to-Gemini gateway experiment is useful motivation, but is not native SDK or live qualification evidence. This work uses HTTP fixtures and public-client tests; it does not make paid live requests or modify OtohaAI. Issue #105's remaining long-tool-loop maintenance remains separate.

## Alternatives and decision

1. Recommended: a separate native Provider, catalog and cache client, plus bounded typed file input with an explicit durable-format gate. This provides a usable canonical contract, at the cost of a small Core/public API and reader-compatibility increment.
2. Adapter-only text/tools first, postponing files and explicit cache resources. This is smaller, but leaves material #112 requirements incomplete and cannot be called full issue acceptance.
3. Continue an Anthropic translation shim or tunnel files through arbitrary JSON. This cannot establish native signatures, file persistence or cache semantics and is excluded.

The following design selects option 1. Implementation is split into independently testable steps within one SDK task, with a final reviewed PR and renewed full RC6 acceptance.

## Protocol and configuration

`GeminiProvider` implements the existing ModelProvider, request validation and physical-drain contracts. It uses the documented `generateContent` dialect: `streamGenerateContent?alt=sse` for streamed execution and `generateContent` for an explicitly selected nonstreaming mode. The documentation currently labels this API “Legacy”; it remains the API requested by #112. Interactions, Live API and Vertex AI authentication/routing are separate protocols and are not silently substituted.

The base URL is configurable, defaulting to Google's public `v1beta` service. Validate scheme, authority and path; reject embedded credentials, query/fragment injection and malformed model names. Credentials are a redacted API-key or bearer value supplied by an async Host callback once per dispatch. API keys use `x-goog-api-key`, never URL query parameters. Cancellation is checked before and after credential acquisition; physical drain waits for a late callback to return, and a late result cannot dispatch HTTP. Gateway endpoints require their own Host qualification; a configured endpoint does not prove protocol compatibility.

`GeminiThinkingConfiguration` selects a thinking level or a budget, never both, with optional thought inclusion. Validate known wire fields and bounds, but do not guess model/account capability from a name or credential. Unsupported combinations reported by a real service remain classified failures. A preserved-thinking profile distinguishes ordinary legacy replay from explicitly enabled strict current-turn function-signature requirements; neither profile permits altering a received signature.

Encode system instructions, text, declared function tools and supported structured output through the existing canonical request contract. Unknown hosted tools, automatic native compaction, trusted context controls, audio/video/image output and foreign continuation formats are locally refused before transport. No automatic retry, fallback to another billing path, or whole-Run replay is added.

The final encoded Data is both checked and sent: a conservative 100,000,000-byte request ceiling includes base64, escaping, text, system, schemas and history. A lower configurable ceiling can support gateways. Image selection still follows the existing Core policy; a final body check is additional protection. Event/response accumulation is bounded; EOF without a validated completion is failure.

## Thought signatures and tools

Persist a Gemini-specific opaque continuation containing ordered native parts and a stable mapping between canonical tool-call IDs and optional native function-call IDs. Preserve signed text, signed function calls, empty signature-only text parts, `thought` metadata, exact signatures and part boundaries. Do not concatenate, move, manufacture or cryptographically validate signatures. Restore native parts only after checking model/endpoint origin and their correspondence to visible canonical text, reasoning and calls.

In the strict profile, every model function-call step in the current turn must retain the received signature on its first function-call part. Later parallel calls may be unsigned. A function-response-only user message does not start a new turn; do not introduce unrelated outer text beside function responses. Earlier closed-turn signatures are preserved whenever replayed. Do not impose Anthropic's whole-prefix binding on Gemini: the documented current-turn and exact-part rules are different.

Decode all calls in one model step into one canonical batch, including repeated names and parallel calls. Group the whole model call batch before its corresponding user function-response batch. Preserve native IDs when supplied; when absent, allocate unique canonical IDs and do not invent a native ID in subsequent wire responses. Validate names, argument objects, duplicate IDs and call/result pairing. Emit executable completed calls only after a clean complete response; truncation, safety refusal, malformed calls or an unfinished stream cannot authorize execution.

Text/JSON tool outputs remain structured function responses. Image tool outputs may use the documented inline function-response parts, subject to the existing image policy. URI file tool outputs are refused in this increment because an outer file part could change the documented turn boundary; user file input is supported below. A completed tool is never repeated because replay validation, cache validation or a later request fails.

Prepared summaries/excerpts retain existing Core boundaries and effect proof requirements. No new arbitrary in-Run signed-history compression is granted. Missing or altered required continuation state fails before HTTP; canonical history and execution receipts remain intact.

## Images, files and durable input

Use existing `ModelImage` for images. Add a bounded `ModelFileReference` and `.file` canonical content case for Host-managed immutable URI references with an explicit MIME type, safe text substitute and nonnegative token estimate. Initially accept PDF and UTF-8 plain-text references; reject audio/video and unsupported MIME types. Require HTTPS, bounded metadata, no embedded username/password or fragment. URI lifetime, authorization, upload, remote bytes and immutability are Host responsibilities. A URI/source digest proves identity of the supplied reference, not the remote document's semantic content or availability.

Add a new `AgentRunInput` value containing nonempty text and ordered image/file attachments, and new `Session.run` overloads for default or explicit binding/capability selection. Keep every existing String overload and initializer signature intact. This increment does not add queued attachment inputs, attachment steering, or attachment-specific context controls. These omissions are documented rather than silently dropping attachments.

Core constructs one immutable canonical user input for preflight, admission and execution. Source digests and final byte/token estimation include the selected view; file token estimates remain explicit Host estimates, never claims of exact vendor tokenization. Add a file policy with default rejection, explicit text-substitute mode, or bounded native mode requiring adapter file capability. No automatic downloading, conversion, file removal, or model-window eviction is added.

Run-record payload fingerprints bind exact attachment metadata and image identity as well as text/operation/Host digest. Preserve the existing fingerprint representation for text-only runs. A reused correlation key with changed attachments is a conflict; rejected inputs leave no admission or terminal record. Startup cancellation and replan paths use the same immutable input. Reopen preserves the canonical attachments without re-executing tools.

Add explicit opt-in `supportsFileContent` storage using schema 13, storing bounded file references in canonical checkpoints, with no second ledger or remote-byte database. Schema 3 remains the default; schemas 10/11/12 and their existing opt-ins remain unchanged. Existing schema-11-to-12 offline upgrade remains exactly that upgrade. No implicit 3–12-to-13 migration is introduced. In-memory Journal supports references; durable stores without the capability reject file input before admission. Preserve existing public create/open signatures through additional overloads.

Prove an actual older schema-12 reader refuses schema 13 before inspect, append and maintenance, with the store bytes unchanged; prove the new reader continues to read ordinary schema 3 and existing supported formats. Full public API compatibility checks cover the new content/capability enum cases and initializer overloads. Downstream exhaustive switches need to handle `.file`; this is a documented source compatibility consideration, not an ABI-stability claim.

## Prompt caching

Follow the existing provider-specific configuration pattern in `PromptCacheConfiguration.swift`; there is currently no universal public type named PromptCacheConfiguration. Add `GeminiPromptCaching` with an implicit service-managed mode and an explicit frozen cached-resource binding. Implicit mode does not invent a wire enable flag or promise a cache hit.

An explicit `GeminiCachedContentClient` lets the Host create and delete a cache resource outside a Run. The Host supplies a bounded canonical request prefix, TTL and stable authorization-scope identity. The SDK validates and freezes the actual encoded contents, system and tools, then records the returned resource name, model, endpoint, expiry and exact local source/config witness. This is a remote cache resource, not a Journal writer, execution capability or proof of tool effects. The Host controls creation policy, cost, lifetime and any persistence of the binding.

For generation, use `cachedContent` and omit only the prefix/system/tools actually present in that frozen resource. Before HTTP, require the same endpoint, model, authorization scope, unexpired resource, exact source prefix and bound system/tool definitions. Changed deferred tools, projected prefix, model or instructions fail locally; the Host may explicitly prepare a new cache/binding. Do not automatically recreate/delete caches, fall back by resending a different prefix, or rerun the Run after a cache error. Service-side missing/expired resources remain classified errors, never reported as local validation success.

Canonical history remains complete. Core's context budget still covers the full effective context, including cached tokens: caching changes billing/transport, not model-window capacity. No summary cache database or generic cross-provider cache protocol is added.

## Usage, failures and catalog

Map prompt tokens with cached input as a subset. Map output tokens to visible candidates plus thought tokens when supplied; reasoning tokens are an output subset. Preserve absent counts as unknown and merge sparse cumulative stream usage without double counting. Reject inconsistent negative counts; do not infer a cache hit or price from configuration.

Classify bounded HTTP and stream error envelopes into existing authentication, permission, invalid-request, rate-limit, unavailable, transport and invalid-response outcomes. Preserve safe Retry-After information. A 429 is scoped to the selected model/request; do not publish a global provider outage. Safety blocks produce a canonical refused result without executable calls. Invalid argument, malformed response, truncation and quota failures do not leak vendor payloads, signatures, keys, file URIs or arbitrary error text through diagnostics.

`GeminiModelCatalogProvider` implements paginated `models.list`, preserving server order and declared display/token-limit metadata. Filter entries that do not advertise generateContent support. Bind cursors to endpoint/account/request scope and bound HTTP responses. Do not infer thinking/cache/file/live qualification merely from visibility or model names.

## Acceptance and release sequence

1. Preserve actual RED/GREEN fixtures for new native encoding, ordered signature replay, parallel/sequential tool batches, usage, local rejection and request-body limits. Fixture signatures are opaque test values, not simulated vendor cryptographic verification.
2. Exercise both streaming and nonstreaming HTTP, SSE chunk boundaries, empty signed parts, blocked/truncated/malformed completions, fixed and expanded tools, current-turn source tampering, unsigned legacy paths, API-key/bearer rotation and cancellation/deadline/physical drain with a blocked credential callback.
3. Test explicit-cache creation and exact replay, prefix/config/account/model/expiry mismatch, missing resource errors, and implicit no-wire behavior. Assert transport counts and canonical history preservation.
4. Test file/image input, default rejection, native/text-substitute policies, pre-admission budget/store failures, correlation conflicts, schema-13 close/reopen, and schema-12 reader byte-preserving refusal. Add the reader gate to both applicable CI scripts without removing existing gates.
5. Add a public-API external client using a real File Journal and HTTP fixtures: one Run with attachments, thinking plus parallel tools, one execution per tool, complete canonical history, next Run/reopen replay and late-cancellation drain. Cache fixture can be separate to keep resource preparation outside the Run.
6. Reuse three independent review directions: persistence/admission/recovery; Provider encoding/signatures/cache/catalog; runtime/context/public API/docs. Resolve blocking findings and rerun affected tests after changes.
7. Complete unchanged full macOS/Linux/Apple/concurrency/compatibility gates plus the new reader gate on the final PR head. Merge through the PR, obtain actual main SHA/tree, and verify its own CI. Rewrite RC5-to-RC6 notes, support matrix and candidate acceptance around both #110 and #112, with precise failures and source identities.
8. Perform fresh anonymous revision and exact-tag public consumers, immutable annotated tag and corresponding full tag CI, then publish the authorized GitHub pre-release only after all gates pass. No earlier #110 or PR #109 green result substitutes for this final candidate. Do not move existing tags.

The release describes SDK unit/HTTP-fixture/public-client acceptance separately from live Google/gateway/account qualification and OtohaAI product acceptance. No new live qualification is claimed. Close #112 only for the documented accepted SDK scope; list unsupported file kinds, queued attachments, file tool responses, Interactions/Vertex/Live APIs, hosted tools and output media as follow-up boundaries.

## Primary protocol references

- [generateContent REST contract](https://ai.google.dev/api/generate-content)
- [generateContent thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)
- [generateContent context caching](https://ai.google.dev/gemini-api/docs/generate-content/caching)
- [cachedContents REST contract](https://ai.google.dev/api/caching)
- [models.list REST contract](https://ai.google.dev/api/models)
- [Files API and Host-managed file lifecycle](https://ai.google.dev/gemini-api/docs/files)
- [Gemini API troubleshooting](https://ai.google.dev/gemini-api/docs/troubleshooting)

Self-review: no placeholders; cache resources never grant execution authority; signatures are opaque and part-bound; file references have explicit identity/estimate/lifetime limits; old signatures and schemas remain readable; no automatic Run replay, paid live qualification or Host implementation is included.
