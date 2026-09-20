# Provider Qualification

This executable runs fixture-first, bounded qualification scenarios through the
public SwiftAgent `Agent`, `AgentSession`, `AgentRun`, tool and drain APIs. It
does not use a vendor SDK or a parallel HTTP implementation.

From the SwiftAgent repository root:

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider openai --mode fixture --case all

swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider deepseek --mode live --case preflight \
  --env-file Examples/ProviderQualification/.env.live

swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode fixture --case all
```

The `gateway` service is the explicit SUB2API qualification path. It reads
`SUB2API_API_KEY`, `SUB2API_BASE_URL`, and `SUB2API_MODEL` (with the legacy
`SUB2API_MODLE` alias) from the selected environment file. Gateway evidence is
kept separate from official OpenAI endpoint evidence.

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider openai --service gateway --mode live --case text \
  --env-file /absolute/path/to/.env.live \
  --budget-file /absolute/path/to/sub2api-budget.json
```

Live mode requires an explicit `--mode live`. A missing credential, model,
unsupported case, failed request or exhausted budget never falls back to a
fixture. Environment variables override values loaded from `--env-file`.
The file parser accepts only literal `KEY=VALUE` or `export KEY=VALUE` lines; it
does not execute shell syntax, interpolation or command substitution.

Use one budget ledger for the whole operator session:

```sh
budget="${TMPDIR:-/tmp}/swiftagent-live-budget.json"
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider anthropic --mode live --case all \
  --env-file /absolute/path/to/.env.live --budget-file "$budget"
```

The default limits are 12 HTTP send attempts per Provider and 48 total. A live
request requires a persistent ledger through `--budget-file` or
`SWIFT_AGENT_LIVE_BUDGET_FILE`; restarting a command cannot reset the recorded
attempts. Operators can explicitly raise the positive integer limits with
`SWIFT_AGENT_LIVE_PER_PROVIDER_LIMIT` and `SWIFT_AGENT_LIVE_TOTAL_LIMIT`. The
total must be at least the per-Provider limit. The budget file variable remains
a file path, not a numeric limit.
Runs are sequential, use at most three model turns and two local read-only tool
calls, and have a 120-second deadline. Output contains only status, counts,
usage fields and sanitized request-shape evidence. Usage covers every response
visible through the case's single `AgentRun.events` consumer, with separate
observed, finalized, provisional, reported and missing counts. `attempts` still
comes from the request-budget ledger; it is not inferred from response count.
Fixture cases therefore report `attempts=0` even when their Agent Run exposes
one or more model responses.
`cost=UNKNOWN` is intentional. Output never prints credentials,
request bodies, signed/encrypted continuation data or arbitrary underlying
error descriptions.

Supported chat cases are `text`, `tool`, `restart`, `structured`, `usage`,
`cancel`, and `all`; `all` runs all six chat cases. Jev supports `noul`,
`choice`, `score`, `mixed`, and `all`.
`preflight` never sends a request.

Local Responses live mode uses `SWIFTAGENT_LOCAL_BASE_URL` (default
`http://127.0.0.1:1234/v1`), required `SWIFTAGENT_LOCAL_MODEL`, and optional
`SWIFTAGENT_LOCAL_API_KEY`. The URL is a base URL; the provider appends
`/responses`. A bearer token requires HTTPS unless the endpoint is loopback.
The loaded model, not merely the server, must support the selected tool or
structured-output case. See the
[Local Responses guide](../../docs/guides/swift-agent-local-responses-provider.md).

For script compatibility, `usage_input`, `usage_output`, and
`usage_reasoning` remain present, but now mean the reported subtotal across all
responses visible in the selected case. Read the adjacent reported/missing
counts before treating them as complete. `usage_finalized_total` and
`usage_provisional_total` keep completed and in-progress response totals
separate. No field is a price or bill.

Environment files are loaded only when selected with `--env-file` or
`SWIFT_AGENT_LIVE_ENV_FILE`; the CLI does not implicitly load `.env.live` from
the working directory. Persistent reservations are serialized through a
permission-restricted lock file and re-read the latest ledger before updating.

Provider variables, service selection, exit codes, AppleChatApp integration and
the latest bounded evidence are documented in
[`docs/guides/swift-agent-examples-and-live.md`](../../docs/guides/swift-agent-examples-and-live.md).
Do not run qualification processes concurrently against the same ledger.
