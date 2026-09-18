# SwiftAgent Conformance & Regression Matrix

last-verified: 2026-09-18

Pi reference: `earendil-works/pi` `5901446094988aa5cd8e11efdaa131c3949106f1` (main, 2026-09-18).
SwiftAgent baseline: `8cf2373ca14b19d9463451c3f3e01c86ca4f6ba9` (SAI-043) plus this SAI-044 delta.

Pi tests are a catalog, not a porting checklist. Each row answers: SwiftAgent has the concept? Should it? Already tested? Stronger? Not applicable?

Action values: `Covered` · `Add test` · `Existing backlog` · `New backlog` · `Not applicable` · `SwiftAgent stronger`

---

## Level status

| Level | Scope | Status |
| --- | --- | --- |
| 1 Core Loop | single turn, tool loop, failure, cancel, events | Covered |
| 2 Stateful Agent | multi-run, steering, context, continuation, compaction | Covered |
| 3 Durable Agent | journal, restart, mutation, receipt, reconciliation | Partial |
| 4 Provider | streaming, encoding, tool calls, reasoning, usage, errors | Partial |
| 5 Host Integration | ExternalClient, WorkspaceAgent, Otoha adapter | Partial |

Level 2 is Covered for the declared contract: next `session.run` after `wait()`, in-run `steer`, fail-closed default compaction. Pi's first-class follow-up *queue* is Host responsibility (SAI-045), not a silent gap in the current API.

Level 3 is Partial only because settled `operationID` retry semantics are still SAI-040. Recovery, receipts, and replay prevention are otherwise stronger than Pi.

Level 4 is Partial because SwiftAgent ships Anthropic + Apple planning adapters, not Pi's multi-cloud catalog. Live cloud/on-device tests remain opt-in skips.

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
| Steering + compaction | coding-agent compact during response | No dedicated pair | — | Mid-run compact is SAI-042 | Yes | P2 | Existing backlog |
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
| Resource-wait timeout vs cancel | — | Partial | cancel-while-waiting covered | Dedicated lease timeout | Yes | P2 | Existing backlog |

---

## F. Recoverable tool errors

Pi can show the model a tool error and continue. SwiftAgent currently hardcodes `isError: false` on successful tool messages and fail-closes executor errors.

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Gap | Applicable | Severity | Action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Declared read-only recoverable error | tool_execution_end isError | No channel | fail-closed executor tests | SAI-039 | Yes | P2 | Existing backlog |
| Malformed arguments / unknown tool | prepare/validate | Fail closed, no execution | `AgentLoopContractTests.malformedUnknownAndInvalidBatchMembersNeverExecuteAnyTool` | Must stay fail closed | Yes | P0 | Covered |
| Mutation / authorization / receipt / journal | — | Fail closed | `AgentLoopFailureTests.authorizationMutationAndInvalidOutputStayFailClosed` | Must stay fail closed | Yes | P0 | Covered |

SAI-039 is updated with these rows. This task does not implement the channel.

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
| Resource wait timeout | cancel path only | Partial; not a new SAI |

---

## I. Terminal event contract

| Scenario | Existing test | Action |
| --- | --- | --- |
| Success / refusal / cancel / provider failure: `runStarted` once, `runFinished` once, `wait()` matches | `AgentEventTests`, `AgentEventFailureTests`, **SAI-044** `AgentEventContractTests` | Covered |
| F1 settlement+quarantine hang | `AgentSessionHangTests.testMutationCommitAndQuarantineFailureStillFinishesTheRun` | Covered |
| Observer disconnect / multiple waiters | `AgentRunTests` | Covered |
| `onFailed` + quarantine via Agent→Session→Run | record() path only | Existing backlog SAI-042 |

---

## J. wait / drain

| Scenario | Existing test | Action |
| --- | --- | --- |
| No background work | `waitForDrainCompletesAfterWaitWhenNoUnderlyingWorkRemains` | Covered |
| Uncooperative tool blocks replacement Session | `waitReturnsBeforeAnUncooperativeToolDrainsAndBlocksAReplacementSession` | Covered |
| Session-level and run-level drain, one owner | `sessionAndRunDrainShareOneOwner` | Covered |
| Multiple drain waiters | **SAI-044** `multipleDrainWaitersSharePhysicalRelease` | Covered |
| Drain waiter Task cancellation | Drain continuations have no cancel handler | Existing backlog SAI-042 |

---

## K–L. Provider stream / Anthropic

