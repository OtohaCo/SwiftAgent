# Apple Foundation Models Provider

last-verified: 2026-09-17

`AgentAppleProvider` supplies `AppleFoundationProvider` for the on-device
`SystemLanguageModel`. It requires an available Apple model on macOS 26 or iOS 26
or later. The portable Engine targets do not import Foundation Models.

```swift
import AgentModels
import AgentAppleProvider

@available(macOS 26, iOS 26, *)
func makeAppleProvider() throws -> AppleFoundationProvider {
    try AppleFoundationProvider(maximumResponseTokens: 1_024)
}
```

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
- This provider does not implement Private Cloud Compute, production backend
  routing or the full Otoha tool catalog.

## Verification

Ordinary package tests use controlled generation fixtures. Real local inference
requires explicit opt-in:

```sh
SWIFT_AGENT_APPLE_LIVE=1 swift test --package-path SwiftAgent --filter AppleNativeLiveTests
```

The live tests require an available model, execute a read-only Calculator through
Core, check actual result feedback and SDK 27 usage, and verify that a one-token
truncated response cannot complete or dispatch a tool. Unavailability or failure
is a failed opted-in test, never a pass. Default skipped live tests do not establish
device readiness. These bounded cases do not establish broad planning reliability
or production qualification; migration acceptance remains in SAI-023/024.
