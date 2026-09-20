# SwiftAgent Conformance & Regression Matrix

last-verified: 2026-09-20

This stable matrix records the long-lived capability and regression contract.
One-time release evidence belongs in the parent project's Kanban records, not
in this package.

Pi reference: `earendil-works/pi` `5901446094988aa5cd8e11efdaa131c3949106f1` (main, 2026-09-18).
SwiftAgent baseline: published `1.0.0-rc.1` plus the audited post-rc.1
Anthropic alias, Apple PCC, OpenAI Responses, and DeepSeek Responses work on
`plan/swift-agent-rc2`.

Pi tests are a catalog, not a porting checklist. Each row answers: SwiftAgent has the concept? Should it? Already tested? Stronger? Not applicable?

Action values: `Covered` · `Add test` · `Existing backlog` · `New backlog` · `Not applicable` · `SwiftAgent stronger`

---

## Level status

| Level | Scope | Status |
| --- | --- | --- |
| 1 Core Loop | single turn, tool loop, failure, cancel, events | Covered |
| 2 Stateful Agent | multi-run, steering, context, continuation, compaction | Covered |
| 3 Durable Agent | journal, restart, mutation, receipt, reconciliation | Covered |
| 4 Provider | streaming, encoding, tool calls, reasoning, usage, errors | Covered for declared adapters |
| 5 Host Integration | ExternalClient, WorkspaceAgent, Otoha adapter | Partial |

Level 2 is Covered for the declared contract: next `session.run` after `wait()`, in-run `steer`, fail-closed default compaction. Pi's first-class follow-up *queue* is Host responsibility (SAI-045), not a silent gap in the current API.

Level 3 is Covered for the declared contract. SAI-040 adds journal-wide durable
deduplication, typed pending/reconciliation failures, receipt-backed settled
replay without executor invocation, and explicit Host-confirmed abort restart.

Level 4 is Covered for the declared Anthropic, OpenAI Responses, DeepSeek
Responses, and Apple planning adapters. This means fixture/schema coverage of
their declared contracts; live cloud/on-device qualification remains
operator-opt-in and DeepSeek currently has no live suite.

Level 5 is Partial: ExternalClient and WorkspaceAgent prove the public API; Otoha is a product host, not Core.

---

## A. Basic Agent Loop

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Text-only request | agent-loop / e2e | Yes | `AgentLoopTests.textOnlyAnswerUsesExactlyOneProviderTurn` | — | Yes | P2 | Covered |
| Model → tool → model | agent-loop | Yes | `AgentLoopTests.twoToolsFeedOrderedTypedResultsBackIntoTheNextTurn` | — | Yes | P0 | Covered |
| Multiple / parallel / sequential tools | agent-loop executionMode | Yes | `AgentSchedulingTests`, `AgentBarrierTests` | — | Yes | P0 | Covered |
| Tool results in source order | completion vs persist order | Yes | scheduling tests keep proposal order | — | Yes | P0 | Covered |
| Max model turns / max tool calls | shouldStopAfterTurn | Yes | `AgentLoopBudgetTests` | — | Yes | P1 | Covered |
| Empty input | — | Yes | `AgentSessionTests.emptyInputDoesNotCreateARunOrPolluteHistory` | — | Yes | P2 | Covered |
| Missing terminal | proxy stream-without-terminal | Yes | `AgentLoopContractTests.missingTerminalAndTrailingEventsCannotDispatchEvenCompletedTools` | — | Yes | P0 | Covered |
| Refusal / truncation / unknown stop | e2e thinking; loop truncated tools | Yes | `AgentLoopContractTests.refusalAndModelCancellationAreNotNormalCompletion`, interruption tests | — | Yes | P1 | Covered |
| Structured output + tools | Pi provider-specific | Yes | `AgentLoopContractTests.incompatibleProviderIsRejected…AndSchemaIsPreserved` | — | Yes | P2 | Covered |
| before/after tool hooks, terminate=true | agent-loop | No | — | Host wraps tools | Host | P3 | Not applicable |

