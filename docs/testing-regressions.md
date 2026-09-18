# SwiftAgent Named Regressions

last-verified: 2026-09-18

Keep production bugs as named tests in their domain files. This index is the
long-term map so a later bug does not require moving files.

| Bug | Test | File |
| --- | --- | --- |
| Settlement + quarantine failure must not hang (F1) | `testMutationCommitAndQuarantineFailureStillFinishesTheRun` | `Tests/AgentCoreTests/AgentSessionHangTests.swift` |
| Root authorization replacement | `AppleExecutionBoundaryTests` / mutation authorization tests | `Tests/AgentAppleProviderTests/AppleExecutionBoundaryTests.swift`, `Tests/AgentCoreTests/AgentLoopFailureTests.swift` |
| Cross-run tool context | `crossRunToolResultIsVisibleAndDrivesUseResource` | `Tests/AgentCoreTests/AgentConversationContextTests.swift` |
| Durable intent failure before executor | `testMutationIntentIsDurableBeforeExecutorAndSettledByReceipt` and intent-persistence failures in recovery | `Tests/AgentCoreTests/AgentMutationRecoveryTests.swift` |
| Receipt / cancel race | `lateValidReceiptAfterTimeoutOrCancellationCannotBecomeSuccess` | `Tests/AgentCoreTests/AgentReceiptTests.swift` |
| Current instructions vs restored conversation | `restartUsesCurrentInstructionsAndKeepsToolHistory` | `Tests/AgentCoreTests/AgentConversationContextTests.swift` |
| Default compaction must not invent semantic memory | `defaultPolicyFailsClosedInsteadOfInventingASemanticSummary` | `Tests/AgentCoreTests/AgentConversationContextTests.swift` |
| Mid-run compaction must replace AgentLoop's stale history | `midRunToolCheckpointFeedsCompactedHistoryIntoTheNextModelRequest`, `zeroRetainedTurnsPreservesCanonicalSummaryAcrossAMultiToolBatch` | `Tests/AgentCoreTests/AgentContextPolicyTests.swift` |
| Executor failure plus quarantine failure must share one typed terminal | `testExecutorAndQuarantineFailureUseOneTypedTerminalWithoutReplay` | `Tests/AgentCoreTests/AgentSessionHangTests.swift` |
| Journal rollover must preserve recovery and reject stale writers | `testCompactionShrinksHistoryAndPreservesLatestCheckpointAcrossRestart`, `testStaleWriterFailsClosedAfterCompaction`, `testDirectorySyncFailureAdoptsTheAlreadyReplacedJournal` | `Tests/AgentCoreTests/AgentJournalTests.swift` |
| Cancelling one drain waiter must not cancel physical drain | `multipleDrainWaitersSharePhysicalRelease` | `Tests/AgentCoreTests/AgentRunTests.swift` |
| Anthropic terminal/trailing and event/data mismatch must fail closed | `unknownSemanticEventAfterMessageStopFailsClosed`, `mismatchedNamedEventAndDataTypeFailClosed` | `Tests/AgentProvidersTests/AnthropicUnknownEventTests.swift` |

When a new production bug lands, add a row here and a focused test next to the
domain tests. Prefer a precise name over a `Regressions/` directory move.
