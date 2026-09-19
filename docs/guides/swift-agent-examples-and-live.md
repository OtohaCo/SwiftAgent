# Examples, credentials and live qualification

last-verified: 2026-09-19

This guide separates executable examples present at the
[source-checked baseline](../ai/start-here.md) from requirements for future
examples. Fixture UI evidence and live-service qualification remain separate.

## Existing executable entry points

| Path | What exists at the baseline |
| --- | --- |
| `Examples/ExternalClient` | An outside-the-package public-API test consumer |
| `Examples/JevDecision` | A fixture-first executable with explicit Jev live opt-in |
| `Examples/AppleChatApp` | A fixture-backed macOS SwiftUI/AppKit reference with app-owned lifecycle, direct streaming and validated buffered routes |

Run from the **SwiftAgent repository root**:

```sh
swift test --package-path Examples/ExternalClient
swift run --package-path Examples/JevDecision JevDecision
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
bash Examples/AppleChatApp/run-macos.sh
```

From a parent app repository where SwiftAgent is a submodule, prefix each
package path with `SwiftAgent/`. Inspect [Examples](../../Examples) at your
revision instead of assuming that a newer example exists in an older release.

`AppleChatApp` defaults to a deterministic local provider and read-only account
lookup tool. It accepts no key and performs no real external effect. Use the New
Conversation menu to compare direct **Streaming** with **Validated** publication.
The controller/projection tests and recorded manual scope are listed in the
[acceptance checklist](../ai/acceptance-checklist.md).

For the existing Jev live path, inject `TYPESAFE_API_KEY` through your local
credential mechanism, then run in a POSIX-compatible shell:

```sh
: "${TYPESAFE_API_KEY:?Set TYPESAFE_API_KEY locally before a live run}"
export TYPESAFE_API_KEY
SWIFT_AGENT_JEV_LIVE=1 \
  swift run --package-path Examples/JevDecision JevDecision
```

`TYPESAFE_MODEL` optionally overrides the example's model configuration.
The actual variable names and behavior are in
[the executable source](../../Examples/JevDecision/Sources/JevDecision/main.swift).
The default path uses a fixture and makes no Jev request. The current executable
reads process environment; it does not automatically load `.env`. The explicit
shell preflight above also prevents a missing key from being mistaken for a
successful live run. Do not identify fixture/live mode solely by process exit.

The example asks Noul, Choice and Score questions and produces a review proposal;
it does not authorize or execute a tool. See [Decisions](swift-agent-decisions.md).

## Credential rules

Keep keys out of source, checked-in configuration, screenshots, shell tracing,
logs and model input. Do not ask a user to paste a secret into a coding-agent
conversation. Read credentials in the host configuration layer, not in prompts
or model-selected arbitrary endpoint arguments.

A `.env.example`, if later added, contains only names and dummy placeholders;
loading it requires a real loader. Never demonstrate a production secret in
`.env.example`. Validate which settings the executable actually implements.

For an Apple app, an Xcode Run Scheme environment can support local development;
it is not a production secret-management plan. App-owned service credentials
belong in an appropriate backend/credential architecture, not a shipped binary.
User-provided keys require a separate host storage and consent policy. This
SDK does not implement the app's Keychain/settings UI.

## Requirements for new examples

Recommended examples cover model conversation, a no-side-effect local tool loop,
structured answer handling, and an Apple UI using the existing SDK. These are
implementation requirements, not current command names or directories.

Every executable example should:

- Use only public SDK imports and state its minimum SDK revision/platform.
- Default to deterministic fixture mode and label that mode visibly.
- Require explicit opt-in for real network use and label the selected provider
  and requested model without printing credentials.
- Fail clearly when explicit live mode lacks credentials or fails; never silently
  substitute a fixture, another account or another service.
- Bound requests, output and concurrency, avoid hidden retries, and show the
  actual logical outcome rather than equating stream closure with success.
- Preserve cancellation/drain ownership and provide safe synthetic inputs.

For an Apple UI, implement and test the ownership and projection designs in
[Apple UI integration](swift-agent-apple-ui.md) and
[UI streaming](swift-agent-ui-streaming.md). A compilable code fragment is not a
manually exercised application, and an SDK CI result is not a UI performance
measurement.

## Live qualification is a separate evidence layer

Offline fixtures cover malformed protocols, failure boundaries and deterministic
races. Live calls check actual request acceptance and server response shapes.
Quality evaluation checks whether the result is useful. None substitutes for the
other two. Ordinary CI remains credential-free; qualification is an explicit,
bounded operator action.

For each supported scope, record SDK commit, provider, official service versus
specific gateway, requested/resolved model identity when available, date,
scenario, request count, outcome and sanitized request IDs. Report PASS, FAIL,
NOT RUN or BLOCKED; missing credentials are not PASS. A successful request can
still be billable. Do not deliberately exhaust a quota to provoke rate limits.

Suggested representative live checks, not a claim of completed coverage:

| Surface | Checks |
| --- | --- |
| OpenAI Responses | Two text turns, local function/result/next request, encrypted continuation when configured, structured output and cancellation |
| DeepSeek Responses | Thinking settings, registered tools with text-only and tool turns, reasoning replay, argument-done event, native replay metadata and incomplete status evidence |
| Anthropic | Multi-turn, tool feedback and configured thinking continuation |
| Jev | Separate and combined Noul/Choice/Score requests, actual response membership/ranges, rubric mapping and usage |
| Apple on-device/PCC | Applicable device/OS/service availability, real planning and cancellation; not ordinary API-key setup |

Do not infer a service's complete model catalog from one successful model. Do not
force live responses to equal fixture probabilities or prose. Jev Score uses an
ordered rubric, not a universal 0-to-1 probability. Reconcile documented upstream
schema differences with actual evidence rather than arbitrary decoder relaxation.

When live behavior reveals a problem, retain a synthetic or carefully sanitized
regression preserving the relevant wire shape. Do not publish real user payloads,
keys, signed URLs or opaque vendor state by default. Mark transformed fixtures
and their provenance; a mocked encrypted value is not a proof of real replay.

## Release wording

Document fixture-verified, SDK-CI-verified, Host-integration-verified and
live-qualified scopes separately. A docs commit, a running fixture, or a skipped
live test must not upgrade the release verdict. Unverified advertised capability
must remain explicitly qualified until its agreed acceptance evidence exists.
