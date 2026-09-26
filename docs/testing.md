# SwiftAgent Testing

last-verified: 2026-09-27

Primary compiler: Swift 6.4. From the package directory:

```sh
swift test --disable-sandbox --no-parallel
swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
bash Scripts/ci-macos.sh
bash Scripts/ci-linux.sh
bash Scripts/ci-concurrency-seal.sh
swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel
swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel
swift test --package-path Examples/DynamicModelRouting --disable-sandbox --no-parallel
swift run --package-path Examples/DynamicModelRouting DynamicModelRouting
swift test --package-path Examples/ExecutionReportingSupport --disable-sandbox --no-parallel
swift test --package-path Examples/HeadlessExecutionHost --disable-sandbox --no-parallel
swift run --package-path Examples/HeadlessExecutionHost HeadlessExecutionHostCLI failure-after-write
swift test --filter UsageLedgerTests
bash Scripts/ci-execution-reporting.sh
```

Do not treat skipped live tests as passes. Anthropic, OpenAI, Local Responses, and Apple live
tests are env-gated. OpenAI live coverage requires
`SWIFT_AGENT_OPENAI_LIVE=1`, `OPENAI_API_KEY`, and `OPENAI_MODEL`; alias users
also provide `OPENAI_RESOLVED_MODEL` when the API reports a dated snapshot.
DeepSeek has fixture/schema coverage and a recorded official qualification
matrix covering text, tools, durable restart, structured output, reasoning
metadata replay, and incomplete terminal status. This is still scoped to the
tested model/service configuration; it is not a claim about every DeepSeek
deployment.

Apple PCC remains experimental and is not live-qualified for the full
SwiftAgent Core tool loop in RC2. Fixture and compile coverage, or a signed
downstream Host's service-access test, do not establish that qualification.

Use `Examples/ProviderQualification` for credential-free fixtures, no-network
preflight and explicitly bounded live cases. Its persistent ledger defaults to
12 sends per provider and 48 total; explicit live mode never falls back to a
fixture. See the [qualification guide](guides/swift-agent-examples-and-live.md).
Usage aggregation semantics and event ownership are documented in the
[usage accounting guide](guides/swift-agent-usage.md).
Execution facts, report finality, Host authorization and failure/cancellation
handling are documented in the [execution reporting guide](guides/swift-agent-execution-reporting.md).

Local Responses fixture coverage includes canonical text/tool replay, stream
validation, cancellation, usage, and durable text/tool restart. Run the
credential-free matrix with:

```sh
swift test --filter LocalResponsesProviderTests
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode fixture --case all
```

LM Studio live qualification is operator-only and requires
`SWIFTAGENT_LOCAL_MODEL`; `SWIFTAGENT_LOCAL_BASE_URL` defaults to
`http://127.0.0.1:1234/v1`, and `SWIFTAGENT_LOCAL_API_KEY` is optional. See the
[Local Responses guide](guides/swift-agent-local-responses-provider.md).

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

## Segmented Journal qualification and benchmark

```sh
swift test --filter SegmentedJournalStoreTests --disable-sandbox --no-parallel
swift test --filter AgentMutationRecoveryTests --disable-sandbox --no-parallel
swift test --package-path Examples/ExternalClient --disable-sandbox --no-parallel
swift test --package-path Examples/HeadlessExecutionHost --disable-sandbox --no-parallel
bash Scripts/benchmark-journal.sh 240 20260927 default
bash Scripts/benchmark-legacy-journal.sh 240 20260927
```

The external client creates a real temporary file, executes a mutation,
drains, closes the store, then starts a separate fixture executable with a
different Session and the same stable operation identity. It verifies that
the settled receipt/output replay without a second file append. The fixture
provider is deterministic and uses no production credentials. The root
package also tests a competing process, SIGKILL lock release, unpublished
tails, committed corruption, fault injection around manifest publication,
automatic segment deletion, and maintenance interleaved with foreground
commits. SIGKILL covers process termination, not OS crash or power loss.

`JournalBenchmark` uses a Release build with a fixed fixture seed. Its three
cases grow redundant commits with a fixed current Session, formal content in
one Session, or unrelated Sessions plus terminal operations. JSON output
includes new-process open/recovery, p50/p95 commit time, bytes read/written,
decoded batch count, lock time, maintenance time, deleted segment bytes and
peak process RSS. Each case uses a fresh temporary directory that the script
removes afterward. The child process is new, while the OS page cache is not
controlled; do not label its open time a cold-disk measurement. Maintenance
may run during foreground work, so compare `steadyWriteBytes` with
`totalWriteBytes` and include `maintenanceCoreMs` in the cost. The script
prints the current SHA, Swift version, OS and hardware. A final benchmark
result belongs in the PR for the exact tested SHA rather than a permanent
claim of speedup in this guide.

The legacy script creates and removes its own temporary worktree at the
recorded `main` SHA, injecting only the synthetic benchmark target into that
worktree. It leaves the current branch untouched. It reports old file bytes,
new-process open/recovery and commit distributions; the old implementation
does not expose equivalent decoded-byte, lock or maintenance counters. Compare
matching scenario/seed/count rows, and report that instrumentation difference
instead of inventing legacy values.

The Pi comparison and coverage tables live in
[the conformance matrix](guides/swift-agent-conformance-matrix.md).
Named production bugs live in [testing-regressions.md](testing-regressions.md).

Dynamic model selection tests use fixture catalogs and providers. They verify
tri-state discovery metadata, bounded refreshes, immutable Run bindings,
continuation origin checks, request-only projections, context budgets, and the
Host Jev routing example. They do not call a real model service. The fixture
example must remain offline and must not be treated as live routing evidence.

New tests go in the domain file (`AgentRunTests`, `AgentContextPolicyTests`,
provider encoder tests). Do not grow a single `AgentConformanceTests.swift`.
Do not move existing files into `Regressions/` for directory cosmetics.