---

## B. Multi-run conversation

SAI-043 owns the `search_resource → Use the first one` contract. This round adds N-3 recall and provider replacement, not a duplicate of that fixture.

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Tool result visible on next Run | agent continue from tool result | Yes | `AgentConversationContextTests.crossRunToolResultIsVisibleAndDrivesUseResource` | — | Yes | P0 | Covered |
| Many sequential Runs / N-3 context | e2e multi-turn | Yes | `AgentMultiRunContextTests.laterRunSeesTheUserTurnFromThreeRunsEarlier` | — | Yes | P1 | Covered |
| After refusal / failed batch / cancel / incomplete | — | Yes | conversation context tests 6–9 | — | Yes | P0 | Covered |
| Restart + follow-up | session persistence (coding-agent) | Yes | `restartRestoresCommittedToolConversationWithoutRebuildingEvidence` | Evidence not durable | Yes | P0 | Covered |
| Continuation + follow-up | — | Yes | `committedProviderContinuationSurvivesTheNextRunOnTheSameAssistant` | — | Yes | P1 | Covered |
| Instructions version change | — | Yes | `restartUsesCurrentInstructionsAndKeepsToolHistory` | — | Yes | P0 | Covered |
| multiTurn unsupported | — | Yes | `providerWithoutMultiTurnCannotSilentlyDropAssistantHistory` | — | Yes | P0 | Covered |
| Portable transcript to a replacement provider | cross-provider-handoff | Yes, no switch API | `AgentMultiRunContextTests.replacementProviderReceivesPortableTranscriptWithoutRequiringOpaqueContinuation`; Anthropic `anotherProvidersOpaqueStateIsNotSentToThisEndpoint` | No dynamic switch API | Yes | P2 | Covered |

---

## C. Steering

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| One / several steering messages, order | agent.test steering queue | Yes | `AgentSteeringTests` | — | Yes | P1 | Covered |
| During model turn / tool batch | inject after tools complete | Yes | correction during model turn; during tool batch | — | Yes | P0 | Covered |
| Exactly once / late after finish | — | Yes | empty + finished errors; cancel races | — | Yes | P1 | Covered |
| Budget exhaustion | — | Yes | `exhaustedBudgetRetainsAcceptedCorrectionsInOrder` | — | Yes | P2 | Covered |
| Steering + compaction | coding-agent compact during response | Yes | `steeringAfterMidRunCompactionIsAppliedExactlyOnce` | — | Yes | P2 | Covered |
| Retry/fallback + steering | retry-events | Partial | fallback tests do not mix steer | Low | Yes | P3 | Not applicable |

---

## D. Follow-up queue

Pi distinguishes `steer` (in-run correction) from `follow-up` (queued next user turn). SwiftAgent has `run.steer` and `session.run`. Overlapping `session.run` throws `runInProgress`.

Decision: **Host responsibility for 1.0.** Hosts `wait()` then `session.run`. A Core follow-up queue would be a new public API. Tracked as SAI-045. Not implemented here.

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Queue “然后再做 X” while Run is live | agent-session-queue | No | `sameSessionRejectsConflictWhileOtherSessionsContinue` | Host waits | Yes | P2 | New backlog |

---

## E. Tool execution semantics

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Executor completion ≠ canonical order | agent-loop source order | Yes | `readOnlyCallsOverlapButHistoryKeepsProposalOrder` | — | Yes | P0 | Covered |
| One read failure / mutation failure isolation | — | Yes | scheduling + mutation recovery | — | Yes | P0 | Covered |
| Cancel / timeout / late completion | — | Yes | loop cancellation, event failure, evidence late-result | — | Yes | P0 | Covered |
| Resource conflict / cross-session | — | Yes | `ToolResourceCoordinatorTests`, `AgentIsolationTests` | — | Yes | P0 | Covered |
| Resource-wait timeout vs cancel | — | Yes | `timedOutOrCancelledExecutorKeepsItsLeaseUntilItActuallyReturns` | — | Yes | P2 | Covered |

