# Developing with Local Models

> last-verified: 2026-09-20

This guide is for developers choosing, qualifying, and shipping a local or
self-hosted language model with SwiftAgent. It focuses on engineering decisions:
which backend/model pair is a good fit, which capabilities to declare, how to
debug failures, and when a new provider is required.

For the exact adapter API, request semantics, and qualification commands, start
with [Local Responses Provider](swift-agent-local-responses-provider.md).

## Recommended path

Use the smallest compatibility surface that preserves SwiftAgent's model
contract:

1. Prefer `LocalResponsesProvider` when the backend implements the tested
   OpenAI-compatible `/v1/responses` wire contract.
2. Start with no optional capabilities.
3. Verify plain text and streaming first.
4. Qualify the exact backend + model + model template/quantization you intend to
   use.
5. Opt in to tools, structured output, or reasoning only after that combination
   has passed the relevant checks.
6. Treat canonical SwiftAgent conversation history as the durable state. Do not
   make correctness depend on backend conversation IDs or KV cache state.

LM Studio is the first local qualification target in this repository. Other
servers are candidates only when their Responses behavior satisfies the tested
SwiftAgent contract; a similar JSON shape alone is not enough.

## Start conservatively

A text-only local configuration needs no optional capability declarations:

```swift
import AgentCore
import AgentModels
import AgentProviders

let provider = try LocalResponsesProvider(configuration: .init(
    baseURL: URL(string: "http://127.0.0.1:1234/v1")!,
    model: "<loaded-model-id>",
    authentication: .none
))

let agent = try Agent(
    model: provider.model,
    provider: provider
)
```

`LocalResponsesProvider` always declares streaming and multi-turn canonical
replay. Optional model behavior is deliberately conservative:

```swift
let provider = try LocalResponsesProvider(configuration: .init(
    baseURL: baseURL,
    model: model,
    authentication: .none,
    maximumOutputTokens: 4_096,
    capabilities: [.tools, .structuredOutput]
))
```

Do not add `.tools`, `.structuredOutput`, or `.reasoning` because the
server advertises a feature. Declare them only when the loaded model behaves
correctly for that feature.

## Choose the model for Agent work, not only chat quality

A model that writes good prose can still be a poor Agent model. Evaluate the
exact deployment on the behaviors SwiftAgent needs.

| Area | What to verify |
| --- | --- |
| Streaming | Incremental text is stable and the stream terminates cleanly. |
| Tool calling | The model emits the intended tool name, valid JSON arguments, stable call IDs, and can continue after tool results. |
| Structured output | The model/backend pair respects the supplied JSON Schema instead of merely returning JSON-looking text. |
| Context | The full canonical transcript, instructions, tool schemas, and expected output fit inside the model/server context window. |
| Reasoning | Any exposed reasoning events are compatible with the normalized contract; hidden or opaque provider state is not required. |
| Usage | Reported usage is internally consistent. Missing counts remain unreported rather than being guessed. |
| Cancellation | Cancelling a Run stops local transport work and reaches physical drain without corrupting the Session. |
| Restart | A new Session reconstructed from durable SwiftAgent history can continue without backend conversation state. |

Model size, quantization, prompt template, sampling defaults, and backend version
can all change tool and structured-output reliability. Re-run qualification
after changing any of them if the application depends on those behaviors.

## Canonical replay changes the performance model

Local Responses is intentionally stateless from SwiftAgent's perspective. Every
turn is reconstructed from canonical `ModelMessage` history. The provider does
not send `previous_response_id` and does not rely on an OpenAI-style encrypted
continuation.

That makes crash recovery and backend restarts simpler, but it also means the
backend may need to process the full conversation again. Plan for:

- increasing prompt-token cost and latency as a Session grows;
- tool schemas and structured-output schemas consuming context;
- smaller local models reaching their practical context limit earlier;
- backend KV caching being an optimization, never trusted conversation state.

Do not manually drop assistant tool calls or tool-result identity to save tokens.
If history needs to be shortened, use SwiftAgent's explicit
[Context Policy](swift-agent-context.md) and preserve the contract required by
the Agent loop.

