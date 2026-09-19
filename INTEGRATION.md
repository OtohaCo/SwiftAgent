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
example acceptance requirements. They do not add an executable Apple UI sample,
media provider, broadcast event API or background execution entitlement.

The source-checked baseline is
`c5f08c7520c989cf01234e19c1fd011b486ca76f` on the RC.2 development line.
This is not a release declaration or live-test result. Use documentation from the
same revision as the dependency installed in your app.
