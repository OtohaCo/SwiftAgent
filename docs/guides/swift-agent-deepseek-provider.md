# DeepSeek Responses Provider

> last-verified: 2026-09-19

`AgentProviders` includes `DeepSeekResponsesProvider`, an independent adapter
for DeepSeek's stateless Responses API.

```swift
import AgentCore
import AgentModels
import AgentProviders

let provider = try DeepSeekResponsesProvider(
    apiKey: ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]!,
    reasoningEffort: .high
)

let agent = try Agent(
    model: ModelID(provider: "deepseek", name: "deepseek-flash"),
    provider: provider
)
```

The default endpoint is `https://api.deepseek.com/responses`. The adapter sends
the complete canonical transcript in `input` on every turn. It does not send or
depend on `previous_response_id`, `conversation`, `store`, or `include`.

## Thinking And Tools

Thinking defaults to `.high`. The supported efforts are `.none`, `.low`,
`.high`, and `.max`. DeepSeek requires original plaintext reasoning on later
turns when thinking and function tools are used. The adapter stores received
`reasoning_text` items in a DeepSeek-owned opaque continuation, validates that
they still match the canonical assistant content and tool calls, and replays
them in their original item order. It never fabricates reasoning and does not
use OpenAI reasoning summaries or encrypted content.

If required reasoning state is missing, request encoding fails with
`ModelProviderError.invalidRequest` before network I/O. A `.developer` message
also fails before network I/O because DeepSeek treats that role as `user`, which
would weaken SwiftAgent's trusted developer-instruction semantics.

Function calls remain host-executed SwiftAgent tools. Provider-hosted tools and
custom `apply_patch` calls are rejected as unsupported instead of entering the
host executor. Tool policy, Evidence, authorization, mutation intent, Receipt,
and journal settlement remain AgentCore responsibilities.

Structured output uses `text.format` with a JSON Schema. Usage maps input,
output, cached-input, and reasoning-token counts without treating an absent
subset as zero. Configured model aliases must explicitly name the model ID that
DeepSeek reports in the response.

## Current Scope

The adapter supports streaming text, stateless multi-turn replay, host function
tools, JSON Schema structured output, plaintext reasoning, usage, cancellation,
and typed HTTP/provider failures. It does not support images, audio,
provider-hosted tools, custom tools, WebSocket transport, or server-side
conversation state.

Contract sources verified on 2026-09-19:

- `https://api-docs.deepseek.com/guides/responses_api`
- `https://api-docs.deepseek.com/api/create-response`
- `https://api-docs.deepseek.com/guides/thinking_mode`
