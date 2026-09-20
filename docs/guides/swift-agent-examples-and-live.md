# Examples, credentials and live qualification

last-verified: 2026-09-19

Executable-example baseline: `c17adeb86f5ea086e9ac9f2d454a41fbe7f85455`.
Run these commands from the SwiftAgent repository root. In a parent repository
where SwiftAgent is a submodule, prefix package paths with `SwiftAgent/`.

## Executable entry points

| Path | Purpose |
| --- | --- |
| `Examples/ExternalClient` | Public-API consumption tests outside the root package |
| `Examples/JevDecision` | Small fixture-first Decision/Jev proposal example |
| `Examples/ProviderQualification` | Shared fixture/live CLI for bounded provider cases and sanitized evidence |
| `Examples/AppleChatApp` | macOS/iOS SwiftUI example reusing one Controller for fixture or explicit live chat providers |

The qualification CLI and AppleChatApp use the existing `AnthropicProvider`,
`OpenAIResponsesProvider`, `DeepSeekResponsesProvider` and `JevDecisionProvider`.
They do not implement a second provider or Agent loop.

## Configuration

Start from `Examples/ProviderQualification/.env.live.example`, but keep the real
file outside Git and restrict its local permissions. `--env-file` is parsed as
literal `KEY=VALUE` or `export KEY=VALUE` assignments. It does not execute shell,
interpolation, backticks or command substitution. Process environment values
override file values. The CLI does not probe the working directory for an
implicit `.env.live`; select a file with `--env-file` or
`SWIFT_AGENT_LIVE_ENV_FILE`.

| Provider | Credential | Model | Optional endpoint/profile |
| --- | --- | --- | --- |
| OpenAI official | `OPENAI_API_KEY` | `OPENAI_MODEL` | `OPENAI_RESOLVED_MODEL`, `OPENAI_BASE_URL` |
| OpenAI-compatible gateway | `CHAINBOW_API_KEY` | `CHAINBOW_MODEL` | `CHAINBOW_RESOLVED_MODEL`, `CHAINBOW_BASE_URL`; legacy `CHAINBOW_MODLE` is accepted |
| DeepSeek | `DEEPSEEK_API_KEY` | `DEEPSEEK_MODEL` | `DEEPSEEK_RESOLVED_MODEL`, `DEEPSEEK_BASE_URL`; legacy `DEEPSEEK_MODLE` is accepted |
| Anthropic | `ANTHROPIC_API_KEY` | `SWIFT_AGENT_ANTHROPIC_MODEL` | `ANTHROPIC_RESOLVED_MODEL`, `ANTHROPIC_BASE_URL` |
| TypeSafe Jev | `TYPESAFE_API_KEY` | `TYPESAFE_MODEL` | `TYPESAFE_BASE_URL` |

Apple on-device and PCC use platform availability rather than an API key. Do
not put cloud credentials in an app bundle, `Info.plist`, resource file or
committed Scheme. A Finder-launched app does not inherit a terminal environment;
pass an absolute `--env-file` during local operator testing or use an app-owned
secret architecture in a real product.

## Offline commands

Fixture matrix:

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider openai --mode fixture --case all
```

No-network preflight:

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider deepseek --mode live --case preflight \
  --env-file /absolute/path/to/.env.live
```

Preflight reports only mode, provider, service, redacted origin, requested model,
credential presence, budget limits and case. It reports the environment file as
`CONFIGURED` or `NONE`, never its local path or contents.

## Bounded live commands

Use one ledger across CLI and UI runs:

```sh
budget="${TMPDIR:-/tmp}/swiftagent-live-budget.json"

swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider anthropic --service official --mode live --case tool \
  --reasoning enabled \
  --env-file /absolute/path/to/.env.live --budget-file "$budget"
```

Chat cases are `text`, `tool`, `restart`, `structured`, `usage`, `cancel` and
`all`; `all` runs all six chat cases in that order. Jev cases are `noul`,
`choice`, `score`, `mixed` and `all`:

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider jev --mode live --case mixed \
  --env-file /absolute/path/to/.env.live --budget-file "$budget"
```

The default budget is 12 HTTP sends per provider and 48 total. A persistent
ledger supplied by `--budget-file` or `SWIFT_AGENT_LIVE_BUDGET_FILE` is required
for every live request; restarting a command cannot reset it. Reservations use a
separate advisory lock and re-read the latest ledger before an atomic update.
Operator concurrency remains one, each Agent Run is limited to three model turns
and two local read-only tool calls, and the default Run/request timeout is 120 seconds.

Exit codes are `0` for all selected cases passing, `2` for configuration errors,
`3` for a failed/not-exercised case or exhausted budget, and `1` for an
unclassified failure. Explicit live mode never falls back to fixtures.

Qualification usage is a case-scoped `AgentUsage` window over responses visible
to the existing event consumer. It includes all observed responses from tool and
restart loops, keeps finalized and provisional subtotals separate, and reports
per-field missing counts. HTTP `attempts` remain the independent budget-ledger
count. Hidden route candidates are outside usage coverage, and cost is reported
as `UNKNOWN`; see the [usage guide](swift-agent-usage.md).

The legacy output names `usage_input`, `usage_output`, and `usage_reasoning`
now represent reported case subtotals rather than the final response alone.
Consumers must inspect the reported/missing counts and finalized/provisional
totals; the old names are retained only to avoid a silent parser break.

The CLI prints sanitized request shape and bounded protocol metadata. It does not
print credentials, request bodies, response text, reasoning, signatures, opaque
continuation values or arbitrary underlying error descriptions. Raw wire data is
not persisted.

## AppleChatApp

Fixture mode:

```sh
bash Examples/AppleChatApp/run-macos.sh \
  --demo "Use lookup_account for account A-100 and summarize it."
```

Explicit live mode uses the same provider configuration and budget ledger:

```sh
bash Examples/AppleChatApp/run-macos.sh \
  --provider openai --service official --mode live \
  --env-file /absolute/path/to/.env.live --budget-file "$budget" \
  --demo "Use lookup_account exactly once for account A-100 and summarize the observed status."
```

The app labels `FIXTURE` or `LIVE`, provider and model without displaying a key.
It retains one event consumer, separates logical terminal from physical drain,
and keeps the local account tool read-only. Use the Stop button during an active
Run. In fixture automation, `--stop` requests Stop after startup; it is not a
timing-based proof that cancellation won.

The app uses the same `AgentUsage` component to show current response, latest
Run, and in-memory Session-window usage. Display-history trimming does not reduce
the Session total. Journal reload alone does not reconstruct earlier usage.

The package includes an iOS SwiftUI entry and cross-builds the executable target
for `arm64-apple-ios16.0`. That is not simulator/device UI acceptance. Live
Apple Foundation Models remain the opt-in tests documented in the
[Apple provider guide](swift-agent-apple-provider.md).

## Evidence boundaries

Fixture, normal CI, Host integration, live service qualification and visual UI
acceptance are separate evidence. A model that answers without calling the
required tool produces `NOT_EXERCISED`, not a fabricated pass. Missing config,
platform unavailability and exhausted budget are also distinct statuses.

The 2026-09-19 bounded operator run is recorded in
[provider live qualification](../reviews/2026-09-19-provider-live-qualification.md).
It includes successful OpenAI-compatible gateway, Anthropic gateway, Jev and
Apple on-device evidence, plus the exact DeepSeek and PCC limitations. Normal CI
remains credential-free.
