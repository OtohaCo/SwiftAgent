# ChatGPT-plan Responses (Sign in with ChatGPT)

last-verified: 2026-10-13 (official documentation and offline SDK fixtures)

`OpenAIChatGPTPlanProvider` is an explicit model source for the public OAuth
ChatGPT-plan route. `OpenAIResponsesProvider` continues to serve ordinary API-key
requests with its existing configuration and wire behavior. Selecting a plan
Provider does not sign in, validate OAuth grants, refresh a token or enable a Host
product feature. The Host must establish consent and permission before using it.

```swift
import AgentCatalog
import AgentCore
import AgentModels
import AgentProviders

// accountTokens is a Host actor. It owns secure storage, consent and refresh.
let credentials = OpenAIChatGPTPlanCredentials(accessToken: {
    try await accountTokens.currentAccessToken()
})
let catalog = try OpenAIChatGPTPlanModelCatalogProvider(
    credentials: credentials,
    serviceInstanceID: "chatgpt-plan",
    authorizationScopeID: "host-account-partition"
)
let choices = try await catalog.listModels(.init())
// Host displays displayName, preserves ordering, and selects an actual model.name slug.
let provider = OpenAIChatGPTPlanProvider(credentials: credentials)
let agent = try Agent(model: selectedModel, provider: provider, tools: hostTools)
```

The source is awaited once per HTTP dispatch, after local validation, and never
during synchronous preflight. SDK retains the closure, not a cached token. Both
inference and catalog use the same Host-selected account source. Keep that account
stable while its conversation/opaque continuation remains in use; token refresh
does not permit silently switching accounts. Partition catalog caches by the
Host's non-secret authorization scope and invalidate them when switching accounts.
Do not use a bearer token as a scope ID. SDK descriptions/mirrors and sanitized
credential-source errors omit credentials. The Host source must also avoid logging
tokens and must cooperate with cancellation or eventually return.

Endpoints are fixed to `https://api.openai.com/v1/responses` and `/v1/models`.
Transport injection supports deterministic fixtures. There is no arbitrary
endpoint override for sending these OAuth credentials to ChatGPT backend-api or
a proxy. A proxy/sub2api flow has its own credentials and qualification contract.

## Request contract

Every HTTP inference has `store:false`, `stream:true`, and the necessary history
in `input`. Each canonical system instruction becomes a developer message in
the request view at the same position; the Session's system message remains
unchanged. Runtime root instructions come from Agent configuration, while the
Journal checkpoint stores formal conversation messages according to the existing
Session contract. Rebuild the configuration on reopen.

Current declared SwiftAgent functions are grouped inside the `swiftagent`
namespace. Canonical names, arguments and call IDs stay unchanged; namespace is
a separate wire field. Started/done/final function items must carry this expected
namespace and a currently declared function name. SDK does not guess or remove
qualified name prefixes. The normal Core tool schema/policy/Evidence/admission/
execution/Receipt/settlement chain still applies. SDK deferred declarations work
by changing the next request's supplied declarations; they do not emit vendor
tool_search or defer_loading.

Validated replayable function items use a plan-specific opaque continuation
format and existing canonical content/call binding checks. Plan and ordinary
API-key opaque formats are incompatible and fail locally when mixed. This state
does not grant authorization or permit switching accounts/deployments. Explicit
Host binding/route candidate identity remains necessary for durable origin
ownership; model name/provider equality alone is not account identity.

| Surface | SDK plan behavior |
| --- | --- |
| Text, developer/system request projection, tool results | Supported in offline wire/lifecycle fixtures |
| Images | Existing image representation and data URL encoding; selected model must accept them |
| JSON Schema output | Existing schema encoding; selected model/service still needs Host acceptance |
| Function tools and ordinary multi-turn replay | Namespaced declarations/calls, canonical pairing and local validation |
| Visible reasoning | Existing normalized event validation; reasoning capability is not advertised |
| include encrypted reasoning, encrypted replay, native compaction/checkpoints/controls | Omitted or explicitly refused; current plan qualification not established |
| Hosted tools, tool_search, custom free-text tools, files/audio/video | Not exposed by this SDK plan adapter; official service support may differ |
| API output limit/tuning/cache-retention/prewarm | No configuration/field sent; the plan route does not support max_output_tokens |
| previous_response_id / conversation storage | Omitted; history is sent in input |