---

## F. Recoverable tool errors

SwiftAgent now provides an explicit read-only channel matching the applicable Pi continuation behavior. The tool policy and the thrown error must both opt in; every other failure remains fail-closed.

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Declared read-only recoverable error | tool_execution_end isError | Yes | `declaredRecoverableReadOnlyErrorBecomesModelVisibleAndContinues`, restart/parallel tests | — | Yes | P2 | Covered by SAI-039 |
| Malformed arguments / unknown tool | prepare/validate | Fail closed, no execution | `AgentLoopContractTests.malformedUnknownAndInvalidBatchMembersNeverExecuteAnyTool` | Must stay fail closed | Yes | P0 | Covered |
| Mutation / authorization / Evidence / receipt / journal | — | Fail closed | `AgentRecoverableToolErrorTests`, mutation recovery and loop failure suites | — | Yes | P0 | Covered |

The model-visible envelope is runtime-defined (`code`, `message`, optional
`details`), carries no Receipt or Evidence, and is encoded by Anthropic and the
Apple prompt adapter with `isError == true`.

---

## G. Cancellation matrix

Phases are covered across files, not one checklist suite.

| Phase | Existing test | Action |
| --- | --- | --- |
| Before provider starts | `alreadyCancelledCreatorPublishesCancellationWithoutStartingProvider` | Covered |
| During provider stream | Anthropic HTTP cancel; event consumer cancel | Covered |
| After response, before tools | incomplete proposal tests | Covered |
| Waiting for resource | `testCancellationWhileWaitingForResourcesDoesNotStartExecutor` | Covered |
| During authorization / after durable intent | mutation recovery cancel tests | Covered |
| During executor | `cancellationReturnsWithoutWaitingForAnUncooperativeTool` | Covered |
| Executor done, before/during receipt | `lateValidReceiptAfterTimeoutOrCancellationCannotBecomeSuccess` | Covered |
| During checkpoint | `cancellationAroundCheckpointKeepsHistoryAndEventsConsistent` | Covered |
| During terminal / drain | `waitReturnsBeforeAnUncooperativeToolDrains…`; event `runFinished` once | Covered |

---

## H. Timeout matrix

| Scenario | Existing test | Action |
| --- | --- | --- |
| Model / overall deadline | `deadlineEndsAStalledProviderRequest` | Covered |
| Tool timeout + late discard | `toolTimeoutEndsRunBeforeOverallDeadlineAndDiscardsLateResult` | Covered |
| Mutation executor timeout, no replay | `testTimeoutAfterExecutorSideEffectDoesNotReplayMutation` | Covered |
| Timeout + cancel race / next Run | receipt + conversation follow-up | Covered |
| Resource wait timeout | scheduler deadline and cancellation paths | Covered by scheduler/cancellation tests |

---

## I. Terminal event contract

| Scenario | Existing test | Action |
| --- | --- | --- |
| Success / refusal / cancel / provider failure: `runStarted` once, `runFinished` once, `wait()` matches | `AgentEventTests`, `AgentEventFailureTests`, **SAI-044** `AgentEventContractTests` | Covered |
| F1 settlement+quarantine hang | `AgentSessionHangTests.testMutationCommitAndQuarantineFailureStillFinishesTheRun` | Covered |
| Observer disconnect / multiple waiters | `AgentRunTests` | Covered |
| `onFailed` + quarantine via Agent→Session→Run | `testExecutorAndQuarantineFailureUseOneTypedTerminalWithoutReplay` | Covered |

---

## J. wait / drain

| Scenario | Existing test | Action |
| --- | --- | --- |
| No background work | `waitForDrainCompletesAfterWaitWhenNoUnderlyingWorkRemains` | Covered |
| Uncooperative tool blocks replacement Session | `waitReturnsBeforeAnUncooperativeToolDrainsAndBlocksAReplacementSession` | Covered |
| Session-level and run-level drain, one owner | `sessionAndRunDrainShareOneOwner` | Covered |
| Multiple drain waiters | **SAI-044** `multipleDrainWaitersSharePhysicalRelease` | Covered |
| Drain waiter Task cancellation | `multipleDrainWaitersSharePhysicalRelease` | Covered; cancelled observer throws while physical drain continues |

