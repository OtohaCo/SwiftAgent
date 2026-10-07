# OpenAI Responses Provider

> last-verified: 2026-10-07

`AgentProviders` includes `OpenAIResponsesProvider`, a stateless adapter for
OpenAI's Responses API.

```swift
import AgentCore
import AgentModels
import AgentProviders

let provider = try OpenAIResponsesProvider(
    apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"]!,
    reasoningEffort: .medium,
    reasoningSummary: .concise
)

let agent = try Agent(
    model: ModelID(provider: "openai", name: "your-model"),
    provider: provider
)
```

The adapter sends `store: false` and rebuilds every request from SwiftAgent's
canonical `ModelMessage` transcript. It does not use `previous_response_id` or
the Conversations API as conversation memory. Response IDs are response
metadata, not Evidence, authorization, or trusted runtime state.

SwiftAgent tool definitions are encoded as OpenAI function tools. A returned
`function_call.call_id` becomes the SwiftAgent `ToolCallID`; AgentCore then
performs schema validation, policy and Evidence checks, durable mutation
admission, execution, Receipt validation, and settlement. The next request
sends the result as `function_call_output` with the same `call_id`.

OpenAI-hosted tools such as web search, file search, code interpreter, computer
use, and MCP are not SwiftAgent `AgentTool` values. This first adapter rejects
hosted-tool output rather than routing it into the host executor and bypassing
the SwiftAgent safety chain.

## Prompt cache key

