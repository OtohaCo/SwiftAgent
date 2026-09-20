# AppleChatApp

AppleChatApp is the executable SwiftUI reference for app-owned conversation
lifecycle, one `AgentRun.events` consumer, tool progress, Stop and physical drain.
It defaults to a deterministic local fixture and can use the shared explicit-live
configuration from `../ProviderQualification`.

From the SwiftAgent repository root:

```sh
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
bash Examples/AppleChatApp/run-macos.sh \
  --demo "Use lookup_account for account A-100 and summarize it."
```

Live operator example:

```sh
budget="${TMPDIR:-/tmp}/swiftagent-live-budget.json"
bash Examples/AppleChatApp/run-macos.sh \
  --provider anthropic --mode live \
  --env-file /absolute/path/to/.env.live --budget-file "$budget" \
  --demo "Use lookup_account exactly once for account A-100 and summarize the observed status."
```

Missing live configuration fails visibly and never falls back to the fixture.
Every live launch also requires the shared persistent budget file shown above.
Do not place credentials in the app bundle, `Info.plist`, resources or a committed
Scheme. The app accepts OpenAI, DeepSeek and Anthropic chat providers; Jev remains
a non-conversational Decision example.

The header displays the latest Run and current in-memory Session accounting
window. Assistant turns show the current response, while provisional responses
remain separate from finalized totals. This is public-event accounting, not a
billing estimate or a persistent lifetime Session ledger; cost remains unknown.

See [the examples guide](../../docs/guides/swift-agent-examples-and-live.md),
[Apple UI ownership](../../docs/guides/swift-agent-apple-ui.md) and
[UI streaming](../../docs/guides/swift-agent-ui-streaming.md).