## Tool calling recommendations

Tool support is the capability most likely to expose a weak local-model fit.

Start with one deterministic, read-only tool with a small schema. The expected
loop is:

```text
model proposes function call
        ↓
AgentCore validates and executes the registered tool
        ↓
tool result enters canonical history
        ↓
LocalResponsesProvider reconstructs the next Responses request
        ↓
model continues
```

The provider never executes a Host tool itself. Tool schema validation,
authorization, Evidence, mutation admission, Receipts, idempotency, and
settlement remain SwiftAgent responsibilities.

When expanding a local setup:

- add tools gradually instead of presenting a large registry immediately;
- keep names and descriptions precise;
- prefer narrow JSON schemas over ambiguous free-form arguments;
- verify multiple sequential tool turns, not only one call;
- verify that a model handles tool errors and still returns a valid terminal
  answer;
- qualify mutation workflows separately from basic tool calling.

A passing read-only `tool` qualification case proves model/protocol behavior;
it is not proof that an application has implemented mutation safety. Read
[Typed Tools](swift-agent-tools.md), [Evidence](swift-agent-evidence.md), and
[Receipts](swift-agent-receipts.md) before enabling writes.

## Structured output

Some local servers accept a JSON Schema field even when the loaded model does
not reliably follow it. Treat server acceptance and model reliability as
separate facts.

Recommended sequence:

1. run text and streaming first;
2. run a focused structured-output qualification case;
3. inspect failures rather than adding repair code in the provider;
4. declare `.structuredOutput` only after the exact deployment passes.

Do not silently parse arbitrary prose and report it as schema-conforming output.
SwiftAgent's structured-output contract is stronger than "the response happened
to contain JSON."

## Reasoning

Reasoning support is optional. A compatible local stream may expose normalized
reasoning text, but SwiftAgent does not invent hidden reasoning, encrypted
reasoning state, or an opaque continuation for Local Responses.

Applications should not depend on private chain-of-thought text for correctness.
Use terminal model content, tool calls, structured answers, Evidence, and Host
policy as the stable integration surfaces.

If a model/backend pair exposes reasoning events that your application needs,
qualify that exact pair and declare `.reasoning` deliberately.

## Output limits and context limits

`maximumOutputTokens` is an adapter request limit, not a guarantee that the
loaded model or server can produce that many tokens. Configure it within the
backend/model limit.

Also account for input size. A local Session request can include:

- instructions;
- the canonical conversation transcript;
- assistant tool calls and matching tool results;
- all active tool declarations;
- a structured-output schema.

When debugging a model that works on short prompts but fails later, check
context pressure before assuming a SwiftAgent state bug.

## Backend compatibility decision

Use this decision order when evaluating a local server.

### The server implements the tested Responses contract

Use `LocalResponsesProvider`, keep optional capabilities conservative, and run
qualification.

### The server implements only Chat Completions

Do not point `LocalResponsesProvider` at it and do not assume that changing an
OpenAI provider base URL creates equivalent semantics. Use a separate adapter
or a gateway that correctly translates the full SwiftAgent contract.

### The server exposes only a native API

Write a provider adapter for that API, or place a compatibility service in front
of it. The adapter still needs to preserve:

- ordered canonical messages;
- tool-call/result identity;
- normalized streaming events;
- structured-output semantics when claimed;
- cumulative usage semantics;
- typed failures;
- cancellation/drain behavior.

Protocol compatibility and provider semantics are separate concerns.

## Development topology

### Same Mac

For a server running on the same Mac as the application:

```text
http://127.0.0.1:1234/v1
```

is a common development base URL. The adapter appends `/responses`.

### iPhone or iPad talking to a Mac

On a physical iOS device, `127.0.0.1` is the device itself, not the Mac.
Supply a reachable LAN URL for the Mac and configure the Host app's Local
Network and transport-security policy as required.

SwiftAgent does not discover a model server, guess a LAN address, or change app
entitlements.

### Remote or shared self-hosted server

Treat a self-hosted endpoint as a network service, even when it runs inside
your organization.