`promptCacheKey` is an optional Host-configured grouping/routing parameter,
not a cache-hit guarantee. Official [prompt caching documentation](https://developers.openai.com/api/docs/guides/prompt-caching),
verified 2026-10-07, distinguishes models before GPT-5.6 (a stable key helps
prefix-based routing) from GPT-5.6 and later (separate cache accounting groups;
the key is optional for cache optimization). Shared groups can be legitimate.
Some deployed gateways may additionally use it for session stickiness; verify
the actual gateway version and configuration rather than assuming this for all
services. No hit-rate improvement, including 97–99%, is established by this SDK's fixtures.

```swift
let provider = try OpenAIResponsesProvider(
    apiKey: apiKey,
    endpoint: gatewayURL,
    promptCacheKey: hostCacheGroup // Host-selected policy, possibly shared
)
```

Every request from this provider carries the configured value, including tool
rounds and later Runs. All Sessions sharing the provider share that value; the
SDK does not allocate a key per Session. On provider reconstruction or journal
recovery, the Host supplies its policy's key again. A gateway requiring separate
per-session keys needs a provider/binding assembled per Session by the Host.
`sessionID.uuidString` is one possible policy, not a required one. The key stays
outside model-visible messages, tool content and continuation payloads.

Empty keys, surrounding whitespace and control characters are rejected.
Without a key, the request body is unchanged. Local Responses sends this field
only when explicitly configured through `Configuration.promptCacheKey`;
service support is unknown until qualified. Anthropic, DeepSeek and Apple do
not send this OpenAI field.

## Model and endpoint-qualified cache controls

The optional `OpenAIResponsesPromptCaching` configuration binds cache controls to
an exact Responses endpoint and a Host-verified set of resolved model names. The
Host declares only capabilities confirmed for that deployed protocol. SwiftAgent
validates endpoint/model binding, required capabilities and parameter combinations
before HTTP; it does not establish a compatible gateway's support from its name.
With model aliases, qualify the resolved identity from `resolvedModelIDsByAlias`;
the request still carries the alias. New required `promptCaching:` overloads retain
all existing public initializer function signatures. Without configuration, neither
modern options nor legacy retention nor explicit markers are sent.

```swift
let endpoint = URL(string: "https://api.openai.com/v1/responses")!
let caching = OpenAIResponsesPromptCaching(
    endpoint: endpoint,
    modelNames: ["gpt-6.1-sol"], // Host-verified endpoint/model capabilities
    capabilities: [.modernControls, .prewarm],
    policy: .modern(
        mode: .explicit, ttl: .thirtyMinutes,
        breakpoints: [.init(messageIndex: 0)]
    )
)
let provider = try OpenAIResponsesProvider(
    apiKey: apiKey, endpoint: endpoint,
    promptCacheKey: hostCacheGroup, promptCaching: caching
)
let request = ModelRequest(
    model: .init(provider: "openai", name: "gpt-6.1-sol"),
    messages: [.developer("Stable instructions and reference material"),
               .user([.text("Dynamic question")])]
)
```

Official protocol distinctions, verified 2026-10-07:

| Model / endpoint capability | Host policy | Wire control |
| --- | --- | --- |
| GPT-5.6 and later with modern controls | `.modern(mode:ttl:breakpoints:)` | `prompt_cache_options.mode` (`implicit` / `explicit`) and `ttl: "30m"` |
| Earlier model qualified for in-memory retention | `.legacy(retention: .inMemory)` and `.legacyInMemoryRetention` capability | `prompt_cache_retention: "in_memory"` |
| Earlier model qualified for extended retention | `.legacy(retention: .twentyFourHours)` and `.legacy24HourRetention` capability | `prompt_cache_retention: "24h"` |
| Gateway / Local Responses | Host attestation for its exact endpoint, resolved model and controls | Only the declared, validated policy |

GPT-5.5 / GPT-5.5 Pro support only `24h`. Extended retention is model- and
organization-dependent; the official guide lists the eligible earlier models.
Earlier models do not support modern explicit breakpoints or prewarming. A Host
must not attest unsupported capabilities simply to pass validation. This SDK
does not guess a gateway's model generation or translate retention into modern TTL.

Breakpoints address the zero-based canonical `ModelRequest.messages` index. The
optional `contentBlock` is a zero-based index among that message's eligible encoded
input-text/image blocks. A plain-text instruction, user message or tool output is
one block at zero; the existing encoder's joined text and error envelope stay intact.
Markers are added only to supported input content, never to function calls, reasoning
continuation, tool definitions or `additional_tools`. Top-level `instructions` cannot
contain markers; this adapter already encodes instructions as canonical input messages.
Missing/ineligible targets, negative or duplicate coordinates fail locally. Each
request can create at most four cache writes; implicit mode reserves one write slot,
leaving three explicit write slots. This is a write budget, not a cap on historical
markers in the input. Keep earlier markers when appending conversation history;
the service checks the first two and latest fifty explicit boundaries, plus eligible
implicit boundaries in implicit mode, and selects the limited writes. The SDK neither
truncates nor reorders valid historical markers. Explicit mode with no markers
deliberately requests no cache writes.

Keep static reference material before a changing suffix. Requests preserve canonical
message history, continuation integrity and supplied tool-array order; sorted JSON
object keys make equivalent serialization stable. Changing tools/schemas, earlier
context/history, output schema, reasoning settings or model can change the prefix.
The SDK does not expose unapproved tools, move context, rewrite old messages or
generate per-request keys in pursuit of cache hits. The provider's configuration
and Host key persist across Runs, tool rounds and shared Sessions; rebuilding it
requires the Host to resupply both. Dynamic breakpoint coordinates must be recomputed
by the Host when its canonical context layout changes.

`LocalResponsesProvider.Configuration` has a required `promptCaching:` overload
for explicit opt-in. Its qualification URL must equal the derived `/responses`
endpoint, and its model name must match the configured local model. Nil configuration
preserves previous bytes; declaring local support is the Host's responsibility.

## Separate prewarm invocations

For an endpoint/model explicitly qualified with `.modernControls` and `.prewarm`,
`OpenAIResponsesProvider.prewarm(request:)` sends `prompt_cache_options.prewarm: true`.
Local Responses offers the same method only with equivalent Host qualification.
Normal `stream(request:)` omits prewarm, so Agent runs continue generating output.
The same configured cache key and prefix markers are used in both methods.

```swift
for try await event in provider.prewarm(request: request) {
    // Feed standard usage / responseCompleted events to the Host ledger under
    // a distinct prewarm invocation ID, including cache-write-only usage.
}
for try await event in provider.stream(request: request) {
    // Account for the generation invocation under another ID.
}
```

Prewarming is a real request with potential cache-write cost. The Host bounds its
requests/tokens/cost, consumes the complete stream before relying on preparation,
and never feeds prewarm tool proposals into an executor or adds its response to
canonical conversation history. A gateway accepting a parameter does not demonstrate
that it warmed a usable cache. Record write usage and compare subsequent reads;
the provider rejects a prewarm response that generates visible content/tools or
reports positive output tokens, retaining any usage already emitted for accounting.

## Cache usage

Completed and incomplete Responses preserve `input_tokens`, `output_tokens`,
`input_tokens_details.cached_tokens`, `input_tokens_details.cache_write_tokens`
and `output_tokens_details.reasoning_tokens` in `ModelUsage`. Missing or null
optional counts remain `nil`; explicit zero remains zero. Old models and
compatible services need not report writes. Cache read/write counts are already
included in input totals; reasoning is included in output totals.

Local Responses uses the same decoder to preserve service-reported fields.
This is not a promise that a local service caches prompts or charges for writes.
See the [usage guide](swift-agent-usage.md) for accounting and export limits.
Prices and fee categories must come from the Host's deployed tariff; official
[OpenAI pricing](https://developers.openai.com/api/docs/pricing) is not a gateway
subscription or quota schedule (reference verified 2026-10-07).

Request-level cache controls are covered by `OpenAIPromptCacheControlsTests`,
including reconstruction, canonical tool rounds and separate write-only prewarm
accounting. Live OtohaAI
reuse and gateway behavior remain [follow-up #89](https://github.com/OtohaCo/SwiftAgent/issues/89).

Structured output uses Responses `text.format` with the supplied JSON Schema.
Reasoning summaries are model-visible content and remain untrusted; reasoning
token usage is normalized into `ModelUsage.reasoningTokens`. When reasoning is
enabled, the adapter requests encrypted reasoning items and stores them only as
an opaque `ModelProviderContinuation`. The next stateless tool turn replays the
reasoning item and the original OpenAI function-item ID after validating that
the continuation still matches the canonical assistant message and tool calls.
AgentCore does not interpret this payload, and switching providers drops it.

OpenAI can resolve a convenience model alias to a dated snapshot in
`response.model`. Identity remains exact by default. Declare the expected
relationship rather than accepting arbitrary response identities:

```swift
let provider = try OpenAIResponsesProvider(
    apiKey: apiKey,
    resolvedModelIDsByAlias: [
        "model-alias": "model-snapshot"
    ]
)
```

Recoverable read-only tool failures use SwiftAgent's normal
`ToolResultMessage(isError: true)` contract. Responses has no separate error
field on `function_call_output`, so the adapter sends a JSON string containing
`is_error: true` and the model-visible `content`. This envelope never carries a
Receipt and does not weaken authorization, Evidence, mutation, or persistence
failures.

`OpenAIReasoningEffort` and `OpenAIReasoningSummary` are extensible string
values. The package provides constants for currently documented values, while
allowing a host to pass a newer vendor value without waiting for an enum case.
Actual support remains model-dependent and an unsupported value is returned as
a typed provider failure. Use `.disabled` for OpenAI's `"none"` effort value;
the distinct Swift name avoids ambiguity with an absent optional configuration.

OpenAI's `context_length_exceeded` code fails with
`ModelProviderError.Kind.contextWindowExceeded`, whether it arrives in an HTTP
400 body, an `error` stream event or `response.failed`. Stream `error` events
are read in both the documented flat shape and the nested `error` object the
live service sends. See [errors](swift-agent-errors.md#provider-context-overflow).

## Terminal And Continuation Validation

Response status and output-item status are separate contracts. Message items
must carry the expected non-null status at add, done, and final snapshot stages.
Reasoning and function-call status is optional in the current SDK schema and
may be omitted or `null`; when present it must be one of `in_progress`,
`completed`, or `incomplete` and must match the event phase. An unknown value
such as `finalized`, a contradictory known value, or final content that differs
from the streamed item fails the response before AgentCore dispatches tools.

Argument JSON completion, `function_call_arguments.done`, `output_item.done`,
and the response terminal are each validated independently. An incomplete
response can expose an incomplete call to the Run result, but AgentCore does
not execute any call from an incomplete turn.

Continuation binding preserves provider item order and the ordered visible
text/reasoning projection. Adjacent fragments of the same kind may merge;
legal cross-item streaming interleaving is preserved, while later reordering or
splitting is rejected. Payloads written before the ordered projection was added
remain readable. A function-only turn retains the native OpenAI function item
ID and status for the next stateless request. If a
reasoning item lacks encrypted content, the adapter keeps only replayable
native function state rather than inventing reasoning continuation bytes.

The live test is operator-only:

```sh
SWIFT_AGENT_OPENAI_LIVE=1 \
OPENAI_API_KEY=... \
OPENAI_MODEL=... \
swift test --filter OpenAIResponsesLiveTests
```

If `OPENAI_MODEL` is an alias whose response reports a different snapshot name,
also set `OPENAI_RESOLVED_MODEL` to that expected snapshot.

Live qualification is operator-controlled and endpoint-specific. Fixture and
hosted CI coverage do not establish official-endpoint or encrypted
reasoning-continuation coverage; candidate-specific evidence belongs in the
parent project's SAI-068 qualification task.
