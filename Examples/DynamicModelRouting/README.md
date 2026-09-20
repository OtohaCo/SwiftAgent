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