| Scenario | Pi coverage | SwiftAgent coverage | Existing test | Action |
| --- | --- | --- | --- | --- |
| SSE framing, missing terminal, empty, duplicate terminal | proxy / event-stream | Yes | `ProviderSSEDecoderTests`, `ModelEventTests`, loop missing-terminal | Covered |
| Unicode / combining / CJK / emoji chunk split | unicode-surrogate | Yes | **SAI-044** `chineseJapaneseEmojiSurviveUTF8ChunkBoundaries` | Covered |
| Unknown top-level Anthropic event ignored | anthropic-sse-parsing | Yes | `AnthropicUnknownEventTests` | Covered |
| Thinking signature / tool input streaming / usage | anthropic thinking tests | Declared subset | `AnthropicProviderTests`, continuation tests | Covered |
| Adaptive thinking, OAuth, Bedrock, Gemini, … | packages/ai/test catalog | No | — | Not applicable |
| `event:` vs `data.type` mismatch after `message_stop` | — | Documented leftover | — | Existing backlog SAI-042 |

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
| Pi foreign toolcall-id normalization / OpenAI Responses IDs | No OpenAI Responses adapter | Not applicable |
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
| Mid-run compaction writeback / journal file rollover | — | Existing backlog SAI-042 |
| Synthetic `.user` + `Conversation summary:` | conversation tests 13–14 | Covered |
| Anthropic encoder: summary + follow-up (adjacent users merge to two text blocks) | **SAI-044** `AnthropicSyntheticSummaryTests` | Covered |
| Apple prompt JSON: summary stays its own user row | **SAI-044** `ApplePromptEncodingTests` | Covered |
| Generic/OpenAI-style: `ModelMessage` JSON round-trip | **SAI-044** `ModelMessageTests.testSyntheticSummaryRoundTripsAsAUserMessageBetweenTurns` | Covered |
| Lossy retain counts synthetic summary as a user turn | source-reviewed | P2 leftover, not a new SAI |

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
| Idempotency: never executed / intent / needsReconciliation / abort | recovery tests | Covered |
| Idempotency: settled retry returns receipt without re-execute | currently rejects same key | Existing backlog SAI-040 |

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
| Generic retry-after delay framework / Pi retry-events | No generic retry API | Not applicable / Future |
| Partial stream then fallback never publishes failed candidate | `partialEventsFromFailedCandidateAreNeverPublished` | Covered |

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
| F Recoverable errors | Fail-closed Covered; channel → SAI-039 |
| G Cancellation | Covered |
| H Timeout | Covered |
| I Terminal events | Covered (Session onFailed path → SAI-042) |
| J wait/drain | Covered (drain Task cancel → SAI-042) |
| K Stream robustness | Covered |
| L Anthropic | Covered for declared subset |
| M Continuation | Covered |
| N Cross-provider | Covered portable + ignore foreign opaque |
| O Tool IDs | Covered |
| P Malformed args | Covered |
| Q Context overflow | Covered (mid-run → SAI-042) |
| R Synthetic summary | Covered |
| S Journal | SwiftAgent stronger (rollover → SAI-042) |
| T Mutation | SwiftAgent stronger |
| U Idempotency | Partial → SAI-040 |
| V Evidence | Covered |
| W Retry/fallback | Covered declared route |
| X Subscribers | Covered |
| Y Lifecycle | Covered |
| Z Unicode | Covered |

---

## Pi has, SwiftAgent does not (applicable)

1. Model-visible recoverable tool error channel — SAI-039.
2. First-class follow-up queue while a Run is in progress — SAI-045.
3. Semantic compaction that preserves dropped tool results — **rejected**. Default is fail-closed (`historyTooLarge`). Lossy opt-in is explicit.
4. Multi-cloud provider catalog (OpenAI Responses, Gemini, Bedrock, …) — N/A until a Host adapter exists.
5. Tool `terminate` / beforeToolCall hooks — Host wrapper, not Core.
6. Async subscriber `waitForIdle` — SwiftAgent `wait()`/`waitForDrain()` is the contract.

## SwiftAgent has, Pi does not (same guarantee)

- EvidenceLedger with `sameRun` / `sameSession` and transcript ≠ permission
- Durable mutation intent before executor
- Typed Receipt and settlement
- Reconciliation / abort / quarantine
- Journal recovery (truncated/corrupt tail, concurrent writer, session lease)
- Mutation replay prevention after side effect, including provider fallback
- `wait()` vs `waitForDrain()` physical identity
- Fail-closed context bound instead of a fake semantic summary