`LocalResponsesProvider` refuses bearer authentication over clear-text HTTP
unless the destination is loopback. Use HTTPS for authenticated non-loopback
endpoints. Keep credentials out of source, prompts, logs, and shipped client
binaries.

Local inference does not make model output trusted. All normal SwiftAgent trust
boundaries still apply.

## Qualification workflow

Use the fixture suite before spending time on a live local server:

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode fixture --case all
```

For live checks, configure:

```text
SWIFTAGENT_LOCAL_BASE_URL=http://127.0.0.1:1234/v1
SWIFTAGENT_LOCAL_MODEL=<loaded-model-id>
SWIFTAGENT_LOCAL_API_KEY=        # optional
```

Then run no-network preflight:

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode live --case preflight \
  --env-file Examples/ProviderQualification/.env.live
```

After preflight, exercise focused cases before `all`. Supported chat cases are
`text`, `tool`, `restart`, `structured`, `usage`, and `cancel`.

A useful progression is:

```text
text
→ tool (when used)
→ structured (when used)
→ usage
→ cancel
→ restart
→ all
```

Use the same persistent budget ledger for an operator session. A missing server,
missing model, unsupported capability, or failed request is unavailable/failed
evidence, never a passing live test. See
[Examples and live qualification](swift-agent-examples-and-live.md) for the
full operator workflow.

## Debugging order

When a local model fails, isolate the layer instead of changing multiple things
at once.

1. **Configuration** — confirm base URL, model ID, authentication, and output
   limit.
2. **Transport** — confirm the endpoint is reachable from the process/device.
3. **Plain text** — prove a minimal streamed response before tools.
4. **Capability declaration** — make sure the request is not using a capability
   that was intentionally left undeclared.
5. **Model behavior** — verify the exact model/template/quantization can perform
   the requested tool or schema task.
6. **Context pressure** — retry with a short canonical transcript and minimal
   tool set.
7. **Terminal consistency** — check malformed SSE, contradictory terminal
   events, or post-terminal data.
8. **Restart** — verify behavior without relying on backend process memory.

Do not "fix" a malformed backend by fabricating usage, tool IDs, reasoning
metadata, or terminal events inside the application.

## Re-qualification triggers

Re-run the relevant live cases when changing any of the following:

- model ID or model weights;
- quantization;
- prompt/chat template;
- local server implementation or version;
- tool registry or tool schema;
- structured-output schema strategy;
- context size or output-token limits;
- authentication/reverse-proxy layer;
- device/network topology.

Record the exact combination you qualified. "Works with LM Studio" or "works
with model family X" is too broad to be useful evidence.

## Production-readiness checklist

Before depending on a local model in an application, verify all items that apply:

- SwiftAgent revision and documentation revision match.
- The exact backend/model deployment has passed live text qualification.
- Every declared optional capability has a corresponding successful live check.
- Tool continuation works across more than one model turn if tools are used.
- Structured output has been tested with the application's real schema shapes.
- Cancellation reaches the expected logical termination and physical drain.
- Durable restart succeeds without backend conversation state.
- Context growth has been measured on realistic Sessions.
- Usage is treated as reported/unknown rather than synthesized.
- Non-loopback bearer authentication uses HTTPS.
- iOS Local Network / transport configuration is owned by the Host app.
- Model output remains untrusted; mutation safety still uses SwiftAgent's
  Evidence, authorization, Receipt, and Journal contracts.
- Server/model lifecycle, health checks, model loading, and hardware monitoring
  are owned outside AgentCore.

## What SwiftAgent intentionally does not manage

The Local Responses adapter is not a local-model runtime. It does not:

- download or update model weights;
- choose a quantization;
- start or stop LM Studio or another inference server;
- manage GPU/CPU memory;
- discover endpoints;
- select a model automatically;
- translate native Ollama-style APIs;
- turn Chat Completions into Responses;
- make provider-native conversation state durable.

Keep those concerns in the Host application or inference-service layer. SwiftAgent
owns the provider-neutral Agent contract and the boundary between model proposals
and trusted execution.
