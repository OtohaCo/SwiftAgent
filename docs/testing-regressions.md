# SwiftAgent Named Regressions

last-verified: 2026-09-19

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
| Settled mutation retry must reuse the original receipt and schema-valid output without executing again | `settledRetryReturnsExistingReceiptWithoutExecutingAgain`, `settledRetryWorksAfterSessionRestart`, `journalCompactionPreservesSettledReplayIdentity`, `legacySettlementWithoutDurableOutputFailsClosed` | `Tests/AgentCoreTests/AgentMutationIdempotencyTests.swift` |
| Concurrent duplicate mutation admission must execute only one side effect | `concurrentDuplicateAdmissionExecutesOnce` | `Tests/AgentCoreTests/AgentMutationIdempotencyTests.swift` |
| Provider fallback must not replay a previously settled mutation | `fallbackProviderReplaysSettledMutationWithoutExecutingAgain` | `Tests/AgentProvidersTests/ProviderFallbackTests.swift` |
| Declared read-only recoverable failure must continue the model loop with a canonical error result | `declaredRecoverableReadOnlyErrorBecomesModelVisibleAndContinues`, `crossRunAndRestartPreserveRecoverableTranscript` | `Tests/AgentCoreTests/AgentRecoverableToolErrorTests.swift` |
| Mutation, authorization, Evidence, malformed calls, and undeclared errors must never enter the recoverable channel | `mutationCannotOptIntoModelVisibleErrors`, `authorizationFailureStaysFailClosed`, `recoverablePayloadCannotMintEvidence`, `malformedArgumentsAndUnknownToolsStayFailClosed`, `recoverableErrorWithoutPolicyOptInStillFailsTheRun` | `Tests/AgentCoreTests/AgentRecoverableToolErrorTests.swift` |
| Valid v1/v2 journals must remain loadable and compact without changing mutation safety | `testLegacyV1PendingMutationSurvivesCompactionAndRestart`, `testValidV2SessionScopedDuplicateIdentitiesRemainLoadableAndFailClosed` | `Tests/AgentCoreTests/AgentJournalTests.swift` |
| Non-zero invalid terminal frame lengths must preserve the prefix and require explicit repair | `testTerminalInvalidLengthWithNonzeroPayloadIsRepairableCorruptTail` | `Tests/AgentCoreTests/AgentJournalTests.swift` |
| Receipt/cancel race must wait for actual executor entry, not a wall-clock expectation | `testReceiptAndCancellationDoNotDoubleSettle` | `Tests/AgentCoreTests/AgentMutationRecoveryTests.swift` |
| Provider routes must not claim streaming while buffering or accept incompatible namespaces | `routeDoesNotAdvertiseStreamingWhenItBuffersCandidateResponses`, `routeRejectsCandidateFromAnotherProviderNamespace` | `Tests/AgentProvidersTests/ProviderFallbackTests.swift` |
| Same-provider retry must honor `retryAfter` and remain cancellable | `sameProviderRetryHonorsRetryAfter`, `cancellingDuringRetryAfterStopsBeforeAnotherAttempt` | `Tests/AgentProvidersTests/ProviderFallbackTests.swift` |
| OpenAI truncation must retain an incomplete tool call without dispatching it | `truncatedFunctionCallIsIncompleteAndNeverExecutes` | `Tests/AgentProvidersTests/OpenAIResponsesFailureTests.swift` |
| OpenAI alias resolution must be explicit and response identity must remain fail-closed | `explicitResolvedModelAliasIsAcceptedAndUndeclaredSnapshotIsRejected` | `Tests/AgentProvidersTests/OpenAIResponsesFailureTests.swift` |
| Stateless OpenAI reasoning must replay only through a matching opaque continuation | `encryptedReasoningAndFunctionItemIdentityRoundTripThroughAgent` | `Tests/AgentProvidersTests/OpenAIResponsesProviderTests.swift` |
| OpenAI stream failures and final output divergence must not become retryable generic success | `streamFailuresUseTypedSanitizedClassification`, `unknownAndUnstreamedOutputItemsFailClosedWithUsefulKinds` | `Tests/AgentProvidersTests/OpenAIResponsesFailureTests.swift` |
| OpenAI reasoning without encrypted continuation state must keep only replayable native function state | `missingEncryptedReasoningKeepsOnlyReplayableFunctionContinuation` | `Tests/AgentProvidersTests/OpenAIResponsesProviderTests.swift` |
| OpenAI continuation replay must preserve native item order | `continuationPreservesProviderItemOrder` | `Tests/AgentProvidersTests/OpenAIResponsesProviderTests.swift` |
| OpenAI refusal content must terminate as refusal rather than a malformed response | `refusalContentTerminatesAsRefusalInsteadOfInvalidResponse` | `Tests/AgentProvidersTests/OpenAIResponsesProviderTests.swift` |
| OpenAI and DeepSeek explicit illegal terminal statuses must fail before tool execution | `terminalItemStatusMatrix`, `invalidFunctionTerminalNeverReachesAgentExecutor`, `completedFunctionTerminalExecutesExactlyOnce` | `Tests/AgentProvidersTests/ResponsesTerminalValidationTests.swift` |
| A legal DeepSeek incomplete response must preserve observed partial state while executing no tools | `partialFunctionWithoutItemDoneIsIncompleteAndNeverExecutes`, `completedAndPartialCallsInIncompleteResponseExecuteNone`, `incompleteFinalCannotRewriteObservedPartialState` | `Tests/AgentProvidersTests/DeepSeekResponsesIncompleteTests.swift` |
| Provider continuations must preserve visible content order and OpenAI native function identity | `openAIContinuationRejectsVisibleContentReordering`, `deepSeekContinuationRejectsVisibleContentReordering`, `openAIToolOnlyContinuationPreservesNativeIdentityAcrossEncoding` | `Tests/AgentProvidersTests/ResponsesContinuationIntegrityTests.swift` |
| DeepSeek thinking plus registered tools requires replayable reasoning in every accepted completed turn | `deepSeekThinkingWithToolsRejectsPlainTextWithoutReasoningInSameTurn`, `deepSeekThinkingTextContinuationEncodesTheNextTurn` | `Tests/AgentProvidersTests/ResponsesContinuationIntegrityTests.swift` |
| A timed-out compactor must exit without overwriting newer memory or durable history | `timedOutCompactorCannotOverwriteNewerMemoryHistory`, `timedOutCompactorCannotOverwriteANewerRunOrDurableCheckpoint` | `Tests/AgentCoreTests/AgentContextPolicyTests.swift` |
| Terminal completion must wait for a reserved mutation commit and preserve durable settlement | `finishingWaitsForBlockedMutationCommitAndPreservesDurableSettlement` | `Tests/AgentCoreTests/AgentCompletionCommitTests.swift` |
| A provider candidate finishing after Run clear must not restore stale route pinning | `validatedCandidateFinishingAfterClearCannotRestorePinnedState` | `Tests/AgentProvidersTests/ProviderFallbackTests.swift` |

When a new production bug lands, add a row here and a focused test next to the
domain tests. Prefer a precise name over a `Regressions/` directory move.
