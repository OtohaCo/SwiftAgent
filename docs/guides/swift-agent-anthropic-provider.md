# Anthropic Messages Provider

last-verified: 2026-10-07

`AnthropicProvider` implements one streaming Messages API request per ModelRequest.
It does not execute tools, keep a second conversation history, retry requests or
choose another provider. AgentCore remains the model/tool loop owner.

```swift
import AgentCore
import AgentModels
import AgentProviders

func makeCloudAgent(apiKey: String, model: String) throws -> Agent {
    let provider = try AnthropicProvider(apiKey: apiKey)
    return try Agent(model: .init(provider: "anthropic", name: model), provider: provider)
}
```

The endpoint defaults to `https://api.anthropic.com/v1/messages`; an explicit
endpoint can select a compatible gateway. HTTPS is required except for local HTTP.
The shared URLSession transport streams bytes, disables persistent caches/cookies
and stored credentials, rejects redirects, and propagates cancellation. Debug
descriptions omit provider credentials. HTTP and native API errors use sanitized
ModelProviderError categories; numeric Retry-After hints do not authorize retries.
An `invalid_request_error` whose message starts "prompt is too long" becomes
`contextWindowExceeded`; the message itself is not kept.

The native response model must match the requested model. Older Anthropic model
aliases may resolve to a dated model ID; declare that relationship explicitly so
the adapter can validate it without accepting an arbitrary model:

```swift
let provider = try AnthropicProvider(
    apiKey: apiKey,
    resolvedModelIDsByAlias: [
        "claude-haiku-4-5": "claude-haiku-4-5-20251001"
    ]
)
```

Canonical model IDs, including 4.6-generation dateless IDs, need no mapping.

## Host-configured prompt caching

Caching is opt-in through `AnthropicPromptCaching`; existing initializers keep
their original function signatures and send no cache controls. The new required
`promptCaching:` overload qualifies an exact Messages endpoint, resolved model
set, and supported controls. The Host attests those capabilities from the deployed
API/gateway version; SwiftAgent checks the binding and combinations before HTTP.
It does not infer gateway support from an Anthropic-compatible URL or model alias.
When aliases are configured, `modelNames` contains the resolved response identities,
while the request continues to send the configured alias.

```swift
let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
let caching = AnthropicPromptCaching(
    endpoint: endpoint,
    modelNames: ["claude-opus-5-5"], // Host-verified model at this endpoint
    capabilities: [.automatic, .explicitBreakpoints, .oneHourTTL],
    automaticTTL: .fiveMinutes,
    breakpoints: [.init(target: .system(index: 0), ttl: .oneHour)]
)
let provider = try AnthropicProvider(
    apiKey: apiKey, endpoint: endpoint, promptCaching: caching
)
```

