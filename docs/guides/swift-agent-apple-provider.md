# Apple Foundation Models Provider

last-verified: 2026-09-19

`AgentAppleProvider` supplies `AppleFoundationProvider` for Apple's on-device
`SystemLanguageModel` and, on macOS or iOS 27, Private Cloud Compute. The
portable Engine targets do not import Foundation Models.

```swift
import AgentModels
import AgentAppleProvider

@available(macOS 26, iOS 26, *)
func makeAppleProvider() throws -> AppleFoundationProvider {
    try AppleFoundationProvider(maximumResponseTokens: 1_024)
}
```

Private Cloud Compute is an additive backend with a distinct model identity:

```swift
@available(macOS 27, iOS 27, *)
func makePrivateCloudProvider() throws -> AppleFoundationProvider {
    try AppleFoundationProvider.privateCloudCompute(maximumResponseTokens: 1_024)
}

let model = AppleFoundationProvider.privateCloudComputeModelID
```

PCC does not require an application API key. Availability remains an Apple
device, account, region, and system decision; an unavailable backend fails the
request with `ModelProviderError.Kind.unavailable`. Network failures map to
`transport`, quota exhaustion to `rateLimited`, and service outages to
`unavailable`, without exposing native diagnostics.

## Execution Boundary

Each request creates one native session with an empty native tool list. Guided
generation produces a typed enum: answer, one proposed tool call, or refusal.
The adapter emits normalized ModelEvents; only Core admits and invokes AgentTools.
Core feeds results into the next ModelRequest. The provider has no host executor,
retry loop, journal or session history of its own.

This is the structured-plan alternative from the 8095a60b review. Apple's
[native tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling)
executes registered callbacks inside the framework. This adapter instead uses
[guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
without registering those callbacks. It does not claim native-tool behavioral
parity. Model instructions do not grant authorization or prove an operation ran.

Incomplete native output, contradictory plans, unknown names and invalid raw
arguments cannot publish completed tool calls. Receipt and mutation admission
remain Core responsibilities. The adapter does not open the mutation gate.

## Capabilities and Limits

- Tool planning and multiple model turns are supported, with one native proposed
  call per response. A proposal is not execution.
- Events use the common stream interface, but text is published only after guided
  generation completes. Incremental streaming is not advertised.
- Caller-supplied structured answer schemas are explicitly rejected. The internal
  plan schema does not imply support for arbitrary structured output.
- SDK 27 response usage is preserved separately from model-generated content.
  Cache-write counts are unreported; on SDK/OS 26 all unavailable counts remain nil.
- SDK refusals remain refusals. Errors are classified without copying private
  native diagnostics. Cancellation reaches generation; as with other Swift tasks,
  cancelling a caller does not prove native work stopped immediately.
- On-device and PCC identities are explicit. SwiftAgent does not silently route
  between them, and neither backend owns a host application's domain tool catalog.

## Verification

Ordinary package tests use controlled generation fixtures. Real local inference
requires explicit opt-in:

```sh
SWIFT_AGENT_APPLE_LIVE=1 swift test --filter AppleNativeLiveTests
```

PCC has a separate operator opt-in:

```sh
SWIFT_AGENT_APPLE_PCC_LIVE=1 swift test --filter privateCloudModelProposesCalculatorWithoutOwningToolExecution
```

The live tests require an available model, execute a read-only Calculator through
Core, check actual result feedback and SDK 27 usage, and verify that a one-token
truncated response cannot complete or dispatch a tool. Unavailability or failure
is a failed opted-in test, never a pass. Default skipped live tests do not establish
device or PCC readiness. These bounded cases do not establish broad planning
reliability or production qualification.

On 2026-09-19, the opted-in on-device suite completed two cases: a one-token
truncation produced no tool execution, and a real model proposed the read-only
Calculator through two Core turns with exactly one Host execution. The separate
PCC case returned the typed `unavailable` failure on the test machine and is
therefore `BLOCKED_PLATFORM`, not a pass. See the
[qualification report](../reviews/2026-09-19-provider-live-qualification.md).