---

## K–L. Provider stream / adapters

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Action |
| --- | --- | --- | --- | --- |
| SSE framing, missing terminal, empty, duplicate terminal | proxy / event-stream | Yes | `ProviderSSEDecoderTests`, `ModelEventTests`, loop missing-terminal | Covered |
| Unicode / combining / CJK / emoji chunk split | unicode-surrogate | Yes | **SAI-044** `chineseJapaneseEmojiSurviveUTF8ChunkBoundaries` | Covered |
| Unknown top-level Anthropic event ignored | anthropic-sse-parsing | Yes | `AnthropicUnknownEventTests` | Covered |
| Thinking signature / tool input streaming / usage | anthropic thinking tests | Declared subset | `AnthropicProviderTests`, continuation tests | Covered |
| OpenAI terminal item status, incomplete calls, native identity, ordered/interleaved continuation | Responses API | Yes | `ResponsesTerminalValidationTests`, `OpenAIResponsesFailureTests`, `OpenAIResponsesStreamDecoderTests.interleavedItemsPreserveCanonicalContentOrder`, `ResponsesContinuationIntegrityTests` | Covered |
| DeepSeek terminal status, legal partial response, same-turn reasoning, ordered/interleaved continuation | Responses API | Yes | `ResponsesTerminalValidationTests`, `DeepSeekResponsesIncompleteTests`, `ResponsesContinuationIntegrityTests.deepSeekInterleavedItemsPreserveCanonicalContentOrder` | Covered |
| Adaptive thinking, OAuth, Bedrock, Gemini, … | packages/ai/test catalog | No | — | Not applicable |
| `event:` vs `data.type` mismatch after `message_stop` | — | Yes | `AnthropicUnknownEventTests` | Covered |

---

## M–N. Continuation / cross-provider

| Scenario | Existing test | Action |
| --- | --- | --- |
| Complete continuation retained; incomplete discarded | `AgentContinuationTests` | Covered |
| Foreign opaque state not sent to Anthropic | `anotherProvidersOpaqueStateIsNotSentToThisEndpoint` | Covered |
| Portable user/assistant/tool across Agent replacement | **SAI-044** `replacementProviderReceivesPortableTranscript…` | Covered |
| Dynamic in-run provider switch API | None | Not applicable / Future |
| Mutation boundary blocks fallback | `ProviderFallbackTests.mutationBoundaryBlocksProviderSwitchWithinTheSameRun` | SwiftAgent stronger |

---

## O–P. Tool call IDs / malformed arguments

| Scenario | Existing test | Action |
| --- | --- | --- |
| Opaque IDs, reuse cannot replay | `ModelIdentityTests`, `AgentLoopBudgetTests.reusedCallIDs…` | Covered |
| Invalid JSON / wrong type / unknown tool never execute | `AgentLoopContractTests.malformedUnknownAndInvalidBatchMembersNeverExecuteAnyTool` | Covered |
| Pi foreign toolcall-id normalization / OpenAI Responses IDs | OpenAI native function ID and call ID are retained and rebound to canonical calls | `openAIToolOnlyContinuationPreservesNativeIdentityAcrossEncoding` | Covered |
| Empty / Unicode / very long IDs as identity bytes | opaque UTF-8 identity tests | Covered |

Do not normalize IDs in a way that breaks Receipt / Journal identity.

---

## Q–R. Context overflow / synthetic summary