The official [prompt caching protocol](https://platform.claude.com/docs/en/build-with-claude/prompt-caching),
verified 2026-10-07, supports top-level automatic `cache_control` and explicit
block controls with `type: "ephemeral"` and `ttl: "5m"` or `"1h"`. Current active
models support these controls, but platform differences remain: legacy Bedrock
integrations do not support automatic caching. Declare only capabilities verified
for the actual endpoint. Unsupported capabilities fail locally; no automatic
fallback silently removes a requested control.

Automatic caching moves the breakpoint to the last eligible block as a conversation
grows. Explicit targets are `.lastTool`, `.system(index:)`, and
`.message(index:contentBlock:)`. System indices count leading system/developer
instructions from zero. Message indices address the original `ModelRequest.messages`,
including instructions; content-block indices address that message's native encoded
blocks before adjacent same-role messages are grouped. A tool result is one outer
`tool_result` block; native assistant continuation may contain thinking followed by
tool-use blocks. Thinking/redacted thinking and empty text cannot be marked.
Missing targets, negative indices, duplicate targets and unsupported block types
fail before the request is sent.

Selecting a system breakpoint converts leading instructions into text blocks in
the same order. Each instruction after the first carries the newline that the
existing combined system string supplied; their concatenated visible text stays
the same. Without a system breakpoint, the existing joined string remains. Tools
retain their supplied order and definitions; cache controls never add hidden or
unauthorized tools. The wire encoder sorts JSON object keys and leaves array order
intact. A change in tool definitions, instruction/context content, model, images,
thinking configuration or earlier history can change the cached prefix. Place the
stable instruction/reference material first and dynamic material later in the Host;
the adapter does not rewrite history or reorder content to improve cache hits.

At most four distinct explicit/automatic slots are allowed. In actual
`tools → system → messages` order, one-hour breakpoints must precede five-minute
breakpoints. Automatic caching consumes one slot even when the final explicit
marker has the same TTL; a different TTL on the final eligible block is rejected.
The provider-wide strategy applies to every Run, tool round and shared Session.
The Host supplies it again on provider reconstruction or journal recovery; recovery
restores canonical history, not an independent vendor cache or a usage ledger.
Continuation ownership and integrity checks remain in force before markers are added.

Parameter fixtures establish request contracts rather than real cache hits.
Inspect reported reads/writes, minimum-prefix requirements and expiry at the actual
service. The OtohaAI experiment and its production routing evidence are tracked in
[#89](https://github.com/OtohaCo/SwiftAgent/issues/89).

## Model Contract

Text, returned thinking summaries, complete tool proposals, usage and terminal
reasons are normalized from [Messages streaming events](https://platform.claude.com/docs/en/build-with-claude/streaming).
SSE decoding preserves fragmented UTF-8, handles CR/LF delimiters, and rejects
unfinished or oversized frames. The per-event limit is 1 MiB. Unknown top-level
event types are ignored without emitting a ModelEvent and without closing an
active content block. Known event types with illegal structure, including an
unknown `delta.type` inside `content_block_delta`, still fail. `ping` is a
no-op. A non-default SSE `event:` name must match JSON `data.type`; mismatches
fail closed. After `message_stop`, any further semantic event also fails closed
(`ping` remains transport-level no-op). `error` follows the existing error contract. A complete proposal still
needs a valid terminal response and clean EOF before Core can dispatch it.

`AnthropicThinking` supports disabled, adaptive, or enabled with an explicit budget.
Manual budgets must be at least 1024 tokens and below the configured output limit.
Callers select a mode supported by their configured model; the adapter does not
silently switch modes. Newer models may require adaptive thinking.

StructuredOutputSchema is passed unchanged through `output_config.format` using
the [structured outputs API](https://platform.claude.com/docs/en/build-with-claude/structured-outputs).
No schema constraints are removed. Structured answers arrive as text; callers
decode them into their expected types. Initial system/developer instructions are
combined in order; later instruction placement is rejected rather than moved.
Consecutive user messages, including ordered tool results, are grouped for the API.

Usage normalizes total input from uncached input plus reported cache reads/writes,
as defined in the [cache accounting contract](https://platform.claude.com/docs/en/build-with-claude/prompt-caching#tracking-cache-performance).
Individual unreported counts remain nil, previously reported values survive sparse
updates, and reported thinking tokens remain an output subset. Invalid or decreasing
normalized usage cannot seal a successful response.

`cache_creation_input_tokens` remains the aggregate cache write count. The optional
`cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens` populate
`ModelUsage.cacheWriteTTL.fiveMinuteTokens` and `oneHourTokens`. Aggregate and TTL
detail describe the same input subset and are never added twice. Missing/null stays
unknown, explicit zero stays zero, and partial TTL detail is retained without
assigning unknown writes to five minutes. Normalized input is known only when the
ordinary input, aggregate write and read categories are all reported. An aggregate
versus TTL mismatch is retained for metering diagnostics rather than causing tool
execution or settlement to repeat. Complete, mutually exclusive TTL categories can
be priced by the Host's two qualified rates; incomplete classifications produce an
unknown cost. Prices and model-specific exceptions belong to the actual Host tariff,
not a universal SDK multiplier. See [usage accounting](swift-agent-usage.md).

## Continuation State

Complete native assistant content, including signatures and redacted thinking,
travels as a ModelProviderContinuation in canonical history. Core stores its bytes
without interpreting native frames. Before replay, this adapter checks model/format
ownership and agreement with visible content and ordered tool identities/arguments.
Another model/provider's opaque state is omitted from this endpoint's request.

Discarding tool proposals invalidates whole-response continuation state. Core drops
it from partial checkpoints and incomplete turns while retaining committed tool
results. Reasoning-only incomplete turns remain in canonical history; when no signed
state or sendable content is available, this adapter omits the empty assistant item
from the HTTP request. Continuation state is neither evidence nor an execution receipt.

## Verification

Fixtures cover request encoding, signed-state replay, errors, truncation, cancellation,
usage and the same Core tool loop. Live verification is explicitly enabled:

```sh
SWIFT_AGENT_ANTHROPIC_LIVE=1 swift test --filter AnthropicLiveTests
```

The live test reads ANTHROPIC_API_KEY, optional ANTHROPIC_BASE_URL and optional
SWIFT_AGENT_ANTHROPIC_MODEL. Its default is the verified available Haiku 4.5 model.
It runs a read-only Calculator with thinking disabled and enabled, checks the real
tool result, signed continuation, structured answer and usage. Missing credentials
or service failures fail an opted-in run. This is a bounded gateway verification,
not qualification of every model, endpoint, or host production path.

Live qualification is operator-controlled and endpoint-specific. Gateway
evidence is not an official-endpoint claim, and fixture coverage is not live
qualification; candidate-specific evidence belongs in the parent project's
SAI-068 qualification task.
