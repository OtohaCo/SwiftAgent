# SwiftAgent Swift 6.4 Concurrency Audit

last-verified: 2026-09-18

Audited against the workspace Swift 6.4 toolchain (`swiftLanguageModes: [.v6]`).
AgentModels, AgentTools, and AgentCore do not import or isolate to MainActor.

## Ownership

| Type | Isolation | Notes |
| --- | --- | --- |
| Agent / AgentConfiguration | struct, Sendable | Configuration only |
| AgentSession | actor | Canonical history and single active run |
| AgentRun | struct, Sendable | Holds `AsyncStream` and an internal control actor |
| ToolScheduler | struct, Sendable | Coordinates through internal actors |
| AgentJournal / EvidenceLedger | actor | Durable and in-memory mutation/evidence state |
| ModelProvider.stream | AsyncThrowingStream | Producer task cancelled when the consumer terminates |

Share one `ToolScheduler` across every Session that can touch the same real
resources. Isolation is per scheduler instance, not per Session.

## Continuations and streams

`AgentRun.events` is a single-consumer `AsyncStream`. Cancelling the observer
does not cancel the Run. `wait()` may have several callers and returns one
terminal result. Provider streams use `ModelEventStream.make`, which cancels the
producer on termination. After a thrown `ModelProviderError` there is no
terminal model event; AgentCore still publishes exactly one `runFinished`.

## Workarounds

No `@preconcurrency` and no `nonisolated(unsafe)` in SwiftAgent sources.

One `@unchecked Sendable` exists:

`ProviderHTTPSessionDelegate` in AgentProviders. `URLSession` callbacks and
stream termination can race. Mutable lifecycle state is behind `NSLock`.
Terminal paths nil out the continuation, session, and task before invoking
callbacks. The annotation is required because `URLSessionDataDelegate` is not
Sendable; it is not a warning-suppression shortcut.

Otoha’s Engine adapter is `@MainActor` because the conversation UI is. That
isolation stays in the host. Core types remain usable off the main actor.
