# Accepting an AI-written SwiftAgent integration

last-verified: 2026-09-19

This is an acceptance checklist, not a report that the checks have run.
Use [the integration guide](start-here.md) and record the actual dependency SHA.

## Dependency and scope

- [ ] Installed SDK revision matches the documentation and example APIs.
- [ ] Public imports only; no `@testable`, package/internal calls or invented helpers.
- [ ] App deployment targets and actor-isolation settings are recorded and build.
- [ ] Core was not modified to import UI/domain/vendor services.
- [ ] Media integration, if only planned, is documented as app work rather than a shipped SDK capability.

## Ownership and UI

- [ ] Start is reserved before awaiting Session.run; rapid double Send is defined.
- [ ] Stop during startup handles both an error and a late returned Run handle.
- [ ] One consumer per Run event stream; multiple views use host snapshots.
- [ ] Session, startup, Run, observation and cleanup have explicit owners.
- [ ] Cancelling display observation is not mistaken for cancelling execution.
- [ ] Logical outcome is separate from physical drain and remote job state.
- [ ] Late old-generation events cannot repaint another conversation or clear its task handles.
- [ ] Page navigation, window close and process/background transitions have distinct policies.
- [ ] Await failure/cancellation still arranges cleanup without blocking MainActor.

## Streaming and rendering

- [ ] Text is accumulated once; terminal response/history does not duplicate it.
- [ ] Turns and tool calls are keyed by identity; parallel completion order is supported.
- [ ] Provisional deltas never establish canonical success or execution authority.
- [ ] Refused/incomplete/error/cancelled are distinct from completed.
- [ ] Tool proposal/started are never labelled as a completed external effect.
- [ ] Recoverable `ToolResultMessage.isError` is displayed as such.
- [ ] A complete snapshot may replace an older snapshot; raw deltas/receipts/terminal events are not silently dropped.
- [ ] Slow/absent display processing does not create an unexamined unbounded task queue.
- [ ] A buffered route is not advertised as real-time token streaming.
- [ ] Opaque continuation and credentials are absent from UI and diagnostics.

## Tools and recovery

- [ ] Mutation uses durable intent, trusted Receipt validation and settlement.
- [ ] Stable operation identity is reused only for the same logical mutation.
- [ ] Shared resources use the shared scheduler and current authorization/Evidence.
- [ ] No successful Receipt is fabricated in a production example.
- [ ] Unknown/cancelled is not converted into confirmed-no-effect or automatic abort.
- [ ] Restart restores canonical conversation, not trusted Evidence from model prose.
- [ ] Decision advice cannot bypass the normal execution boundary.

## Evidence to attach

Record command, toolchain/build settings, dependency SHA, scenario, actual result
and remaining limits. Keep discovered, passed, failed and skipped counts distinct.
Use deterministic barriers and worker-exit acknowledgment for non-UI race tests;
sleep and repeated `Task.yield()` are not causal completion evidence.

Build and run applicable non-UI tests. Manually exercise the UI on stated
simulator/device/OS targets: streaming, Stop, two turns, navigation, errors and
multiple windows/conversations where supported. Record actual observations;
compilation alone is not UI acceptance. This checklist does not require inventing
an automated screenshot or UI E2E framework.

For live calls, use the [qualification guide](../guides/swift-agent-examples-and-live.md).
Fixture, hosted SDK CI, Host integration and live qualification are separate
claims. Missing keys or unavailable devices are NOT RUN/BLOCKED, not PASS.

## Fresh-context documentation test

Give a separate coding-agent session only this integration entry, the actual SDK
checkout and a minimal app task. Ask it to implement a streaming conversation,
Stop and a second turn without editing the SDK. Record where it guessed API,
misread lifetime, copied a fixture as production, or needed undocumented steps.
Fix the recipe at the point of confusion, then build the resulting consumer.
Do not claim an independent review or a successful fresh-context test unless it
was actually performed.

Documentation can be source-checked without Apple UI or live credentials.
Report that narrower result explicitly; never use it as the release gate for
an executable example still being implemented.

## Recorded AppleChatApp evidence

Implementation baseline: `c17adeb86f5ea086e9ac9f2d454a41fbe7f85455`.

| Scope | Command or environment | Result |
| --- | --- | --- |
| Lifecycle, projection, fixture/live configuration, fixture tool loop and two-conversation isolation | `swift test --package-path Examples/AppleChatApp --disable-sandbox --no-parallel` | PASS: 21 Swift Testing tests in 4 suites; 0 failures, 0 skips |
| Provider qualification configuration, budget, evidence and fixture scenarios | `swift test --package-path Examples/ProviderQualification --disable-sandbox --no-parallel` | PASS: 22 Swift Testing tests in 5 suites; 0 failures, 0 skips |
| macOS build | `swift build --package-path Examples/AppleChatApp` | PASS with Swift 6.4 / Xcode 27.0 |
| iOS executable cross-build | `swift build --package-path Examples/AppleChatApp --product AppleChatApp --triple arm64-apple-ios16.0` | PASS; no claim of simulator/device UI execution |
| macOS fixture UI | `bash Examples/AppleChatApp/run-macos.sh` on macOS 27.0 | PASS: direct incremental text, tool progress/result, recoverable tool error, terminal state and two app windows were observed |
| Validated route | `validatedRouteIsHonestlyReportedAsBuffered` | PASS: the route removes streaming capability and publishes the accepted complete response; no simulated typing |
| macOS explicit live path | `bash Examples/AppleChatApp/run-macos.sh --provider openai --service gateway --mode live ... --demo ...` | PASS for configuration, two HTTP sends and one local read-only tool loop; visual content inspection NOT RUN because the automation process could not access the window |

The deterministic controller tests cover rapid double Send, Stop during pending
startup, Stop followed by replacement only after physical drain, buffered terminal
events before ownership release, late startup cleanup, and failure while draining.
They use gates and explicit completions rather than timing sleeps. The macOS UI
itself remains a manual acceptance surface; the tests exercise its non-UI
lifecycle and projection logic.

Provider-by-provider service evidence, request budgets and unexercised cases are
recorded in the [2026-09-19 qualification report](../reviews/2026-09-19-provider-live-qualification.md).
