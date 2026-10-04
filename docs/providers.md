# SwiftAgent Providers

> last-verified: 2026-10-04

`ModelProvider` is the vendor-neutral request and event boundary. Provider
adapters translate vendor transport and stream contracts into `ModelEvent`;
`AgentLoop` remains the only tool-orchestration authority.

| Provider | Product | Platforms | Streaming | Host tools | Structured output | Reasoning | Images in (ADR 0012) | Usage | Authentication | Normal CI evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Anthropic Messages | AgentProviders | macOS, iOS, Linux | Yes | Yes | Yes | Signed thinking continuation | Base64 image blocks in user turns and tool results | Yes | API key | Fixtures; operator live test available |
| OpenAI Responses | AgentProviders | macOS, iOS, Linux | Yes | Yes | JSON Schema | Encrypted opaque continuation and visible summaries | `input_image` data URLs in user messages and tool outputs | Yes | API key | Fixtures; operator live test available |
| DeepSeek Responses | AgentProviders | macOS, iOS, Linux | Yes | Yes | JSON Schema | Plaintext opaque continuation | No; refused | Yes | API key | Fixtures; bounded terminal/usage live evidence |
| Local Responses (LM Studio qualification target) | AgentProviders | macOS, iOS, Linux | Yes | Explicit model opt-in | Explicit model opt-in | Visible normalized content only; no opaque continuation | Explicit `.imageInput` opt-in | Yes when reported | None or bearer | Fixtures; operator live qualification available |
| Apple on-device | AgentAppleProvider | macOS/iOS 26+ | No; one validated plan per request | Yes | No | Not advertised | No; refused | SDK 27 where available | None | Compile and fixtures; operator live test available |
| Apple Private Cloud Compute | AgentAppleProvider | macOS/iOS 27+ | No; one validated plan per request | Yes | No | Not advertised | No; refused | Yes where reported by SDK | None | Compile and fixtures; operator live test available |

Provider capabilities describe the adapter's declared contract, not every
feature offered by the vendor. `.imageInput` means the adapter can send images;
whether the bound model takes them is the Host's choice per Run
(`AgentImageInputPolicy`). OpenAI and DeepSeek provider-hosted tools such as
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
- [Local Responses and LM Studio](guides/swift-agent-local-responses-provider.md)
- [Apple on-device and PCC](guides/swift-agent-apple-provider.md)

## Decision Providers

Decision providers do not implement `ModelProvider`, produce conversation
turns, or participate in AgentCore fallback. They evaluate typed questions and
return untrusted advice for Host orchestration.

| Provider | Product | Platforms | Decisions | Authentication | Normal CI evidence |
| --- | --- | --- | --- | --- | --- |
| TypeSafe Jev System One | AgentJevProvider | macOS, iOS, Linux | Noul, Choice, Score | API key | Fixture protocol tests; live use is operator opt-in |

See the [Decision Provider guide](guides/swift-agent-decisions.md). A decision
cannot mint Evidence, authorize or execute a tool, create a Receipt, or settle
an AgentJournal.

Bounded operator evidence and explicit gaps are recorded in the parent
project's SAI-068 qualification task. This package guide defines the provider
contract and the commands; it is not a per-machine live-test report.
