# Anthropic Messages Provider

last-verified: 2026-09-18

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
SWIFT_AGENT_ANTHROPIC_LIVE=1 swift test --package-path SwiftAgent --filter AnthropicLiveTests
```

The live test reads ANTHROPIC_API_KEY, optional ANTHROPIC_BASE_URL and optional
SWIFT_AGENT_ANTHROPIC_MODEL. Its default is the verified available Haiku 4.5 model.
It runs a read-only Calculator with thinking disabled and enabled, checks the real
tool result, signed continuation, structured answer and usage. Missing credentials
or service failures fail an opted-in run. This is a bounded gateway verification,
not qualification of every model, endpoint, or host production path.