The encoder allowlist currently contains only `model`, `input`, `store`, `stream`,
optional namespaced `tools` and optional structured-output `text`. It omits all
unsupported preview fields. Core deadlines, model-turn/tool-call budgets and
context projection remain effective, but no SDK setting imposes a server output
token cap on this route. Budget/estimate reserves do not become an unsupported
HTTP field. Native/encrypted output is rejected rather than stripped or retried.

## Errors and recovery

Only a validated `response.completed` can complete a plan turn. Text deltas,
EOF, `response.incomplete` or `response.failed` cannot produce a successful
terminal. A failure after visible text remains a failure, and Core will not
execute proposals from an invalid completed response. Do not replay the whole
Run because of a plan error.

| Signal | SDK classification / Host action |
| --- | --- |
| subscription_sharing_usage_limit_exceeded | rateLimited + diagnostic subscriptionSharingUsageLimitExceeded; pause plan requests, show usage/alternative-source choice; do not infer reset time |
| subscription_sharing_usage_unavailable | unavailable + diagnostic subscriptionSharingUsageUnavailable; preserve credentials, bounded Host backoff |
| 401 / invalid user or expired token | authentication; Host checks grant/account/refresh state before another request |
| 403 / ineligible or unauthorized context | permissionDenied; verify policy/permission, do not loop OAuth automatically |
| Unsupported plan capability | unsupportedCapability; change the supported request configuration before retrying |
| Unrecognized/malformed failure | Sanitized status or invalidResponse classification; no raw vendor text/token exposed |

The plan HTTP classifier reads at most 64 KiB of an error body, preserving HTTP
status/retry-after classification if the body cannot be safely read. Known codes
have fixed diagnostics; arbitrary vendor text and unknown codes are not copied
into errors. The Provider performs no retry, automatic billing fallback or token
refresh. Host-selected routing must retain existing mutation/fallback safeguards;
an error never authorizes replay of an external effect.

Cancellation is responsive at the logical Run boundary. Physical
`waitForDrain()` additionally waits for a pending Host token callback to return;
a callback which never returns can keep physical drain pending. A late token
after cancellation/deadline cannot trigger HTTP dispatch. Drain before rebuilding
a Session or inspecting/reconciling uncertain execution facts. The adapter does
not alter Run records or mutation recovery semantics.

## Model catalog and qualification

`GET /v1/models` decodes the plan `models` array, keeps `visibility == "list"`
in server order, uses `slug` as the model/deployment ID and `display_name` for
display. Capabilities remain unknown; no generic API-key `data` decoding, sorting,
pagination or model-detail request is invented. Unsupported cursor/page-size
arguments fail locally; responses use the existing 2 MiB bound.

[Public-only Host fixture](../../Examples/ExternalClient/Tests/ExternalClientTests/ChatGPTPlanPublicClientTests.swift)
uses this Provider with a deterministic HTTP transport, a real temporary File
Journal, a tool loop and close/reopen. Run it through the existing ExternalClient
test gate. [Issue #110 acceptance](../releases/issue110-acceptance.md) records
source-bound results and failures. Fixtures and CI establish SDK behavior, not
current OAuth client approval, account/model access or a working live service.
No paid live qualification or OtohaAI integration was performed here.

Official protocol sources:
[models/inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
[preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations),
[errors/recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery),
[namespaces](https://developers.openai.com/api/docs/guides/function-calling#defining-namespaces).
