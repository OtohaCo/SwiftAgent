# SwiftAgent Swift 6.4 Concurrency Audit

last-verified: 2026-09-27

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
logical terminal result. Throwing `waitForDrain()` waits until provider and tool
work for that Run have exited and the Session identity is free. Cancelling one
drain waiter removes only that observer; it does not cancel physical drain.
Provider streams
use `ModelEventStream.make`, which cancels the producer on termination. After
a thrown `ModelProviderError` there is no terminal model event; AgentCore still
publishes exactly one `runFinished`.

## I/O isolation and checked ownership

No `@preconcurrency` or `nonisolated(unsafe)` is used in Core. The immutable
`AgentJournal.storage` value is `nonisolated` so synchronous `makeSession`
can check the configured capability. There is no memory-to-durable upgrade.

`AgentJournal` runs isolated work on its own `JournalIOExecutor` serial Dispatch
queue, including synchronous store calls. This avoids blocking `MainActor` or
the cooperative global executor when the actor commits. The separate file-store
maintenance queue builds immutable candidates without holding the foreground
store coordinator lock; publication and GC hold it for one bounded segment's
index updates and deletes. The actor
retains the maintenance Task, and `close()` waits for it and refuses active
Session leases before unlocking. Async create/open use an owned utility queue.
They check a monotonic deadline before and after blocking I/O, so they do not
promise a hard interrupt of an OS call. The synchronous create/open variants
are for callers already off UI executors.

`SegmentedJournalStore`, `MetricsBox` and `JournalIOExecutor` use
`@unchecked Sendable` where OS descriptors, file coordination or a queue sit
behind explicit locks/serial execution. Provider HTTP delegates use their own
`NSLock` to coordinate callbacks and stream termination. A UI Host can isolate
its adapter to `MainActor`; durable file I/O does not run there.
