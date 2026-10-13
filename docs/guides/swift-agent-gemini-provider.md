# Native Gemini Host integration

Status: SDK implementation / offline qualification for issue #112; renewed RC6
candidate acceptance is required. No paid live Google, gateway, account or model
qualification is included. OtohaAI integration is separate.

Use `GeminiProvider` for Google's documented **generateContent** dialect
(currently called Legacy), not Interactions, Vertex or Live API. The default
base URL is `https://generativelanguage.googleapis.com/v1beta`; a gateway must
implement this exact protocol. HTTPS is required except explicit loopback HTTP
fixtures. A model ID uses provider `gemini` and the model slug, without `models/`.
Credentials are a redacted async `GeminiCredentials(apiKey:)` or
`GeminiCredentials(bearerToken:)` callback. API keys enter `x-goog-api-key`, never
a query string. The Host owns refresh, scopes and account selection. Account
changes require a new binding and corresponding continuation/cache qualification.

## Native requests and thinking

```swift
let provider = try GeminiProvider(
    credentials: GeminiCredentials(apiKey: { try await hostKeys.currentKey() }),
    thinking: GeminiThinkingConfiguration(level: .low, includeThoughts: true),
    preservedThinking: .requireCurrentTurnFunctionSignatures,
    maximumOutputTokens: 4096,
    authorizationScopeID: "selected-account-v1")
```

`level` and `budget` are mutually exclusive. The adapter validates field bounds;
the Host must qualify which model/endpoint accepts them. It does not infer
capabilities, account dates or tariffs from names or keys. Streaming defaults to
`streamGenerateContent?alt=sse`; `streaming: false` uses `generateContent`.
Text/thought deltas are incremental. Completed calls and the opaque continuation
are emitted only after a validated finish reason and clean HTTP EOF. Partial
output followed by a stream/transport error does not authorize tools or complete
a Run. Safety refusal and truncation retain visible words without executable
calls. Unknown finish reasons are invalid responses.

Opaque continuations retain every received native part, including signed text,
function calls, empty signature-only text, `thought` flags, signatures and
optional vendor IDs. Replay checks exact UTF-8 correspondence to canonical text,
reasoning and calls plus model/endpoint origin. It does not cryptographically
validate a signature. `.preserve` supports ordinary legacy replay;
`.requireCurrentTurnFunctionSignatures` additionally requires the received
signature on the first function-call part of every step since the latest formal
user message. Later parallel calls may be unsigned. Function-result-only wire
user messages do not start a new turn. All calls in a step precede the ordered
batch of paired function responses. Missing/tampered continuation or incomplete
pairing fails locally before credentials/HTTP; completed tools are not repeated.

Ordinary deferred tool declarations may expand between requests and reset on the
next Run while exact native parts remain intact. This differs from Anthropic's
prefix-binding policy. Explicit cached resources freeze tools and reject changes.
Existing Core projection/source/effect-proof rules still apply; this adapter
grants no arbitrary in-Run signed-history compression or native compaction.

The same encoded Data is checked and sent. The conservative default ceiling is
100,000,000 bytes, including base64, escaping, system, schemas and full wire
history; `maximumRequestBytes` may lower it for a gateway. Core raw-image selection
is a separate bound. `maximumResponseBytes` bounds adapter accumulation (default
16,000,000); SSE frames retain the existing decoder bounds. This does not prove
all custom transports or Jev allocations are bounded and does not resolve #61.

## Typed attachments and storage

```swift
let file = try ModelFileReference(
    uri: URL(string: "https://files.example/immutable-report.pdf")!,
    mediaType: .pdf, description: "immutable report", estimatedInputTokens: 2000)
let binding = try AgentModelBinding(
    profileID: "gemini", profileRevision: "1",
    model: ModelID(provider: "gemini", name: "host-qualified-model"),
    provider: provider,
    deployment: AgentModelDeployment(serviceInstanceID: "selected-account-v1",
        endpointScope: GeminiProvider.defaultBaseURL.absoluteString,
        apiDialect: "gemini-generate-content"),
    fileInput: .native())
let journal = try await AgentIncrementalJournal.createAsync(
    at: directory, operationDomain: "host-domain", supportsFileContent: true)
let session = try Agent(binding: binding).makeSession(journal: journal)
let run = try await session.run(AgentRunInput(text: "Read the report", attachments: [.file(file)]))
let result = try await run.wait()
try await run.waitForDrain()
```

These snippets are integration sketches; the executable public-only fixture is
[GeminiPublicClientTests](../../Examples/ExternalClient/Tests/ExternalClientTests/GeminiPublicClientTests.swift).
Run `swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel --filter GeminiPublicClientTests`.
It uses a real File Journal, attachments, signed parallel tools, one execution per
call, next-Run/reopen replay, cancellation drain and explicit cache preparation.
No internal or `@testable` access is used.

Files are bounded HTTPS references with no embedded credentials/fragment, PDF or
plain-text MIME types, a safe text substitute and explicit nonnegative Host token
estimates. The Host owns upload, access, expiration, remote bytes/immutability and
plain-text encoding. A source digest proves reference identity, not document
contents or summary semantics. SDK does not download, convert or silently remove
files. Default file policy rejects; `.describe` affects the request view only;
`.native` requires file capability and bounds the total files/estimated tokens.
A configured context estimator must include these estimates, actual declared
tools, system and output reserves; Core rejects estimates below the file floor.
Caching does not reduce the model-window budget. Keep threshold, semantic
summarization and cache version decisions in the Host.

