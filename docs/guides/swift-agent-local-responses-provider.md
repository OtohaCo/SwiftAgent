# Local Responses Provider

> last-verified: 2026-09-20

`AgentProviders` includes `LocalResponsesProvider` for local or self-hosted
endpoints that implement the tested OpenAI-compatible `/v1/responses` wire
contract. LM Studio is the first qualification target. Compatibility with one
wire format is not a claim that the backend implements OpenAI's server-side
conversation or opaque reasoning-continuation semantics.

```swift
import AgentCore
import AgentModels
import AgentProviders

let provider = try LocalResponsesProvider(configuration: .init(
    baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
    model: "<your-model>",
    authentication: .none,
    capabilities: [.tools, .structuredOutput]
))

let agent = try Agent(model: provider.model, provider: provider)
```

The base URL stops before `/responses`; the provider appends that path while
normalizing a trailing slash. A bearer token is optional. Bearer credentials
require HTTPS except for loopback development endpoints, so a token is not sent
in clear text to an arbitrary LAN host.

## Canonical replay

The provider sends the complete canonical `ModelMessage` transcript on every
turn. It never sends `previous_response_id`, does not use a backend response ID
as durable state, and does not create an OpenAI encrypted continuation. A
durable `AgentJournal` restores canonical conversation history; the next local
request is reconstructed from that history even if the backend process was
restarted.

Assistant tool calls become Responses `function_call` input items. Matching
SwiftAgent tool results become `function_call_output` items with the current
call ID. `LocalResponsesProvider` never receives or invokes a Host executor:
schema validation, policy, Evidence, mutation admission, execution, Receipt
validation, and settlement remain AgentCore and AgentTools responsibilities.

Reasoning text that the compatible stream safely exposes can be published as
ordinary normalized reasoning content. Provider-native opaque or encrypted
reasoning state is not invented or replayed. Configure `.reasoning` only when
the selected backend and model have been qualified for that contract.

## Capabilities

Streaming and multi-turn canonical replay are always declared. Tool and JSON
Schema structured-output support are conservative opt-ins:

```swift
let configuration = LocalResponsesProvider.Configuration(
    baseURL: baseURL,
    model: model,
    authentication: token.map(LocalResponsesAuthentication.bearer) ?? .none,
    capabilities: [.tools, .structuredOutput]
)
```

An endpoint accepting a `tools` field does not prove that every loaded model
can reliably produce valid tool calls. Omit a capability until the exact
backend/model pair has passed qualification. Requests using an undeclared
capability fail before network I/O.

## LM Studio qualification

Start LM Studio's local server and load a model that supports the scenarios you
intend to test. Then configure the shared qualification CLI:

```sh
cp Examples/ProviderQualification/.env.live.example \
  Examples/ProviderQualification/.env.live
chmod 600 Examples/ProviderQualification/.env.live

# Edit only the local file:
# SWIFTAGENT_LOCAL_BASE_URL=http://127.0.0.1:1234/v1
# SWIFTAGENT_LOCAL_MODEL=<loaded-model-id>
# SWIFTAGENT_LOCAL_API_KEY=        # optional

swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode live --case preflight \
  --env-file Examples/ProviderQualification/.env.live

swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode live --case tool \
  --env-file Examples/ProviderQualification/.env.live \
  --budget-file "${TMPDIR:-/tmp}/swiftagent-live-budget.json"
```

Use `--case all` only after preflight and a focused case succeed. Normal CI uses
fixtures and does not require LM Studio. A missing server, model, or capability
is unavailable evidence, not a passing live test.

On macOS, loopback commonly points at the same Mac. On an iPhone, `127.0.0.1`
points at the phone; supply the Mac's reachable LAN URL and configure the Host
app's Local Network and transport security policy as appropriate. The library
does not discover a server or guess an address.

## Supported boundary

The adapter covers Responses text streaming, Host function calls, canonical
multi-turn replay, optional JSON Schema structured output, provider-reported
usage, typed failures, and cancellation/stream termination. Unknown top-level
metadata events may be ignored when they cannot affect semantics; unknown
output item types, malformed tool state, terminal contradictions, or post-
terminal data fail closed.

Current qualification does not claim Ollama native APIs, Chat Completions,
provider-hosted tools, backend model management, vLLM live coverage, or
provider-native continuation optimization. Future backends should reuse this
adapter only when their Responses behavior satisfies the tested SwiftAgent
contract.
