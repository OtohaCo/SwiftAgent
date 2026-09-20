# SwiftAgent Testing

last-verified: 2026-09-19

Primary compiler: Swift 6.4. From the package directory:

```sh
swift test --disable-sandbox --no-parallel
swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
bash Scripts/ci-macos.sh
bash Scripts/ci-linux.sh
bash Scripts/ci-concurrency-seal.sh
swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
swift test --filter UsageLedgerTests
```

Do not treat skipped live tests as passes. Anthropic, OpenAI, and Apple live
tests are env-gated. OpenAI live coverage requires
`SWIFT_AGENT_OPENAI_LIVE=1`, `OPENAI_API_KEY`, and `OPENAI_MODEL`; alias users
also provide `OPENAI_RESOLVED_MODEL` when the API reports a dated snapshot.
DeepSeek has fixture/schema coverage and bounded operator evidence for one
completed reasoning/usage response. Multi-turn, tool, restart, structured and
incomplete live shapes remain unqualified, so a green package run or that one
operator case is not broad DeepSeek cloud qualification.

Use `Examples/ProviderQualification` for credential-free fixtures, no-network
preflight and explicitly bounded live cases. Its persistent ledger defaults to
12 sends per provider and 48 total; explicit live mode never falls back to a
fixture. See the [qualification guide](guides/swift-agent-examples-and-live.md).
Usage aggregation semantics and event ownership are documented in the
[usage accounting guide](guides/swift-agent-usage.md).

Provider remediation fixtures can be run directly:

```sh
swift test --filter ResponsesTerminalValidationTests
swift test --filter DeepSeekResponsesIncompleteTests
swift test --filter ResponsesContinuationIntegrityTests
swift test --filter ProviderFallbackTests
```

## What a Core test must prove

- Context: the next real `ModelRequest.messages`, not `session.history.contains`.
- Mutation: executor count, external state, journal state, receipt, settlement, replay.
- Events: `runStarted` / `runFinished` once and `wait()` matches the terminal.
- Recovery: reload the durable journal; do not only inspect the in-memory actor.
- Concurrency: gates and expectations, not `sleep`.

The Pi comparison and coverage tables live in
[the conformance matrix](reviews/2026-09-18-swift-agent-conformance-matrix.md).
Named production bugs live in [testing-regressions.md](testing-regressions.md).

New tests go in the domain file (`AgentRunTests`, `AgentContextPolicyTests`,
provider encoder tests). Do not grow a single `AgentConformanceTests.swift`.
Do not move existing files into `Regressions/` for directory cosmetics.
