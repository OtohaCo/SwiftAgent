# OpenAI Responses Provider

> last-verified: 2026-09-19

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

The live test is operator-only:

```sh
SWIFT_AGENT_OPENAI_LIVE=1 \
OPENAI_API_KEY=... \
OPENAI_MODEL=... \
swift test --filter OpenAIResponsesLiveTests
```

If `OPENAI_MODEL` is an alias whose response reports a different snapshot name,
also set `OPENAI_RESOLVED_MODEL` to that expected snapshot.
