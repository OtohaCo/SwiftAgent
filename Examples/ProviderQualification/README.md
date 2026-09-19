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

The default limits are 12 HTTP send attempts per Provider and 48 total. Runs
are sequential, use at most three model turns and two local read-only tool
calls, and have a 120-second deadline. Output contains only status, counts,
usage fields and sanitized request-shape evidence. It never prints credentials,
request bodies, signed/encrypted continuation data or arbitrary underlying
error descriptions.

Supported chat cases are `text`, `tool`, `restart`, `structured`, `usage`,
`cancel`, and `all`. Jev supports `noul`, `choice`, `score`, `mixed`, and `all`.
`preflight` never sends a request.
