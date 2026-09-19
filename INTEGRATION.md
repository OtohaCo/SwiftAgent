# Integrating SwiftAgent into an app

last-verified: 2026-09-19

Start with [the AI integration guide](docs/ai/start-here.md). It is written for
app developers and coding agents such as Codex and Claude. Repository contribution
rules remain in [CONTRIBUTING.md](CONTRIBUTING.md); they are not an app architecture.

| Task | Guide |
| --- | --- |
| Select products and use the public API | [Start here](docs/ai/start-here.md) |
| Own sessions, runs, cancellation and UI state on Apple platforms | [Apple UI integration](docs/guides/swift-agent-apple-ui.md) |
| Render streaming text, tool progress and terminal outcomes | [UI streaming](docs/guides/swift-agent-ui-streaming.md) |
| Add tools, trusted receipts or Decision/Jev advice | [Consumer recipes](docs/ai/consumer-recipes.md) |
| Configure examples and verify real services | [Examples and live qualification](docs/guides/swift-agent-examples-and-live.md) |
| Connect an app-owned speech, image, video or music service | [Host service tools](docs/guides/swift-agent-host-service-tools.md) |
| Check an integration before accepting generated code | [Acceptance checklist](docs/ai/acceptance-checklist.md) |

These guides distinguish existing SDK APIs, host design recommendations and
example acceptance requirements. The fixture-backed executable Apple UI sample
is [Examples/AppleChatApp](Examples/AppleChatApp); it does not add a media
provider, broadcast event API or background execution entitlement.

Run it from the repository root:

```sh
bash Examples/AppleChatApp/run-macos.sh
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
```

The default conversation displays incremental output. Create a **Validated**
conversation to see the same UI publish only after `ModelProviderRoute` accepts a
complete candidate. The example uses a deterministic local provider and a
read-only account lookup tool, so it needs no credentials and performs no real
external effect. Its implementation and recorded acceptance evidence are linked
from the Apple UI, UI streaming and acceptance guides above.

The source-checked baseline is
`7cc8aa6e333062ee3a20a24daed13de463008fff` on the RC.2 development line.
This is not a release declaration or live-test result. Use documentation from the
same revision as the dependency installed in your app.
