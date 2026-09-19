# SwiftAgent Testing

last-verified: 2026-09-18

Primary compiler: Swift 6.4. From the package directory:

```sh
swift test --package-path SwiftAgent
swift test --package-path SwiftAgent/ExternalClient
bash Scripts/ci-linux.sh
```

Do not treat skipped live tests as passes. Anthropic, OpenAI, and Apple live
tests are env-gated. OpenAI live coverage requires
`SWIFT_AGENT_OPENAI_LIVE=1`, `OPENAI_API_KEY`, and `OPENAI_MODEL`; alias users
also provide `OPENAI_RESOLVED_MODEL` when the API reports a dated snapshot.

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
