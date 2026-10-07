# Dynamic model routing example

This fixture-first example shows the Host boundary for selecting a concrete
`AgentModelBinding` for one Run. It uses a static catalog and a local Decision
Provider by default, so it does not make network requests.

Run from the SwiftAgent repository root:

```sh
swift run --package-path Examples/DynamicModelRouting DynamicModelRouting
swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel
```

Expected fixture output includes:

```text
selection=balanced source=decision
Decision advice never authorizes or executes tools.
```

The example performs these checks before starting the Run:

- candidate capability and adapter checks;
- local/private-input policy for a remote classifier;
- finite candidate IDs only;
- conversation and catalog revision revalidation;
- cooldown and cache-aware cost policy, with unknown cost preserved as unknown.

To opt into a real TypeSafe Jev classification, set
`SWIFT_AGENT_JEV_LIVE=1`, `TYPESAFE_API_KEY`, and `TYPESAFE_MODEL` in the
process environment. The example still supplies Jev only with the task summary,
latest input, and legal candidate descriptions. Jev cannot create Evidence,
authorize or execute a tool, or settle a Journal.

## Forecast cost contract

Last verified: 2026-10-07. `RoutingUsageForecast` contains the Host's prediction
for each candidate, not measured `ModelUsage` or an actual bill. The Host must
label its forecast assumptions in the consuming product and supply that
candidate's own input, cache read, cache write and output predictions and tariff.
Do not inherit the current model's cache hits when switching models. The test fixtures
explicitly predict zero writes; this is an assumption, not a conservative
estimate for a service with write charges.

`HostPricingQuote.cacheWriteScope` defaults to `.singleCategory`: one disjoint
write category with one Host-provided `cacheWriteInputPerMillion` rate, qualified
by the quote's source/date and candidate deployment. The calculation is:

```text
ordinary = input - cacheRead - cacheWrite
cost = (ordinary × inputRate + cacheRead × readRate
        + cacheWrite × writeRate + output × outputRate) / 1,000,000
```

Writes replace ordinary input charges for those tokens; they are not an extra
full charge on all input. Test-only rates of 1, 0.1, 1.25 and 2 give `0.00515`
for 15,000 input, 12,000 reads, 3,000 writes and 100 output. These are not any
provider's current prices. The SDK core does not hardcode multipliers or supply
a complete billing system.

A known zero read/write count needs no corresponding rate. An unknown read
count, unknown single-category write count, positive count with unknown rate,
negative count/rate, overlapping categories or Decimal arithmetic failure yields
unknown cost (`nil`). Counts are validated here without changing runtime usage
validation or execution facts. `.noSeparateCharge` is an explicit Host assertion
that a verified protocol/tariff bills all non-read input at the ordinary rate;
only under that scope can unknown writes be irrelevant to the estimate. It must
not be selected merely because a service omitted the count or quote.

The router compares each candidate's own forecast and quote in the same
currency. Unknown cost cannot establish savings or justify a cost-based switch.
Summary `reportedSubtotal` values are not complete inputs unless the Host also
checks coverage, finalization and missing fields. Journal recovery does not
restore a historical usage ledger; hidden retries/internal calls are not
necessarily covered by public response events.

For complete, mutually exclusive 5m/1h writes, configure `.ttlBreakdown`, supply
`RoutingUsageForecast.cacheWriteTTL` and `HostPricingQuote.cacheWriteTTLPrices`:

```text
ordinary = input - cacheRead - write5m - write1h
cost = (ordinary × inputRate + cacheRead × readRate
        + write5m × write5mRate + write1h × write1hRate
        + output × outputRate) / 1,000,000
```

The test-only rates above plus an hourly write rate of 2 yield `0.0059` for
15,000 input, 12,000 reads, 2,000 5m writes, 1,000 1h writes and 100 output.
Aggregate writes, when reported, must equal the two TTL categories; neither
aggregate nor reasoning is charged a second time. A known aggregate zero needs
no write rates. For nonzero writes, both TTL counts are required and a positive
category needs its own rate; an unknown category is never assigned to 5m.
Partial, overlapping or inconsistent categories yield unknown cost.

`HostModelRouter.costEstimate(for:)` returns both the optional value and a
`HostCostUnknownReason`, distinguishing missing forecasts/quotes/counts/rates,
invalid classifications, invalid quote metadata and checked arithmetic failure.
Routing results also expose current/selected missing reasons so a UI can display
them. Quotes carry currency, source, `asOf`, and an
optional exact model scope; a mismatched model scope is rejected. The candidate
binding supplies the endpoint/deployment scope. Quote dates are tariff evidence,
not proof of a live bill or current account balance. No currency conversion is
performed, and different currencies never justify a switch.

Anthropic request policy and TTL preservation are implemented in the provider
and usage modules; see the [usage guide](../../docs/guides/swift-agent-usage.md).
Real gateway cache and billing effects require a separately bounded experiment,
tracked in [#89](https://github.com/OtohaCo/SwiftAgent/issues/89). Official API
prices cannot establish a subscription or gateway's effective tariff.
