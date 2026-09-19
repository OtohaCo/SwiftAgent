# Integrating SwiftAgent into an app or service

last-verified: 2026-09-19

Start with [the AI integration guide](docs/ai/start-here.md). It is written for
app developers and coding agents such as Codex and Claude. Repository contribution
rules remain in [CONTRIBUTING.md](CONTRIBUTING.md); they are not an app architecture.

| Task | Guide |
| --- | --- |
| Select products and use the public API | [Start here](docs/ai/start-here.md) |
| Own sessions, runs, cancellation and UI state on Apple platforms | [Apple UI integration](docs/guides/swift-agent-apple-ui.md) |
| Run SwiftAgent behind a Linux HTTP service | [Server integration](docs/guides/swift-agent-server.md) |
| Choose Android server access or native Swift/JNI embedding | [Android integration](docs/guides/swift-agent-android.md) |
| Render streaming text, tool progress and terminal outcomes | [UI streaming](docs/guides/swift-agent-ui-streaming.md) |
| Add tools, trusted receipts or Decision/Jev advice | [Consumer recipes](docs/ai/consumer-recipes.md) |
| Configure examples and verify real services | [Examples and live qualification](docs/guides/swift-agent-examples-and-live.md) |
| Connect an app-owned speech, image, video or music service | [Host service tools](docs/guides/swift-agent-host-service-tools.md) |
| Check an integration before accepting generated code | [Acceptance checklist](docs/ai/acceptance-checklist.md) |

These guides distinguish existing SDK APIs, host design recommendations and
example acceptance requirements. The executable Apple UI sample is
[Examples/AppleChatApp](Examples/AppleChatApp). It defaults to fixtures and can
use the same explicit live configuration as the
[ProviderQualification CLI](Examples/ProviderQualification); it does not add a
media provider, broadcast event API or background execution entitlement.

Run it from the repository root:

```sh
bash Examples/AppleChatApp/run-macos.sh
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider openai --mode fixture --case all
```

The default fixture conversation displays incremental output. Create a **Validated**
conversation to see the same UI publish only after `ModelProviderRoute` accepts a
complete candidate. The example uses a deterministic local provider and a
read-only account lookup tool, so it needs no credentials and performs no real
external effect. Explicit `--mode live` uses an existing chat provider through
the same Controller and local read-only tool path; missing configuration never
falls back to the fixture. Configuration and bounded commands are in the examples
guide linked above.

The source-checked baseline is
`c17adeb86f5ea086e9ac9f2d454a41fbe7f85455` on the RC.2 development line.
This is not a release declaration or live-test result. Use documentation from the
same revision as the dependency installed in your app.

## Platform qualification boundaries

Linux SDK checks are not server deployment qualification. An Android app can call
an app-owned SwiftAgent service without embedding Swift, while native embedding
requires separate module, bridge, packaging and device tests. These guides add
neither a server executable nor Android-native support; follow their explicit
acceptance gates before making those claims.
