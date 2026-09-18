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
logical terminal result. `waitForDrain()` waits until provider and tool work
for that Run have exited and the Session identity is free. Provider streams
use `ModelEventStream.make`, which cancels the producer on termination. After
a thrown `ModelProviderError` there is no terminal model event; AgentCore still
publishes exactly one `runFinished`.

## Workarounds

No `@preconcurrency` and no `nonisolated(unsafe)` in SwiftAgent sources.

Two `@unchecked Sendable` types exist. Neither is a warning-suppression shortcut.

### ProviderHTTPSessionDelegate

Lives in AgentProviders. `URLSession` callbacks and stream termination can race.
Mutable lifecycle state is behind `NSLock`. Terminal paths nil out the
continuation, session, and task before invoking callbacks. The annotation is
required because `URLSessionDataDelegate` is not Sendable.

### AgentJournalStorageBox

Lives in AgentCore. `Agent.makeSession()` is synchronous and must read the
journal's persistence mode without awaiting the `AgentJournal` actor.
`storage` is therefore `nonisolated` and backed by this box.

`value` is only read or written under `NSLock`. The actor's isolated methods
set `.memory` in `init()`, `.durable` in `init(persistenceURL:)` / `load(from:)`,
and upgrade `.memory` to `.durable` after a successful `persist(to:)` snapshot
bind. Publishing `.durable` does not mean a later append cannot fail; it only
changes the advertised mode that `makeSession` consults.

Do not collapse these two annotations to keep a count of one. They protect
different seams.

Otoha’s Engine adapter is `@MainActor` because the conversation UI is. That
isolation stays in the host. Core types remain usable off the main actor.