| Scenario | Existing test | Action |
| --- | --- | --- |
| inputTooLarge / historyTooLarge / default no compactor | SAI-038/043 context tests | Covered |
| Exactly at encoded limit / one byte over | **SAI-044** `historyExactlyAtTheEncodedLimit…`, `oneByteOverTheEncodedLimit…` | Covered |
| Compactor throws, Session does not hang | **SAI-044** `throwingCompactorFailsTheRunWithoutHangingTheSession` | Covered |
| Unresolved tool span kept | `contextWindowKeepsUnresolvedToolPairs` | Covered |
| Mid-run compaction writeback / journal file rollover | SAI-042 context/journal tests | Covered |
| Synthetic `.user` + `Conversation summary:` | conversation tests 13–14 | Covered |
| Anthropic encoder: summary + follow-up (adjacent users merge to two text blocks) | **SAI-044** `AnthropicSyntheticSummaryTests` | Covered |
| Apple prompt JSON: summary stays its own user row | **SAI-044** `ApplePromptEncodingTests` | Covered |
| Generic/OpenAI-style: `ModelMessage` JSON round-trip | **SAI-044** `ModelMessageTests.testSyntheticSummaryRoundTripsAsAUserMessageBetweenTurns` | Covered |
| Lossy retain counts synthetic summary as a user turn | `syntheticSummaryDoesNotCountAsARecentUserTurn` | Covered |

Anthropic merging adjacent user messages is protocol-correct and is why a synthetic summary must not be `.system`.

---

## S–U. Journal / mutation / idempotency

SwiftAgent-specific. Pi has no equivalent durable mutation/receipt model.

| Scenario | Existing test | Action |
| --- | --- | --- |
| Clean / truncated / corrupt tail / middle corruption / concurrent writer | `AgentJournalTests` | SwiftAgent stronger |
| Durable intent, crash windows, receipt, reconcile, abort, lease | `AgentMutationRecoveryTests` | SwiftAgent stronger |
| F1 hang: settlement + quarantine both fail | `AgentSessionHangTests` | Covered |
| Unicode checkpoint round-trip | **SAI-044** `AgentJournalUnicodeTests` | Covered |
| Identity scope: stable operation ID + tool + canonical semantic JSON args; excludes call/session/run | `AgentMutationIdempotencyTests`, recovery cross-session test | Covered |
| Nil operation ID is per-call only, with no cross-run deduplication | loop idempotency-key contract | Covered |
| `intent` retry fails closed with typed `mutationPending` | `intentRetryReturnsTypedPendingWithoutCreatingAnotherIntent` | Covered |
| `needsReconciliation` retry fails closed | `needsReconciliationRetryFailsClosed` | Covered |
| Settled retry returns the original receipt without executor invocation | `settledRetryReturnsExistingReceiptWithoutExecutingAgain`, restart recovery test | Covered |
| Settled replay emits the original schema-valid output and uses the current tool call ID | `settledRetryReturnsExistingReceiptWithoutExecutingAgain` | Covered |
| Abort permits a new lifecycle only after trusted Host confirmation of no side effect | `confirmedAbortedMutationCanCreateANewDurableIntent` | Covered |
| Authorization and Evidence are checked before replay admission | mutation authorization/evidence ordering tests | Covered |
| Legacy settlement without durable output fails closed | `legacySettlementWithoutDurableOutputFailsClosed` | Covered |
| Terminal identities retained indefinitely; schema v3 reads v1/v2 | journal recovery and rollover contract | Covered |

---

## V. Evidence

| Scenario | Existing test | Action |
| --- | --- | --- |
| sameRun / sameSession / other Session / restart / transcript ≠ ledger | `AgentEvidenceTests`, conversation evidence tests | Covered |
| Expired / wrong namespace / id / metadata | `EvidenceLedgerTests`, `EvidenceResolutionTests` | Covered |
| Late timeout cannot mint Evidence | `lateTimedOutResultCannotPublishEvidence` | Covered |

---

## W. Retry / fallback

