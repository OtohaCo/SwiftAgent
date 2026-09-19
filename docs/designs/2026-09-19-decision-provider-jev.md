# Decision Provider Contract and Jev Adapter

status: Approved
last-verified: 2026-09-19
issue: OtohaPlayer/SwiftAgent#5 (SAI-055)

## Scope

This design adds two Linux-portable products:

- `AgentDecisions`: vendor-neutral decision requests, typed Noul/Choice/Score
  results, provider protocol, validation, usage, and classified errors.
- `AgentJevProvider`: the TypeSafe Jev System One HTTP adapter.

`AgentCore` does not depend on either product. A decision is untrusted advice.
It cannot create Evidence, authorize a tool, execute a host closure, create a
Receipt, or settle an AgentJournal.

## Protocol evidence

Sources were read on 2026-09-19:

- TypeSafe OpenAPI `0.2.0`, `https://api.typesafe.ai/openapi.json`, SHA-256
  `a191f8a7df6bd6fedced8120dd0fd106f88575d1d1c8360d08900a6c7c0360d5`.
- Official JavaScript SDK `0.6.0`, commit
  `66880ccded6cb642dc1809620c2b108c33730214`.
- Official Python SDK `0.7.0`, commit
  `2ce5c65f13646cab6e6f782328194c9d85f3300a`.

The verified wire contract is `POST /v1/systemone` at
`https://api.typesafe.ai`, authenticated with `Authorization: Bearer <key>`.
The default documented model alias is `jev-latest`.

The OpenAPI and Python SDK currently accept one Score criterion, while the
newer JavaScript SDK validates at least two. SwiftAgent adopts the conservative
two-level minimum because a score scale needs two distinct levels. This is a
recorded upstream contract discrepancy, not an inferred server guarantee.

The JavaScript SDK's `EntryType` permits a top-level null state, while OpenAPI
0.2.0 accepts only string, object, or array for `state`. The Jev adapter follows
the published HTTP schema and rejects top-level null, boolean, and number before
networking. The vendor-neutral `DecisionRequest` remains capable of carrying any
`JSONValue` so another decision provider is not constrained by Jev.

The API describes Choice and Score probability maps as summing
"approximately" to one but specifies no tolerance. The adapter validates that
each reported value is finite and in `0...1`; it does not invent a sum tolerance.

## Vendor-neutral model

`DecisionRequest` carries JSON state, named Noul questions, named Choice
questions, named Score questions, and an optional `ContinuousClock` deadline.
Question names are unique across all three groups.

- Noul asks a yes/no question and returns the probability of yes/true.
- Choice selects one named alternative and returns the selection, confidence,
  and a probability for every requested alternative.
- Score applies an ordered rubric whose zero-based position is the score level.
  It returns the expected score, confidence, the original rubric, and a
  probability for every level.

Choice criteria are represented as an ordered list rather than a dictionary so
duplicate names can be rejected before the request is encoded. Score criteria
remain an ordered list. Vendor response maps are normalized back into the
request order.

`DecisionResponse` groups answers by the same three typed categories. Extra
fields inside known vendor objects are legal extensions and are ignored.
Missing answers, unexpected answer names, answer-kind mismatches, unknown
selected choices, incorrect score indices, duplicate normalized indices, and
non-finite or out-of-range numeric values fail closed as `invalidResponse`.

The verified response schema has no success-side "unknown", "refused", or
"no result" answer variant. A successful Jev response therefore must contain
exactly one correctly typed answer for every requested question. Missing or
unknown answers are invalid responses; HTTP or transport failures remain typed
provider errors. No synthetic neutral answer is invented.

## Jev mapping

The adapter maps generic questions to the verified Jev fields:

- Noul: `{ "type": "noul", "instructions": ..., "criteria": ... }`
- Choice: `{ "type": "choice", "instructions": ..., "criteria": { ... } }`
- Score: `{ "type": "score", "instructions": ..., "criteria": [ ... ] }`

Jev state accepts a top-level string, object, or array. `AgentDecisions` keeps
state generic as `JSONValue`; `AgentJevProvider` rejects top-level null, number,
or boolean before networking because the current OpenAPI does not accept them.
Nested JSON nulls remain valid.

The response model may differ from the requested alias, as the official schema
explicitly permits alias resolution. It is retained as response metadata and
is not trusted state.

## Errors and transport

`DecisionProviderError` uses stable, extensible kind values for configuration,
authentication, permission, invalid request, rate limit, unavailable service,
transport, invalid response, and deadline failures. Messages are SDK-owned and
never include the API key, request payload, response body, endpoint query, or
underlying localized error. A safe request ID and parsed retry delay may be
retained.

The first adapter does not retry automatically. HTTP `Retry-After` metadata is
returned to the caller, which owns retry policy and the total deadline. This
prevents hidden attempts from outliving a host operation. Caller cancellation
throws `CancellationError`; an expired decision deadline throws a classified
deadline error. The underlying URLSession task is cancelled, and a late
transport completion cannot settle the call again.

`retry-after-ms`, numeric `Retry-After`, and RFC 1123 HTTP-date metadata are
parsed for the Host without triggering an adapter retry. Remote request IDs are
retained only when nonempty, control-free, and at most 256 UTF-8 bytes.

The adapter has a small private transport seam instead of depending on
`AgentProviders`. Sharing that target would couple a decision adapter to the
language-model provider module. No general HTTP framework is introduced.

## Public API rationale

Public surface is limited to what an independent Host needs:

- typed question, criterion, answer, usage, request, and response values;
- `DecisionProvider` and its descriptor/error contract;
- `JevDecisionProvider` configuration and execution.

Jev request/response DTOs, transport, endpoint parsing, and validation helpers
remain internal. The three answer categories are separate stored properties,
not a public closed enum, so a future additive decision primitive does not
force exhaustive-switch source breaks in existing clients.

## Security boundary

The API intentionally contains no executor callback and imports neither
`AgentTools` nor `AgentCore`. A Host may use a decision to construct a later
proposal, but any actual tool invocation still enters the existing Agent path:

`Decision -> proposal -> ToolPolicy -> Evidence -> authorization -> durable intent -> executor -> Receipt -> settlement`

Confidence and probability never alter this boundary.
