# SwiftAgent Decision Providers

last-verified: 2026-09-19

Decision providers answer typed questions about supplied state. They are not
language-model conversation providers and they do not run SwiftAgent tools.

## Products

- `AgentDecisions` defines the vendor-neutral contract.
- `AgentJevProvider` maps that contract to TypeSafe Jev System One.
- `AgentCore` depends on neither product.

```swift
import AgentDecisions
import AgentJevProvider
import AgentModels

let request = try DecisionRequest(
    state: .object(["message": .string("I was charged twice")]),
    nouls: [
        "billing": .init(instructions: .string("Is this about billing?")),
    ],
    choices: [
        "route": try .init(criteria: [
            .init(name: "support"),
            .init(name: "billing"),
        ]),
    ],
    scores: [
        "urgency": try .init(criteria: [.string("Can wait"), .string("Today")]),
    ]
)

let provider = try JevDecisionProvider(apiKey: apiKey)
let response = try await provider.decide(request)
```

## Decision types

- Noul returns the probability of yes or true in `0...1`.
- Choice selects one requested candidate and reports confidence plus one
  probability for every candidate.
- Score uses an ordered zero-based rubric and reports its probability-weighted
  expected score, confidence, the original legend, and one probability for
  every rubric level.

Question names are unique across categories. Choice identities are exact and
case-sensitive. Score criteria require at least two levels. The Jev adapter
validates finite numeric ranges and exact answer/candidate/index membership. It
does not enforce a probability-sum tolerance because the vendor contract says
"approximately" one without defining a tolerance.

## Jev transport

The default endpoint is `https://api.typesafe.ai/v1/systemone`; authentication
uses a Bearer API key and the default model alias is `jev-latest`. Configuration
may select another model or HTTPS endpoint. Local loopback HTTP is accepted for
controlled tests.

The adapter does not retry. `DecisionProviderError.retryAfter` exposes valid
server delay metadata so the Host can apply one total retry/deadline policy.
Caller cancellation throws `CancellationError`; deadline expiry uses
`DecisionProviderError.Kind.deadlineExceeded`. Error messages never include the
API key, request body, response body, endpoint query, or underlying error text.
Malformed or unrepresentably large retry-delay metadata is ignored; it cannot
terminate the Host process or change the classified provider failure.

The current wire schema requires exactly one answer for each request question.
Missing, extra, mismatched, or malformed answers fail closed as
`invalidResponse`; the SDK does not invent an "unknown" decision.

## Security boundary

A decision is advice. Even probability or confidence `1.0` does not:

- create Evidence;
- grant authorization or skip `ToolPolicy`;
- execute a Host closure;
- create a Receipt or journal settlement;
- replay an uncertain mutation.

If a Host converts a decision into a later tool proposal, that proposal must
enter the normal Agent/Session/Run path. See the
[security model](../security-model.md).

## Example and live opt-in

Run the deterministic fixture with no credentials:

```sh
swift run --package-path Examples/JevDecision JevDecision
```

To call Jev explicitly:

```sh
SWIFT_AGENT_JEV_LIVE=1 \
TYPESAFE_API_KEY=... \
TYPESAFE_MODEL=jev-latest \
swift run --package-path Examples/JevDecision JevDecision
```

Normal CI never requires or prints the API key. Live service qualification is
operator opt-in and is separate from fixture/schema coverage.