| Scenario | Existing test | Action |
| --- | --- | --- |
| Transient fallback; non-transient / cancel never fallback | `ProviderFallbackTests` | Covered |
| Mutation side effect blocks replay/switch | same | SwiftAgent stronger |
| Same-provider `retryAfter`; cancellation during delay | `sameProviderRetryHonorsRetryAfter`, `cancellingDuringRetryAfterStopsBeforeAnotherAttempt` | Covered for declared route |
| Partial stream then fallback never publishes failed candidate | `partialEventsFromFailedCandidateAreNeverPublished` | Covered |
| Route candidate namespace and buffered capability truthfulness | `routeRejectsCandidateFromAnotherProviderNamespace`, `routeDoesNotAdvertiseStreamingWhenItBuffersCandidateResponses` | Covered |
| Late candidate completion after Run clear cannot restore stale pinning | `validatedCandidateFinishingAfterClearCannotRestorePinnedState` | Covered |

---

## X–Y. Subscribers / lifecycle

| Scenario | Existing test | Action |
| --- | --- | --- |
| Disconnect observer / cancel waiter does not cancel Run | `AgentRunTests` | Covered |
| Multiple wait() waiters | `multipleWaitersShareOutcome…` | Covered |
| Slow consumer backpressure soak | — | P3, not RC |
| Drain waiters released on complete | **SAI-044** multiple drain waiters | Covered |
| Waiter leak soak / unbounded growth | source-reviewed | P3 |

---

## Z. Unicode / encoding

| Scenario | Existing test | Action |
| --- | --- | --- |
| Combining marks / opaque IDs | `ModelIdentityTests`, schema tests | Covered |
| SSE chunk boundaries including CJK/emoji | **SAI-044** ProviderSSEDecoder | Covered |
| Journal checkpoint CJK/emoji | **SAI-044** AgentJournalUnicodeTests | Covered |

---

## Area summary

| Area | Status |
| --- | --- |
| A Basic loop | Covered (hooks N/A) |
| B Multi-run | Covered |
| C Steering | Covered (compact+steer → SAI-042) |
| D Follow-up queue | Gap → SAI-045 |
| E Tool execution | Covered |
| F Recoverable errors | Covered (SAI-039) |
| G Cancellation | Covered |
| H Timeout | Covered |
| I Terminal events | Covered (Session onFailed path → SAI-042) |
| J wait/drain | Covered (drain Task cancel → SAI-042) |
| K Stream robustness | Covered |
| L Provider adapters | Covered for declared subsets; live qualification remains explicit |
| M Continuation | Covered |
| N Cross-provider | Covered portable + ignore foreign opaque |
| O Tool IDs | Covered |
| P Malformed args | Covered |
| Q Context overflow | Covered (mid-run → SAI-042) |
| R Synthetic summary | Covered |
| S Journal | SwiftAgent stronger (rollover → SAI-042) |
| T Mutation | SwiftAgent stronger |
| U Idempotency | Covered (SAI-040) |
| V Evidence | Covered |
| W Retry/fallback | Covered declared route |
| X Subscribers | Covered |
| Y Lifecycle | Covered |
| Z Unicode | Covered |

---

## Pi has, SwiftAgent does not (applicable)

1. First-class follow-up queue while a Run is in progress — SAI-045.
2. Semantic compaction that preserves dropped tool results — **rejected**. Default is fail-closed (`historyTooLarge`). Lossy opt-in is explicit.
3. Additional vendor catalog entries such as Gemini or Bedrock — product scope,
   not a conformance gap in the declared provider set.
4. Tool `terminate` / beforeToolCall hooks — Host wrapper, not Core.
5. Async subscriber `waitForIdle` — SwiftAgent `wait()`/`waitForDrain()` is the contract.

## SwiftAgent has, Pi does not (same guarantee)

- EvidenceLedger with `sameRun` / `sameSession` and transcript ≠ permission
- Durable mutation intent before executor
- Typed Receipt and settlement
- Reconciliation / abort / quarantine
- Journal recovery (truncated/corrupt tail, concurrent writer, session lease)
- Mutation replay prevention after side effect, including provider fallback
- `wait()` vs `waitForDrain()` physical identity
- Fail-closed context bound instead of a fake semantic summary
