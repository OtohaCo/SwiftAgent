# SwiftAgent Providers

> last-verified: 2026-09-19

`ModelProvider` is the vendor-neutral request and event boundary. Provider
adapters translate vendor transport and stream contracts into `ModelEvent`;
`AgentLoop` remains the only tool-orchestration authority.

| Provider | Product | Platforms | Streaming | Host tools | Structured output | Reasoning | Usage | Authentication | Normal CI evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Anthropic Messages | AgentProviders | macOS, iOS, Linux | Yes | Yes | Yes | Signed thinking continuation | Yes | API key | Fixtures; operator live test available |
| OpenAI Responses | AgentProviders | macOS, iOS, Linux | Yes | Yes | JSON Schema | Encrypted opaque continuation and visible summaries | Yes | API key | Fixtures; operator live test available |
| DeepSeek Responses | AgentProviders | macOS, iOS, Linux | Yes | Yes | JSON Schema | Plaintext opaque continuation | Yes | API key | Fixtures only; no live qualification yet |
| Apple on-device | AgentAppleProvider | macOS/iOS 26+ | No; one validated plan per request | Yes | No | Not advertised | SDK 27 where available | None | Compile and fixtures; operator live test available |
| Apple Private Cloud Compute | AgentAppleProvider | macOS/iOS 27+ | No; one validated plan per request | Yes | No | Not advertised | Yes where reported by SDK | None | Compile and fixtures; operator live test available |

Provider capabilities describe the adapter's declared contract, not every
feature offered by the vendor. OpenAI and DeepSeek provider-hosted tools such as
web search, file search, computer use, MCP, and custom tools are not SwiftAgent
`AgentTool` values. The current adapters reject those output item types rather
than routing them into the Host executor.

Opaque provider continuation is replay assistance only. It is not canonical
conversation memory, Evidence, authorization, mutation state, or portable state
for another provider. The canonical transcript remains the `AgentSession`
history.

Detailed guides:

- [Anthropic](guides/swift-agent-anthropic-provider.md)
- [OpenAI Responses](guides/swift-agent-openai-provider.md)
- [DeepSeek Responses](guides/swift-agent-deepseek-provider.md)
- [Apple on-device and PCC](guides/swift-agent-apple-provider.md)