`AgentRunInput` freezes nonempty text and ordered image/file attachments for
preflight, Run admission and canonical publication. Correlation fingerprints bind
attachments; text-only fingerprints and all old String overloads remain exact.
Queue/steering/context-control attachment inputs are not included. Enable
`imageInput: .native()` separately for images. User files are supported; URI file
tool results are locally refused because their current-turn boundary is not
qualified. Image results use documented inline function-response parts.

`supportsFileContent: true` explicitly creates schema **13**, including prior store
capabilities. Default schema3, other opt-ins and their signatures are unchanged.
No schema3–12→13 upgrade exists; do not treat a new store as recovery for uncertain
mutations. The schema11→12 handoff upgrade is unchanged. Older schema12 readers
refuse schema13 before inspect/append/maintenance, including empty stores. Native
references survive maintenance and reopen. New `.file` requires downstream
exhaustive `ModelContent` switches to be updated; no ABI stability is promised.

## Explicit and implicit cache lifecycle

Implicit caching is service managed: `.implicit` adds no fake enable flag and
promises no hit. Usage alone reports observed cached tokens. For explicit caches,
the Host calls `GeminiCachedContentClient.create(prefix:ttl:)` outside a Run with a
closed, bounded canonical prefix and stable authorization scope. The client
freezes actual source contents/system/tools/model/endpoint/account scope and
returns `GeminiCachedContentBinding` with server resource name and expiry.

```swift
let cacheClient = try GeminiCachedContentClient(credentials: credentials,
    authorizationScopeID: "selected-account-v1")
let cached = try await cacheClient.create(prefix: closedPrefix, ttl: .seconds(3600))
let cachedProvider = try GeminiProvider(credentials: credentials,
    authorizationScopeID: "selected-account-v1", promptCaching: .explicit(cached))
// Requests retain the full canonical prefix and append a nonempty new suffix.
// Later, when Host policy permits:
try await cacheClient.delete(cached)
```

Generation requires exact source prefix/system/tools/model/endpoint/account and
unexpired binding. Only the frozen wire prefix/system/tools are omitted; the
request adds `cachedContent`. Expiry is rechecked after a pending credential
callback. Changed projection, deferred declarations or account locally rejects
before HTTP. Missing/expired remote cache returns a classified failure; there is
no automatic recreation, deletion, fallback/resend or Run replay. Bindings have
no public forging initializer and no SDK persistence database. Host controls
cost, lifetime and persistence strategy. Remote cache is not Journal/effect proof.

## Catalog, errors and recovery

`GeminiModelCatalogProvider` uses native `models.list` pagination, preserving
server order/display names/token limits and filtering advertised generateContent
support. Cursors bind exact endpoint/account/service/page-size scope. Capability
facts remain unknown; visibility is not qualification for tools/thinking/files/
cache. Host catalog caches must partition the same nonsecret scope and invalidate
on account/endpoint changes.

Prompt counts include cached input as a subset; reported output is candidates
plus thoughts when available, with thoughts as a subset. Sparse cumulative counts
merge without adding cached tokens again. Unknown counts/tariffs remain unknown.
HTTP status and known stream error envelopes classify authentication, permission,
invalid request, selected-model quota/rate limit and service unavailability with
sanitized diagnostics. No arbitrary vendor text/key/signature/URI is included in
errors. Retry-After is retained when supplied as a valid HTTP header. No automatic
retry, account switch or fallback billing route is added.

Cancellation/deadline follow normal Core contracts. A late credential callback
cannot dispatch; physical drain still waits for it to return. Host callbacks must
cooperate with cancellation or eventually return. Drain the corresponding Run
before fresh Session recovery; reconciliation requires Host-verified facts and a
fresh same-ID actor on the same Journal. Do not reuse stale cached history or
rewrite a former logical terminal. Canonical history, tool results and receipts
remain complete after a later request/cache/replay refusal.

| Path | RC6 local scope | Live qualification |
| --- | --- | --- |
| Text, JSON schema, user images/PDF/plain-text refs | Swift encoder + HTTP/public fixture | Not run |
| Signed ordered continuation, parallel/sequential functions | Local policy/replay, preserve or explicit strict profile | Not run; fixture signatures are opaque values |
| Unsigned legacy path | Preserve profile | Not run |
| Implicit/explicit cachedContents, models.list | Bounded HTTP fixtures / scoped witnesses | Not run; no hit/model/account claim |
| File tool results, audio/video/image output, hosted tools | Local refusal | Unsupported in this increment |
| Native compaction/trusted controls/foreign continuations | Local refusal | Unsupported |
| Interactions, Vertex, Live API, OAuth UI/refresh, uploads | Separate Host/protocol tasks | Unsupported |

Primary references: [generateContent](https://ai.google.dev/api/generate-content),
[legacy thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures),
[legacy caching](https://ai.google.dev/gemini-api/docs/generate-content/caching),
[cachedContents](https://ai.google.dev/api/caching), [models.list](https://ai.google.dev/api/models)
and [errors](https://ai.google.dev/gemini-api/docs/troubleshooting).
