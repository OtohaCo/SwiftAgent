# Local Responses Provider

Status: Approved for SAI-071 implementation

## Goal

Add a provider for local or self-hosted OpenAI-compatible `/v1/responses`
endpoints, beginning with LM Studio, without treating wire compatibility as
OpenAI service-semantic compatibility.

## Dependency and State Boundary

`LocalResponsesProvider` remains in `AgentProviders`, which depends only on
`AgentModels`. `AgentCore` continues to own orchestration, canonical
conversation history, tool execution, cancellation, and durable restart.

Every Local request is rebuilt from the complete canonical `ModelMessage`
history. The adapter does not send `previous_response_id`, does not persist a
backend response identifier, and does not emit an opaque provider
continuation. A restarted backend or SwiftAgent process therefore resumes from
the journal-backed transcript rather than remote state.

## Shared Wire Components

- `ProviderHTTPTransport` owns HTTP streaming and physical cancellation.
- `ProviderSSEDecoder` owns SSE framing and UTF-8 boundaries.
- A shared canonical Responses input encoder owns portable message, host-tool,
  tool-result, and structured-output wire shapes.
- A shared Responses stream state machine owns lifecycle, item identity,
  deltas, terminal validation, usage, and unknown-event handling.

OpenAI-specific encrypted reasoning and native item continuation remain an
explicit OpenAI policy layered on those wire components. Local mode never
enables that policy.

## Public Surface

- `LocalResponsesProvider`
- `LocalResponsesProvider.Configuration`
- `LocalResponsesAuthentication`

Configuration requires a base URL and model, supports no authentication or a
Bearer token, and accepts explicit model capabilities. Streaming and
multi-turn canonical replay are always present. Tools, structured output, and
reasoning are opt-in because endpoint acceptance does not prove that a loaded
model can produce those shapes reliably.

## Non-goals

No Chat Completions adapter, Ollama-native API, provider discovery, model
lifecycle management, LAN scanning, GUI, provider-hosted tool execution, or
server-side continuation optimization is added in this change.
