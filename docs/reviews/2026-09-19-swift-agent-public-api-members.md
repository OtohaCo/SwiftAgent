# SwiftAgent Public API Member Inventory

last-verified: 2026-09-19

Generated from Swift 6.4 public symbol graphs on `plan/swift-agent-rc2`. The published `1.0.0-rc.1` baseline is `d2347f11c6a78f421708e897dae42a51a98d37ea`; the current audited branch adds provider surface without removing a published symbol. Package and internal symbols are intentionally absent.

All 1013 currently public symbols are `KEEP`. Compared with `1.0.0-rc.1`, the exact precise-identifier diff is 57 additions and 0 removals. The additions are additive for clients that do not adopt them; public enum expansion remains source-breaking for exhaustive switches as documented in the versioning guide.

| Module | rc.1 symbols | Current symbols | Delta |
| --- | ---: | ---: | ---: |
| AgentAppleProvider | 5 | 7 | +2 |
| AgentCore | 283 | 283 | +0 |
| AgentModels | 260 | 260 | +0 |
| AgentProviders | 41 | 96 | +55 |
| AgentTools | 311 | 311 | +0 |
| WorkspaceAgent | 56 | 56 | +0 |
| **Total** | **956** | **1013** | **+57** |

Top-level public types: **105** current, **100** in rc.1.

## Post-rc.1 additions

The five new top-level public types are `OpenAIReasoningEffort`, `OpenAIReasoningSummary`, `OpenAIResponsesProvider`, `DeepSeekReasoningEffort`, and `DeepSeekResponsesProvider`. Other added identifiers are their members, synthesized conformances, the Anthropic alias-aware initializer, and Apple Private Cloud Compute members. `DeepSeekReasoningEffort` is a closed enum; adding a future case is source-breaking for exhaustive client switches.

| Module | Kind | Symbol path | Source | Precise identifier | Decision |
| --- | --- | --- | --- | --- | --- |
| AgentAppleProvider | Structure | `AppleFoundationProvider` | `Sources/AgentAppleProvider/AppleFoundationProvider.swift:5` | `s:18AgentAppleProvider0b10FoundationC0V` | KEEP |
| AgentAppleProvider | Instance Property | `AppleFoundationProvider.descriptor` | `Sources/AgentAppleProvider/AppleFoundationProvider.swift:8` | `s:18AgentAppleProvider0b10FoundationC0V10descriptor0A6Models05ModelC10DescriptorVvp` | KEEP |
| AgentAppleProvider | Initializer | `AppleFoundationProvider.init(maximumResponseTokens:)` | `Sources/AgentAppleProvider/AppleNativeGeneration.swift:8` | `s:18AgentAppleProvider0b10FoundationC0V21maximumResponseTokensACSi_tKcfc` | KEEP |
| AgentAppleProvider | Type Property | `AppleFoundationProvider.modelID` | `Sources/AgentAppleProvider/AppleFoundationProvider.swift:6` | `s:18AgentAppleProvider0b10FoundationC0V7modelID0A6Models05ModelF0VvpZ` | KEEP |
| AgentAppleProvider | Type Method | `AppleFoundationProvider.privateCloudCompute(maximumResponseTokens:)` | `Sources/AgentAppleProvider/AppleNativeGeneration.swift:19` | `s:18AgentAppleProvider0b10FoundationC0V19privateCloudCompute21maximumResponseTokensACSi_tKFZ` | KEEP |
| AgentAppleProvider | Type Property | `AppleFoundationProvider.privateCloudComputeModelID` | `Sources/AgentAppleProvider/AppleFoundationProvider.swift:7` | `s:18AgentAppleProvider0b10FoundationC0V26privateCloudComputeModelID0A6Models0hI0VvpZ` | KEEP |
| AgentAppleProvider | Instance Method | `AppleFoundationProvider.stream(request:)` | `Sources/AgentAppleProvider/AppleFoundationProvider.swift:27` | `s:18AgentAppleProvider0b10FoundationC0V6stream7requestScsy0A6Models10ModelEventOs5Error_pGAF0H7RequestV_tF` | KEEP |
| AgentCore | Structure | `Agent` | `Sources/AgentCore/Agent.swift:43` | `s:9AgentCore0A0V` | KEEP |
| AgentCore | Initializer | `Agent.init(model:provider:tools:configuration:)` | `Sources/AgentCore/Agent.swift:48` | `s:9AgentCore0A0V5model8provider5tools13configurationAC0A6Models7ModelIDV_AH0H8Provider_pSay0A5Tools0A4Tool_pGAA0A13ConfigurationVtKcfc` | KEEP |
| AgentCore | Initializer | `Agent.init(model:provider:tools:instructions:)` | `Sources/AgentCore/Agent.swift:72` | `s:9AgentCore0A0V5model8provider5tools12instructionsAC0A6Models7ModelIDV_AH0H8Provider_pSay0A5Tools0A4Tool_pGSStKcfc` | KEEP |
| AgentCore | Instance Method | `Agent.makeSession(id:journal:)` | `Sources/AgentCore/Agent.swift:88` | `s:9AgentCore0A0V11makeSession2id7journalAA0aD0C10Foundation4UUIDV_AA0A7JournalCSgtKF` | KEEP |
| AgentCore | Structure | `AgentBudget` | `Sources/AgentCore/AgentBudget.swift:1` | `s:9AgentCore0A6BudgetV` | KEEP |
| AgentCore | Instance Property | `AgentBudget.deadline` | `Sources/AgentCore/AgentBudget.swift:4` | `s:9AgentCore0A6BudgetV8deadline12_Concurrency15ContinuousClockV7InstantVvp` | KEEP |
| AgentCore | Initializer | `AgentBudget.init(maxModelTurns:maxToolCalls:deadline:)` | `Sources/AgentCore/AgentBudget.swift:8` | `s:9AgentCore0A6BudgetV13maxModelTurns0D9ToolCalls8deadlineACSi_Si12_Concurrency15ContinuousClockV7InstantVtKcfc` | KEEP |
| AgentCore | Instance Property | `AgentBudget.maxModelTurns` | `Sources/AgentCore/AgentBudget.swift:2` | `s:9AgentCore0A6BudgetV13maxModelTurnsSivp` | KEEP |
| AgentCore | Instance Property | `AgentBudget.maxToolCalls` | `Sources/AgentCore/AgentBudget.swift:3` | `s:9AgentCore0A6BudgetV12maxToolCallsSivp` | KEEP |
| AgentCore | Structure | `AgentCompactionSummary` | `Sources/AgentCore/AgentJournal.swift:27` | `s:9AgentCore0A17CompactionSummaryV` | KEEP |
| AgentCore | Operator | `AgentCompactionSummary.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A17CompactionSummaryV` | KEEP |
| AgentCore | Instance Property | `AgentCompactionSummary.constraints` | `Sources/AgentCore/AgentJournal.swift:29` | `s:9AgentCore0A17CompactionSummaryV11constraintsSaySSGvp` | KEEP |
| AgentCore | Instance Property | `AgentCompactionSummary.decisions` | `Sources/AgentCore/AgentJournal.swift:30` | `s:9AgentCore0A17CompactionSummaryV9decisionsSaySSGvp` | KEEP |
| AgentCore | Instance Property | `AgentCompactionSummary.goal` | `Sources/AgentCore/AgentJournal.swift:28` | `s:9AgentCore0A17CompactionSummaryV4goalSSvp` | KEEP |
| AgentCore | Initializer | `AgentCompactionSummary.init(from:)` | `-` | `s:9AgentCore0A17CompactionSummaryV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentCore | Initializer | `AgentCompactionSummary.init(goal:constraints:decisions:openWork:)` | `Sources/AgentCore/AgentJournal.swift:33` | `s:9AgentCore0A17CompactionSummaryV4goal11constraints9decisions8openWorkACSS_SaySSGA2Htcfc` | KEEP |
| AgentCore | Instance Property | `AgentCompactionSummary.openWork` | `Sources/AgentCore/AgentJournal.swift:31` | `s:9AgentCore0A17CompactionSummaryV8openWorkSaySSGvp` | KEEP |
| AgentCore | Structure | `AgentConfiguration` | `Sources/AgentCore/Agent.swift:9` | `s:9AgentCore0A13ConfigurationV` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.contextPolicy` | `Sources/AgentCore/Agent.swift:16` | `s:9AgentCore0A13ConfigurationV13contextPolicyAA0a7ContextE0Vvp` | KEEP |
| AgentCore | Initializer | `AgentConfiguration.init(instructions:structuredOutput:maxModelTurns:maxToolCalls:runTimeout:scheduler:contextPolicy:)` | `Sources/AgentCore/Agent.swift:18` | `s:9AgentCore0A13ConfigurationV12instructions16structuredOutput13maxModelTurns0G9ToolCalls10runTimeout9scheduler13contextPolicyACSS_0A6Models010StructuredF6SchemaVSgS2is8DurationV0A5Tools0J9SchedulerVAA0a7ContextP0Vtcfc` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.instructions` | `Sources/AgentCore/Agent.swift:10` | `s:9AgentCore0A13ConfigurationV12instructionsSSvp` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.maxModelTurns` | `Sources/AgentCore/Agent.swift:12` | `s:9AgentCore0A13ConfigurationV13maxModelTurnsSivp` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.maxToolCalls` | `Sources/AgentCore/Agent.swift:13` | `s:9AgentCore0A13ConfigurationV12maxToolCallsSivp` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.runTimeout` | `Sources/AgentCore/Agent.swift:14` | `s:9AgentCore0A13ConfigurationV10runTimeouts8DurationVvp` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.scheduler` | `Sources/AgentCore/Agent.swift:15` | `s:9AgentCore0A13ConfigurationV9scheduler0A5Tools13ToolSchedulerVvp` | KEEP |
| AgentCore | Instance Property | `AgentConfiguration.structuredOutput` | `Sources/AgentCore/Agent.swift:11` | `s:9AgentCore0A13ConfigurationV16structuredOutput0A6Models010StructuredE6SchemaVSgvp` | KEEP |
| AgentCore | Protocol | `AgentContextCompactor` | `Sources/AgentCore/AgentContext.swift:13` | `s:9AgentCore0A16ContextCompactorP` | KEEP |
| AgentCore | Instance Method | `AgentContextCompactor.summarize(droppedConversation:)` | `Sources/AgentCore/AgentContext.swift:14` | `s:9AgentCore0A16ContextCompactorP9summarize19droppedConversationAA0A17CompactionSummaryVSay0A6Models12ModelMessageOG_tYaKF` | KEEP |
| AgentCore | Enumeration | `AgentContextError` | `Sources/AgentCore/AgentContext.swift:6` | `s:9AgentCore0A12ContextErrorO` | KEEP |
| AgentCore | Operator | `AgentContextError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A12ContextErrorO` | KEEP |
| AgentCore | Case | `AgentContextError.historyTooLarge(bytes:limit:)` | `Sources/AgentCore/AgentContext.swift:8` | `s:9AgentCore0A12ContextErrorO15historyTooLargeyACSi_SitcACmF` | KEEP |
| AgentCore | Case | `AgentContextError.inputTooLarge(bytes:limit:)` | `Sources/AgentCore/AgentContext.swift:7` | `s:9AgentCore0A12ContextErrorO13inputTooLargeyACSi_SitcACmF` | KEEP |
| AgentCore | Instance Property | `AgentContextError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A12ContextErrorO` | KEEP |
| AgentCore | Structure | `AgentContextPolicy` | `Sources/AgentCore/AgentContext.swift:41` | `s:9AgentCore0A13ContextPolicyV` | KEEP |
| AgentCore | Instance Property | `AgentContextPolicy.compactor` | `Sources/AgentCore/AgentContext.swift:45` | `s:9AgentCore0A13ContextPolicyV9compactorAA0aC9Compactor_pSgvp` | KEEP |
| AgentCore | Type Property | `AgentContextPolicy.default` | `Sources/AgentCore/AgentContext.swift:47` | `s:9AgentCore0A13ContextPolicyV7defaultACvpZ` | KEEP |
| AgentCore | Initializer | `AgentContextPolicy.init(maxInputUTF8Bytes:maxActiveHistoryUTF8Bytes:retainedRecentTurnCount:compactor:)` | `Sources/AgentCore/AgentContext.swift:69` | `s:9AgentCore0A13ContextPolicyV17maxInputUTF8Bytes0e13ActiveHistorygH023retainedRecentTurnCount9compactorACSi_S2iAA0aC9Compactor_pSgtcfc` | KEEP |
| AgentCore | Type Method | `AgentContextPolicy.lossyRetainedTurns(maxInputUTF8Bytes:maxActiveHistoryUTF8Bytes:retainedRecentTurnCount:)` | `Sources/AgentCore/AgentContext.swift:56` | `s:9AgentCore0A13ContextPolicyV18lossyRetainedTurns17maxInputUTF8Bytes0h13ActiveHistoryjK023retainedRecentTurnCountACSi_S2itFZ` | KEEP |
| AgentCore | Instance Property | `AgentContextPolicy.maxActiveHistoryUTF8Bytes` | `Sources/AgentCore/AgentContext.swift:43` | `s:9AgentCore0A13ContextPolicyV25maxActiveHistoryUTF8BytesSivp` | KEEP |
| AgentCore | Instance Property | `AgentContextPolicy.maxInputUTF8Bytes` | `Sources/AgentCore/AgentContext.swift:42` | `s:9AgentCore0A13ContextPolicyV17maxInputUTF8BytesSivp` | KEEP |
| AgentCore | Instance Property | `AgentContextPolicy.retainedRecentTurnCount` | `Sources/AgentCore/AgentContext.swift:44` | `s:9AgentCore0A13ContextPolicyV23retainedRecentTurnCountSivp` | KEEP |
| AgentCore | Enumeration | `AgentEvent` | `Sources/AgentCore/AgentEvent.swift:28` | `s:9AgentCore0A5EventO` | KEEP |
| AgentCore | Operator | `AgentEvent.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A5EventO` | KEEP |
| AgentCore | Case | `AgentEvent.model(_:)` | `Sources/AgentCore/AgentEvent.swift:31` | `s:9AgentCore0A5EventO5modelyAC0A6Models05ModelC0OcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.runFinished(_:)` | `Sources/AgentCore/AgentEvent.swift:38` | `s:9AgentCore0A5EventO11runFinishedyAcA0A14RunTerminationOcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.runStarted(_:)` | `Sources/AgentCore/AgentEvent.swift:29` | `s:9AgentCore0A5EventO10runStartedyAcA0A7RunInfoVcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.steeringApplied(id:text:)` | `Sources/AgentCore/AgentEvent.swift:37` | `s:9AgentCore0A5EventO15steeringAppliedyAC10Foundation4UUIDV_SStcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.toolCompleted(_:)` | `Sources/AgentCore/AgentEvent.swift:34` | `s:9AgentCore0A5EventO13toolCompletedyAC0A6Models17ToolResultMessageVcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.toolFailed(_:_:)` | `Sources/AgentCore/AgentEvent.swift:36` | `s:9AgentCore0A5EventO10toolFailedyAC0A6Models10ToolCallIDV_AA0A7FailureOtcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.toolReceiptValidated(_:)` | `Sources/AgentCore/AgentEvent.swift:35` | `s:9AgentCore0A5EventO20toolReceiptValidatedyAcA0a4ToolE0VcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.toolStarted(_:)` | `Sources/AgentCore/AgentEvent.swift:33` | `s:9AgentCore0A5EventO11toolStartedyAC0A6Models8ToolCallVcACmF` | KEEP |
| AgentCore | Case | `AgentEvent.turnStarted(_:)` | `Sources/AgentCore/AgentEvent.swift:30` | `s:9AgentCore0A5EventO11turnStartedyACSicACmF` | KEEP |
| AgentCore | Enumeration | `AgentFailure` | `Sources/AgentCore/AgentEvent.swift:77` | `s:9AgentCore0A7FailureO` | KEEP |
| AgentCore | Operator | `AgentFailure.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A7FailureO` | KEEP |
| AgentCore | Case | `AgentFailure.cancelled` | `Sources/AgentCore/AgentEvent.swift:91` | `s:9AgentCore0A7FailureO9cancelledyA2CmF` | KEEP |
| AgentCore | Case | `AgentFailure.context(_:)` | `Sources/AgentCore/AgentEvent.swift:90` | `s:9AgentCore0A7FailureO7contextyAcA0A12ContextErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.evidence(_:)` | `Sources/AgentCore/AgentEvent.swift:84` | `s:9AgentCore0A7FailureO8evidenceyAC0A5Tools13EvidenceErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.journal(_:)` | `Sources/AgentCore/AgentEvent.swift:88` | `s:9AgentCore0A7FailureO7journalyAcA0A12JournalErrorOcACmF` | KEEP |
| AgentCore | Instance Property | `AgentFailure.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A7FailureO` | KEEP |
| AgentCore | Case | `AgentFailure.loop(_:)` | `Sources/AgentCore/AgentEvent.swift:78` | `s:9AgentCore0A7FailureO4loopyAcA0A9LoopErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.modelStream(_:)` | `Sources/AgentCore/AgentEvent.swift:81` | `s:9AgentCore0A7FailureO11modelStreamyAC0A6Models05ModelE5ErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.mutationPersistence(_:)` | `Sources/AgentCore/AgentEvent.swift:89` | `s:9AgentCore0A7FailureO19mutationPersistenceyAcA0a8MutationE5ErrorVcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.provider(_:)` | `Sources/AgentCore/AgentEvent.swift:80` | `s:9AgentCore0A7FailureO8provideryAC0A6Models18ModelProviderErrorVcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.receipt(_:)` | `Sources/AgentCore/AgentEvent.swift:85` | `s:9AgentCore0A7FailureO7receiptyAC0A5Tools16ToolReceiptErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.resource(_:)` | `Sources/AgentCore/AgentEvent.swift:86` | `s:9AgentCore0A7FailureO8resourceyAC0A5Tools17ToolResourceErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.scheduler(_:)` | `Sources/AgentCore/AgentEvent.swift:87` | `s:9AgentCore0A7FailureO9scheduleryAC0A5Tools18ToolSchedulerErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.session(_:)` | `Sources/AgentCore/AgentEvent.swift:79` | `s:9AgentCore0A7FailureO7sessionyAcA0A12SessionErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.toolInvocation(_:)` | `Sources/AgentCore/AgentEvent.swift:83` | `s:9AgentCore0A7FailureO14toolInvocationyAC0A5Tools04ToolE5ErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.toolRegistry(_:)` | `Sources/AgentCore/AgentEvent.swift:82` | `s:9AgentCore0A7FailureO12toolRegistryyAC0A5Tools04ToolE5ErrorOcACmF` | KEEP |
| AgentCore | Case | `AgentFailure.unclassified` | `Sources/AgentCore/AgentEvent.swift:92` | `s:9AgentCore0A7FailureO12unclassifiedyA2CmF` | KEEP |
| AgentCore | Class | `AgentJournal` | `Sources/AgentCore/AgentJournal.swift:279` | `s:9AgentCore0A7JournalC` | KEEP |
| AgentCore | Instance Method | `AgentJournal.abortMutation(_:)` | `Sources/AgentCore/AgentJournal.swift:745` | `s:9AgentCore0A7JournalC13abortMutationyyAA07PendingE8RecoveryVKF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.assertIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assertIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:9AgentCore0A7JournalC` | KEEP |
| AgentCore | Instance Method | `AgentJournal.assumeIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assumeIsolated_4file4lineqd__qd__xYiKXE_s12StaticStringVSutKs8SendableRd__lF::SYNTHESIZED::s:9AgentCore0A7JournalC` | KEEP |
| AgentCore | Instance Method | `AgentJournal.discardCorruptTail()` | `Sources/AgentCore/AgentJournal.swift:471` | `s:9AgentCore0A7JournalC18discardCorruptTailyyKF` | KEEP |
| AgentCore | Initializer | `AgentJournal.init()` | `Sources/AgentCore/AgentJournal.swift:333` | `s:9AgentCore0A7JournalCACycfc` | KEEP |
| AgentCore | Initializer | `AgentJournal.init(persistenceURL:)` | `Sources/AgentCore/AgentJournal.swift:351` | `s:9AgentCore0A7JournalC14persistenceURLAC10Foundation0E0V_tKcfc` | KEEP |
| AgentCore | Instance Method | `AgentJournal.latestCheckpoint(sessionID:)` | `Sources/AgentCore/AgentJournal.swift:457` | `s:9AgentCore0A7JournalC16latestCheckpoint9sessionIDSay0A6Models12ModelMessageOG7history_Say10Foundation4UUIDVG11steeringIDstSgAM_tF` | KEEP |
| AgentCore | Type Method | `AgentJournal.load(from:)` | `Sources/AgentCore/AgentJournal.swift:392` | `s:9AgentCore0A7JournalC4load4fromAC10Foundation3URLV_tKFZ` | KEEP |
| AgentCore | Type Property | `AgentJournal.maximumFrameSize` | `Sources/AgentCore/AgentJournal.swift:292` | `s:9AgentCore0A7JournalC16maximumFrameSizeSivpZ` | KEEP |
| AgentCore | Instance Method | `AgentJournal.pendingMutations(sessionID:)` | `Sources/AgentCore/AgentJournal.swift:578` | `s:9AgentCore0A7JournalC16pendingMutations9sessionIDSayAA23PendingMutationRecoveryVG10Foundation4UUIDVSg_tF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.persist(to:)` | `Sources/AgentCore/AgentJournal.swift:1020` | `s:9AgentCore0A7JournalC7persist2toy10Foundation3URLV_tKF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.preconditionIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE20preconditionIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:9AgentCore0A7JournalC` | KEEP |
| AgentCore | Instance Method | `AgentJournal.reconcileMutation(_:receipt:)` | `Sources/AgentCore/AgentJournal.swift:674` | `s:9AgentCore0A7JournalC17reconcileMutation_7receiptyAA07PendingE8RecoveryV_0A5Tools11ToolReceiptVtKF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.reconcileMutation(_:receipt:output:)` | `Sources/AgentCore/AgentJournal.swift:679` | `s:9AgentCore0A7JournalC17reconcileMutation_7receipt6outputyAA07PendingE8RecoveryV_0A5Tools11ToolReceiptV0A6Models9JSONValueOtKF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.reconcileMutation(_:receipt:receiptExpectation:)` | `Sources/AgentCore/AgentJournal.swift:689` | `s:9AgentCore0A7JournalC17reconcileMutation_7receipt0F11ExpectationyAA07PendingE8RecoveryV_0A5Tools11ToolReceiptVAI0klG0VSgtKF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.reconcileMutation(_:receipt:receiptExpectation:output:)` | `Sources/AgentCore/AgentJournal.swift:695` | `s:9AgentCore0A7JournalC17reconcileMutation_7receipt0F11Expectation6outputyAA07PendingE8RecoveryV_0A5Tools11ToolReceiptVAJ0lmG0VSg0A6Models9JSONValueOtKF` | KEEP |
| AgentCore | Instance Method | `AgentJournal.recoverPendingMutations(sessionID:)` | `Sources/AgentCore/AgentJournal.swift:592` | `s:9AgentCore0A7JournalC23recoverPendingMutations9sessionIDSayAA0E16MutationRecoveryVG10Foundation4UUIDVSg_tKF` | KEEP |
| AgentCore | Instance Property | `AgentJournal.recovery` | `Sources/AgentCore/AgentJournal.swift:467` | `s:9AgentCore0A7JournalC8recoveryAA0aC8RecoveryOvp` | KEEP |
| AgentCore | Instance Method | `AgentJournal.snapshot()` | `Sources/AgentCore/AgentJournal.swift:399` | `s:9AgentCore0A7JournalC8snapshotSayAA0aC6RecordVGyF` | KEEP |
| AgentCore | Instance Property | `AgentJournal.storage` | `Sources/AgentCore/AgentJournal.swift:311` | `s:9AgentCore0A7JournalC7storageAA0aC7StorageOvp` | KEEP |
| AgentCore | Instance Method | `AgentJournal.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pqd_0_YKXEqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:9AgentCore0A7JournalC` | KEEP |
| AgentCore | Instance Method | `AgentJournal.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pYaqd_0_YKYCXEYaqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:9AgentCore0A7JournalC` | KEEP |
| AgentCore | Enumeration | `AgentJournalError` | `Sources/AgentCore/AgentJournal.swift:193` | `s:9AgentCore0A12JournalErrorO` | KEEP |
| AgentCore | Operator | `AgentJournalError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A12JournalErrorO` | KEEP |
| AgentCore | Case | `AgentJournalError.checksumMismatch` | `Sources/AgentCore/AgentJournal.swift:197` | `s:9AgentCore0A12JournalErrorO16checksumMismatchyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.concurrentWriter` | `Sources/AgentCore/AgentJournal.swift:198` | `s:9AgentCore0A12JournalErrorO16concurrentWriteryA2CmF` | KEEP |
| AgentCore | Instance Property | `AgentJournalError.errorDescription` | `Sources/AgentCore/AgentJournal.swift:212` | `s:9AgentCore0A12JournalErrorO16errorDescriptionSSSgvp` | KEEP |
| AgentCore | Instance Property | `AgentJournalError.failureReason` | `-` | `s:10Foundation14LocalizedErrorPAAE13failureReasonSSSgvp::SYNTHESIZED::s:9AgentCore0A12JournalErrorO` | KEEP |
| AgentCore | Instance Property | `AgentJournalError.helpAnchor` | `-` | `s:10Foundation14LocalizedErrorPAAE10helpAnchorSSSgvp::SYNTHESIZED::s:9AgentCore0A12JournalErrorO` | KEEP |
| AgentCore | Case | `AgentJournalError.invalidFrame` | `Sources/AgentCore/AgentJournal.swift:195` | `s:9AgentCore0A12JournalErrorO12invalidFrameyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.invalidHeader` | `Sources/AgentCore/AgentJournal.swift:194` | `s:9AgentCore0A12JournalErrorO13invalidHeaderyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.invalidMutationIntent` | `Sources/AgentCore/AgentJournal.swift:199` | `s:9AgentCore0A12JournalErrorO21invalidMutationIntentyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.invalidRecord` | `Sources/AgentCore/AgentJournal.swift:196` | `s:9AgentCore0A12JournalErrorO13invalidRecordyA2CmF` | KEEP |
| AgentCore | Instance Property | `AgentJournalError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A12JournalErrorO` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationIntentConflict` | `Sources/AgentCore/AgentJournal.swift:200` | `s:9AgentCore0A12JournalErrorO22mutationIntentConflictyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationMissingReceiptExpectation` | `Sources/AgentCore/AgentJournal.swift:206` | `s:9AgentCore0A12JournalErrorO33mutationMissingReceiptExpectationyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationNotFound` | `Sources/AgentCore/AgentJournal.swift:204` | `s:9AgentCore0A12JournalErrorO16mutationNotFoundyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationPending` | `Sources/AgentCore/AgentJournal.swift:201` | `s:9AgentCore0A12JournalErrorO15mutationPendingyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationReceiptInvalid` | `Sources/AgentCore/AgentJournal.swift:205` | `s:9AgentCore0A12JournalErrorO22mutationReceiptInvalidyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationReplayUnavailable` | `Sources/AgentCore/AgentJournal.swift:202` | `s:9AgentCore0A12JournalErrorO25mutationReplayUnavailableyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationRequiresReconciliation` | `Sources/AgentCore/AgentJournal.swift:203` | `s:9AgentCore0A12JournalErrorO30mutationRequiresReconciliationyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.mutationSettlementRequiresReconciliation` | `Sources/AgentCore/AgentJournal.swift:207` | `s:9AgentCore0A12JournalErrorO40mutationSettlementRequiresReconciliationyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.persistenceUnavailable(_:)` | `Sources/AgentCore/AgentJournal.swift:208` | `s:9AgentCore0A12JournalErrorO22persistenceUnavailableyACSScACmF` | KEEP |
| AgentCore | Instance Property | `AgentJournalError.recoverySuggestion` | `-` | `s:10Foundation14LocalizedErrorPAAE18recoverySuggestionSSSgvp::SYNTHESIZED::s:9AgentCore0A12JournalErrorO` | KEEP |
| AgentCore | Case | `AgentJournalError.repairRequired` | `Sources/AgentCore/AgentJournal.swift:210` | `s:9AgentCore0A12JournalErrorO14repairRequiredyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalError.sessionLeaseUnavailable` | `Sources/AgentCore/AgentJournal.swift:209` | `s:9AgentCore0A12JournalErrorO23sessionLeaseUnavailableyA2CmF` | KEEP |
| AgentCore | Enumeration | `AgentJournalEvent` | `Sources/AgentCore/AgentJournal.swift:74` | `s:9AgentCore0A12JournalEventO` | KEEP |
| AgentCore | Operator | `AgentJournalEvent.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A12JournalEventO` | KEEP |
| AgentCore | Case | `AgentJournalEvent.assistantMessage(content:toolCalls:)` | `Sources/AgentCore/AgentJournal.swift:77` | `s:9AgentCore0A12JournalEventO16assistantMessageyACSay0A6Models12ModelContentOG_SayAE8ToolCallVGtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.checkpoint(history:steeringIDs:)` | `Sources/AgentCore/AgentJournal.swift:91` | `s:9AgentCore0A12JournalEventO10checkpointyACSay0A6Models12ModelMessageOG_Say10Foundation4UUIDVGtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.compaction(_:)` | `Sources/AgentCore/AgentJournal.swift:92` | `s:9AgentCore0A12JournalEventO10compactionyAcA0A17CompactionSummaryVcACmF` | KEEP |
| AgentCore | Initializer | `AgentJournalEvent.init(from:)` | `-` | `s:9AgentCore0A12JournalEventO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentCore | Case | `AgentJournalEvent.modelAttempt(turn:model:)` | `Sources/AgentCore/AgentJournal.swift:78` | `s:9AgentCore0A12JournalEventO12modelAttemptyACSi_0A6Models7ModelIDVtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.modelCompleted(_:)` | `Sources/AgentCore/AgentJournal.swift:79` | `s:9AgentCore0A12JournalEventO14modelCompletedyAC0A6Models13ModelResponseVcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.mutationAborted(callID:)` | `Sources/AgentCore/AgentJournal.swift:90` | `s:9AgentCore0A12JournalEventO15mutationAbortedyAC0A6Models10ToolCallIDV_tcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.mutationNeedsReconciliation(callID:)` | `Sources/AgentCore/AgentJournal.swift:87` | `s:9AgentCore0A12JournalEventO27mutationNeedsReconciliationyAC0A6Models10ToolCallIDV_tcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.mutationOutput(callID:output:)` | `Sources/AgentCore/AgentJournal.swift:88` | `s:9AgentCore0A12JournalEventO14mutationOutputyAC0A6Models10ToolCallIDV_AE9JSONValueOtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.mutationReceiptExpectation(callID:expectation:)` | `Sources/AgentCore/AgentJournal.swift:86` | `s:9AgentCore0A12JournalEventO26mutationReceiptExpectationyAC0A6Models10ToolCallIDV_0A5Tools0ifG0VtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.mutationSettled(callID:receipt:source:)` | `Sources/AgentCore/AgentJournal.swift:89` | `s:9AgentCore0A12JournalEventO15mutationSettledyAC0A6Models10ToolCallIDV_0A5Tools0H7ReceiptVAA0A24MutationSettlementSourceOtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.pendingMutation(_:)` | `Sources/AgentCore/AgentJournal.swift:85` | `s:9AgentCore0A12JournalEventO15pendingMutationyAcA07PendingF6IntentVcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.runCompleted(_:)` | `Sources/AgentCore/AgentJournal.swift:93` | `s:9AgentCore0A12JournalEventO12runCompletedyAcA0aC10RunOutcomeOcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.sessionCreated` | `Sources/AgentCore/AgentJournal.swift:75` | `s:9AgentCore0A12JournalEventO14sessionCreatedyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.toolAuthorized(callID:)` | `Sources/AgentCore/AgentJournal.swift:81` | `s:9AgentCore0A12JournalEventO14toolAuthorizedyAC0A6Models10ToolCallIDV_tcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.toolCompleted(_:)` | `Sources/AgentCore/AgentJournal.swift:83` | `s:9AgentCore0A12JournalEventO13toolCompletedyAC0A6Models17ToolResultMessageVcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.toolProposed(call:effect:resources:)` | `Sources/AgentCore/AgentJournal.swift:80` | `s:9AgentCore0A12JournalEventO12toolProposedyAC0A6Models8ToolCallV_0A5Tools0H6PolicyV6EffectOSayAH0H8ResourceOGtcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.toolReceipt(_:)` | `Sources/AgentCore/AgentJournal.swift:84` | `s:9AgentCore0A12JournalEventO11toolReceiptyAcA0a4ToolF0VcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.toolStarted(callID:)` | `Sources/AgentCore/AgentJournal.swift:82` | `s:9AgentCore0A12JournalEventO11toolStartedyAC0A6Models10ToolCallIDV_tcACmF` | KEEP |
| AgentCore | Case | `AgentJournalEvent.userMessage(_:)` | `Sources/AgentCore/AgentJournal.swift:76` | `s:9AgentCore0A12JournalEventO11userMessageyACSScACmF` | KEEP |
| AgentCore | Structure | `AgentJournalRecord` | `Sources/AgentCore/AgentJournal.swift:136` | `s:9AgentCore0A13JournalRecordV` | KEEP |
| AgentCore | Operator | `AgentJournalRecord.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A13JournalRecordV` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.checkpointID` | `Sources/AgentCore/AgentJournal.swift:145` | `s:9AgentCore0A13JournalRecordV12checkpointID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.event` | `Sources/AgentCore/AgentJournal.swift:146` | `s:9AgentCore0A13JournalRecordV5eventAA0aC5EventOvp` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.id` | `Sources/AgentCore/AgentJournal.swift:139` | `s:9AgentCore0A13JournalRecordV2id10Foundation4UUIDVvp` | KEEP |
| AgentCore | Initializer | `AgentJournalRecord.init(from:)` | `-` | `s:9AgentCore0A13JournalRecordV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.runID` | `Sources/AgentCore/AgentJournal.swift:144` | `s:9AgentCore0A13JournalRecordV5runID10Foundation4UUIDVSgvp` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.schemaVersion` | `Sources/AgentCore/AgentJournal.swift:142` | `s:9AgentCore0A13JournalRecordV13schemaVersionSivp` | KEEP |
| AgentCore | Type Property | `AgentJournalRecord.schemaVersion` | `Sources/AgentCore/AgentJournal.swift:137` | `s:9AgentCore0A13JournalRecordV13schemaVersionSivpZ` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.sequence` | `Sources/AgentCore/AgentJournal.swift:140` | `s:9AgentCore0A13JournalRecordV8sequences6UInt64Vvp` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.sessionID` | `Sources/AgentCore/AgentJournal.swift:143` | `s:9AgentCore0A13JournalRecordV9sessionID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Property | `AgentJournalRecord.timestamp` | `Sources/AgentCore/AgentJournal.swift:141` | `s:9AgentCore0A13JournalRecordV9timestamp10Foundation4DateVvp` | KEEP |
| AgentCore | Enumeration | `AgentJournalRecovery` | `Sources/AgentCore/AgentJournal.swift:169` | `s:9AgentCore0A15JournalRecoveryO` | KEEP |
| AgentCore | Operator | `AgentJournalRecovery.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A15JournalRecoveryO` | KEEP |
| AgentCore | Case | `AgentJournalRecovery.clean` | `Sources/AgentCore/AgentJournal.swift:170` | `s:9AgentCore0A15JournalRecoveryO5cleanyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalRecovery.corruptTail` | `Sources/AgentCore/AgentJournal.swift:174` | `s:9AgentCore0A15JournalRecoveryO11corruptTailyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalRecovery.truncatedTail` | `Sources/AgentCore/AgentJournal.swift:172` | `s:9AgentCore0A15JournalRecoveryO13truncatedTailyA2CmF` | KEEP |
| AgentCore | Enumeration | `AgentJournalRunOutcome` | `Sources/AgentCore/AgentJournal.swift:41` | `s:9AgentCore0A17JournalRunOutcomeO` | KEEP |
| AgentCore | Operator | `AgentJournalRunOutcome.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A17JournalRunOutcomeO` | KEEP |
| AgentCore | Case | `AgentJournalRunOutcome.cancelled` | `Sources/AgentCore/AgentJournal.swift:44` | `s:9AgentCore0A17JournalRunOutcomeO9cancelledyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalRunOutcome.completed` | `Sources/AgentCore/AgentJournal.swift:42` | `s:9AgentCore0A17JournalRunOutcomeO9completedyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalRunOutcome.failed(code:)` | `Sources/AgentCore/AgentJournal.swift:43` | `s:9AgentCore0A17JournalRunOutcomeO6failedyACSS_tcACmF` | KEEP |
| AgentCore | Initializer | `AgentJournalRunOutcome.init(from:)` | `-` | `s:9AgentCore0A17JournalRunOutcomeO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentCore | Enumeration | `AgentJournalStorage` | `Sources/AgentCore/AgentJournal.swift:243` | `s:9AgentCore0A14JournalStorageO` | KEEP |
| AgentCore | Operator | `AgentJournalStorage.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A14JournalStorageO` | KEEP |
| AgentCore | Case | `AgentJournalStorage.durable` | `Sources/AgentCore/AgentJournal.swift:247` | `s:9AgentCore0A14JournalStorageO7durableyA2CmF` | KEEP |
| AgentCore | Case | `AgentJournalStorage.memory` | `Sources/AgentCore/AgentJournal.swift:245` | `s:9AgentCore0A14JournalStorageO6memoryyA2CmF` | KEEP |
| AgentCore | Enumeration | `AgentLoopError` | `Sources/AgentCore/AgentLoop.swift:286` | `s:9AgentCore0A9LoopErrorO` | KEEP |
| AgentCore | Operator | `AgentLoopError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A9LoopErrorO` | KEEP |
| AgentCore | Case | `AgentLoopError.deadlineExceeded` | `Sources/AgentCore/AgentLoop.swift:293` | `s:9AgentCore0A9LoopErrorO16deadlineExceededyA2CmF` | KEEP |
| AgentCore | Case | `AgentLoopError.invalidBudget` | `Sources/AgentCore/AgentLoop.swift:290` | `s:9AgentCore0A9LoopErrorO13invalidBudgetyA2CmF` | KEEP |
| AgentCore | Instance Property | `AgentLoopError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A9LoopErrorO` | KEEP |
| AgentCore | Case | `AgentLoopError.modelMismatch` | `Sources/AgentCore/AgentLoop.swift:287` | `s:9AgentCore0A9LoopErrorO13modelMismatchyA2CmF` | KEEP |
| AgentCore | Case | `AgentLoopError.modelTurnLimitReached` | `Sources/AgentCore/AgentLoop.swift:291` | `s:9AgentCore0A9LoopErrorO21modelTurnLimitReachedyA2CmF` | KEEP |
| AgentCore | Case | `AgentLoopError.providerMismatch` | `Sources/AgentCore/AgentLoop.swift:288` | `s:9AgentCore0A9LoopErrorO16providerMismatchyA2CmF` | KEEP |
| AgentCore | Case | `AgentLoopError.reusedToolCallID(_:)` | `Sources/AgentCore/AgentLoop.swift:294` | `s:9AgentCore0A9LoopErrorO16reusedToolCallIDyAC0A6Models0fgH0VcACmF` | KEEP |
| AgentCore | Case | `AgentLoopError.toolCallLimitReached` | `Sources/AgentCore/AgentLoop.swift:292` | `s:9AgentCore0A9LoopErrorO20toolCallLimitReachedyA2CmF` | KEEP |
| AgentCore | Case | `AgentLoopError.toolTimedOut(_:)` | `Sources/AgentCore/AgentLoop.swift:295` | `s:9AgentCore0A9LoopErrorO12toolTimedOutyAC0A6Models10ToolCallIDVcACmF` | KEEP |
| AgentCore | Case | `AgentLoopError.unsupportedCapabilities(_:)` | `Sources/AgentCore/AgentLoop.swift:289` | `s:9AgentCore0A9LoopErrorO23unsupportedCapabilitiesyAC0A6Models05ModelF0VcACmF` | KEEP |
| AgentCore | Enumeration | `AgentLoopOutcome` | `Sources/AgentCore/AgentLoop.swift:271` | `s:9AgentCore0A11LoopOutcomeO` | KEEP |
| AgentCore | Operator | `AgentLoopOutcome.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A11LoopOutcomeO` | KEEP |
| AgentCore | Case | `AgentLoopOutcome.completed` | `Sources/AgentCore/AgentLoop.swift:272` | `s:9AgentCore0A11LoopOutcomeO9completedyA2CmF` | KEEP |
| AgentCore | Case | `AgentLoopOutcome.incomplete(_:)` | `Sources/AgentCore/AgentLoop.swift:274` | `s:9AgentCore0A11LoopOutcomeO10incompleteyAC0A6Models10StopReasonOcACmF` | KEEP |
| AgentCore | Case | `AgentLoopOutcome.refused` | `Sources/AgentCore/AgentLoop.swift:273` | `s:9AgentCore0A11LoopOutcomeO7refusedyA2CmF` | KEEP |
| AgentCore | Structure | `AgentLoopResult` | `Sources/AgentCore/AgentLoop.swift:277` | `s:9AgentCore0A10LoopResultV` | KEEP |
| AgentCore | Operator | `AgentLoopResult.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A10LoopResultV` | KEEP |
| AgentCore | Instance Property | `AgentLoopResult.history` | `Sources/AgentCore/AgentLoop.swift:279` | `s:9AgentCore0A10LoopResultV7historySay0A6Models12ModelMessageOGvp` | KEEP |
| AgentCore | Instance Property | `AgentLoopResult.modelTurns` | `Sources/AgentCore/AgentLoop.swift:281` | `s:9AgentCore0A10LoopResultV10modelTurnsSivp` | KEEP |
| AgentCore | Instance Property | `AgentLoopResult.outcome` | `Sources/AgentCore/AgentLoop.swift:280` | `s:9AgentCore0A10LoopResultV7outcomeAA0aC7OutcomeOvp` | KEEP |
| AgentCore | Instance Property | `AgentLoopResult.receipts` | `Sources/AgentCore/AgentLoop.swift:283` | `s:9AgentCore0A10LoopResultV8receiptsSayAA0A11ToolReceiptVGvp` | KEEP |
| AgentCore | Instance Property | `AgentLoopResult.response` | `Sources/AgentCore/AgentLoop.swift:278` | `s:9AgentCore0A10LoopResultV8response0A6Models13ModelResponseVvp` | KEEP |
| AgentCore | Instance Property | `AgentLoopResult.toolCalls` | `Sources/AgentCore/AgentLoop.swift:282` | `s:9AgentCore0A10LoopResultV9toolCallsSivp` | KEEP |
| AgentCore | Structure | `AgentMutationPersistenceError` | `Sources/AgentCore/AgentEvent.swift:49` | `s:9AgentCore0A24MutationPersistenceErrorV` | KEEP |
| AgentCore | Operator | `AgentMutationPersistenceError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A24MutationPersistenceErrorV` | KEEP |
| AgentCore | Initializer | `AgentMutationPersistenceError.init(settlement:quarantine:)` | `Sources/AgentCore/AgentEvent.swift:53` | `s:9AgentCore0A24MutationPersistenceErrorV10settlement10quarantineAcA0A7FailureO_AGtcfc` | KEEP |
| AgentCore | Instance Property | `AgentMutationPersistenceError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A24MutationPersistenceErrorV` | KEEP |
| AgentCore | Instance Property | `AgentMutationPersistenceError.quarantine` | `Sources/AgentCore/AgentEvent.swift:51` | `s:9AgentCore0A24MutationPersistenceErrorV10quarantineAA0A7FailureOvp` | KEEP |
| AgentCore | Instance Property | `AgentMutationPersistenceError.settlement` | `Sources/AgentCore/AgentEvent.swift:50` | `s:9AgentCore0A24MutationPersistenceErrorV10settlementAA0A7FailureOvp` | KEEP |
| AgentCore | Enumeration | `AgentMutationSettlementSource` | `Sources/AgentCore/AgentJournal.swift:54` | `s:9AgentCore0A24MutationSettlementSourceO` | KEEP |
| AgentCore | Operator | `AgentMutationSettlementSource.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A24MutationSettlementSourceO` | KEEP |
| AgentCore | Instance Method | `AgentMutationSettlementSource.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:9AgentCore0A24MutationSettlementSourceO` | KEEP |
| AgentCore | Case | `AgentMutationSettlementSource.executor` | `Sources/AgentCore/AgentJournal.swift:55` | `s:9AgentCore0A24MutationSettlementSourceO8executoryA2CmF` | KEEP |
| AgentCore | Instance Method | `AgentMutationSettlementSource.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:9AgentCore0A24MutationSettlementSourceO` | KEEP |
| AgentCore | Instance Property | `AgentMutationSettlementSource.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:9AgentCore0A24MutationSettlementSourceO` | KEEP |
| AgentCore | Initializer | `AgentMutationSettlementSource.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:9AgentCore0A24MutationSettlementSourceO` | KEEP |
| AgentCore | Initializer | `AgentMutationSettlementSource.init(rawValue:)` | `-` | `s:9AgentCore0A24MutationSettlementSourceO8rawValueACSgSS_tcfc` | KEEP |
| AgentCore | Case | `AgentMutationSettlementSource.reconciliation` | `Sources/AgentCore/AgentJournal.swift:56` | `s:9AgentCore0A24MutationSettlementSourceO14reconciliationyA2CmF` | KEEP |
| AgentCore | Enumeration | `AgentMutationState` | `Sources/AgentCore/AgentJournal.swift:47` | `s:9AgentCore0A13MutationStateO` | KEEP |
| AgentCore | Operator | `AgentMutationState.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A13MutationStateO` | KEEP |
| AgentCore | Case | `AgentMutationState.aborted` | `Sources/AgentCore/AgentJournal.swift:51` | `s:9AgentCore0A13MutationStateO7abortedyA2CmF` | KEEP |
| AgentCore | Instance Method | `AgentMutationState.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:9AgentCore0A13MutationStateO` | KEEP |
| AgentCore | Instance Method | `AgentMutationState.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:9AgentCore0A13MutationStateO` | KEEP |
| AgentCore | Instance Property | `AgentMutationState.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:9AgentCore0A13MutationStateO` | KEEP |
| AgentCore | Initializer | `AgentMutationState.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:9AgentCore0A13MutationStateO` | KEEP |
| AgentCore | Initializer | `AgentMutationState.init(rawValue:)` | `-` | `s:9AgentCore0A13MutationStateO8rawValueACSgSS_tcfc` | KEEP |
| AgentCore | Case | `AgentMutationState.intent` | `Sources/AgentCore/AgentJournal.swift:48` | `s:9AgentCore0A13MutationStateO6intentyA2CmF` | KEEP |
| AgentCore | Case | `AgentMutationState.needsReconciliation` | `Sources/AgentCore/AgentJournal.swift:49` | `s:9AgentCore0A13MutationStateO19needsReconciliationyA2CmF` | KEEP |
| AgentCore | Case | `AgentMutationState.settled` | `Sources/AgentCore/AgentJournal.swift:50` | `s:9AgentCore0A13MutationStateO7settledyA2CmF` | KEEP |
| AgentCore | Structure | `AgentRetainedTurnCompactor` | `Sources/AgentCore/AgentContext.swift:20` | `s:9AgentCore0A21RetainedTurnCompactorV` | KEEP |
| AgentCore | Initializer | `AgentRetainedTurnCompactor.init()` | `Sources/AgentCore/AgentContext.swift:21` | `s:9AgentCore0A21RetainedTurnCompactorVACycfc` | KEEP |
| AgentCore | Instance Method | `AgentRetainedTurnCompactor.summarize(droppedConversation:)` | `Sources/AgentCore/AgentContext.swift:23` | `s:9AgentCore0A21RetainedTurnCompactorV9summarize19droppedConversationAA0A17CompactionSummaryVSay0A6Models12ModelMessageOG_tYaKF` | KEEP |
| AgentCore | Structure | `AgentRun` | `Sources/AgentCore/AgentRun.swift:16` | `s:9AgentCore0A3RunV` | KEEP |
| AgentCore | Instance Method | `AgentRun.cancel()` | `Sources/AgentCore/AgentRun.swift:33` | `s:9AgentCore0A3RunV6cancelyyYaF` | KEEP |
| AgentCore | Instance Property | `AgentRun.events` | `Sources/AgentCore/AgentRun.swift:19` | `s:9AgentCore0A3RunV6eventsScSyAA0A5EventOGvp` | KEEP |
| AgentCore | Instance Property | `AgentRun.id` | `Sources/AgentCore/AgentRun.swift:17` | `s:9AgentCore0A3RunV2id10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Property | `AgentRun.sessionID` | `Sources/AgentCore/AgentRun.swift:18` | `s:9AgentCore0A3RunV9sessionID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Method | `AgentRun.steer(_:)` | `Sources/AgentCore/AgentRun.swift:35` | `s:9AgentCore0A3RunV5steery10Foundation4UUIDVSSYaKF` | KEEP |
| AgentCore | Instance Method | `AgentRun.wait()` | `Sources/AgentCore/AgentRun.swift:31` | `s:9AgentCore0A3RunV4waitAA0A10LoopResultVyYaKF` | KEEP |
| AgentCore | Instance Method | `AgentRun.waitForDrain()` | `Sources/AgentCore/AgentRun.swift:32` | `s:9AgentCore0A3RunV12waitForDrainyyYaKF` | KEEP |
| AgentCore | Enumeration | `AgentRunError` | `Sources/AgentCore/AgentRun.swift:38` | `s:9AgentCore0A8RunErrorO` | KEEP |
| AgentCore | Operator | `AgentRunError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A8RunErrorO` | KEEP |
| AgentCore | Case | `AgentRunError.emptySteering` | `Sources/AgentCore/AgentRun.swift:39` | `s:9AgentCore0A8RunErrorO13emptySteeringyA2CmF` | KEEP |
| AgentCore | Case | `AgentRunError.finished` | `Sources/AgentCore/AgentRun.swift:40` | `s:9AgentCore0A8RunErrorO8finishedyA2CmF` | KEEP |
| AgentCore | Instance Property | `AgentRunError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A8RunErrorO` | KEEP |
| AgentCore | Structure | `AgentRunInfo` | `Sources/AgentCore/AgentEvent.swift:7` | `s:9AgentCore0A7RunInfoV` | KEEP |
| AgentCore | Operator | `AgentRunInfo.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A7RunInfoV` | KEEP |
| AgentCore | Initializer | `AgentRunInfo.init(sessionID:runID:model:)` | `Sources/AgentCore/AgentEvent.swift:12` | `s:9AgentCore0A7RunInfoV9sessionID03runF05modelAC10Foundation4UUIDV_AI0A6Models05ModelF0Vtcfc` | KEEP |
| AgentCore | Instance Property | `AgentRunInfo.model` | `Sources/AgentCore/AgentEvent.swift:10` | `s:9AgentCore0A7RunInfoV5model0A6Models7ModelIDVvp` | KEEP |
| AgentCore | Instance Property | `AgentRunInfo.runID` | `Sources/AgentCore/AgentEvent.swift:9` | `s:9AgentCore0A7RunInfoV5runID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Property | `AgentRunInfo.sessionID` | `Sources/AgentCore/AgentEvent.swift:8` | `s:9AgentCore0A7RunInfoV9sessionID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Enumeration | `AgentRunTermination` | `Sources/AgentCore/AgentEvent.swift:41` | `s:9AgentCore0A14RunTerminationO` | KEEP |
| AgentCore | Operator | `AgentRunTermination.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A14RunTerminationO` | KEEP |
| AgentCore | Case | `AgentRunTermination.cancelled` | `Sources/AgentCore/AgentEvent.swift:44` | `s:9AgentCore0A14RunTerminationO9cancelledyA2CmF` | KEEP |
| AgentCore | Case | `AgentRunTermination.failed(_:)` | `Sources/AgentCore/AgentEvent.swift:43` | `s:9AgentCore0A14RunTerminationO6failedyAcA0A7FailureOcACmF` | KEEP |
| AgentCore | Case | `AgentRunTermination.result(_:)` | `Sources/AgentCore/AgentEvent.swift:42` | `s:9AgentCore0A14RunTerminationO6resultyAcA0A10LoopResultVcACmF` | KEEP |
| AgentCore | Class | `AgentSession` | `Sources/AgentCore/AgentSession.swift:12` | `s:9AgentCore0A7SessionC` | KEEP |
| AgentCore | Instance Property | `AgentSession.activeRunID` | `Sources/AgentCore/AgentSession.swift:15` | `s:9AgentCore0A7SessionC11activeRunID10Foundation4UUIDVSgvp` | KEEP |
| AgentCore | Instance Method | `AgentSession.assertIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assertIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:9AgentCore0A7SessionC` | KEEP |
| AgentCore | Instance Method | `AgentSession.assumeIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assumeIsolated_4file4lineqd__qd__xYiKXE_s12StaticStringVSutKs8SendableRd__lF::SYNTHESIZED::s:9AgentCore0A7SessionC` | KEEP |
| AgentCore | Instance Property | `AgentSession.history` | `Sources/AgentCore/AgentSession.swift:14` | `s:9AgentCore0A7SessionC7historySay0A6Models12ModelMessageOGvp` | KEEP |
| AgentCore | Instance Property | `AgentSession.id` | `Sources/AgentCore/AgentSession.swift:13` | `s:9AgentCore0A7SessionC2id10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Method | `AgentSession.preconditionIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE20preconditionIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:9AgentCore0A7SessionC` | KEEP |
| AgentCore | Instance Method | `AgentSession.run(_:budget:operationID:)` | `Sources/AgentCore/AgentSession.swift:51` | `s:9AgentCore0A7SessionC3run_6budget11operationIDAA0A3RunVSS_AA0A6BudgetVSgSSSgtYaKF` | KEEP |
| AgentCore | Instance Method | `AgentSession.waitForRunToDrain(runID:)` | `Sources/AgentCore/AgentSession.swift:89` | `s:9AgentCore0A7SessionC17waitForRunToDrain5runIDy10Foundation4UUIDV_tYaF` | KEEP |
| AgentCore | Instance Method | `AgentSession.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pqd_0_YKXEqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:9AgentCore0A7SessionC` | KEEP |
| AgentCore | Instance Method | `AgentSession.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pYaqd_0_YKYCXEYaqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:9AgentCore0A7SessionC` | KEEP |
| AgentCore | Enumeration | `AgentSessionError` | `Sources/AgentCore/AgentSession.swift:347` | `s:9AgentCore0A12SessionErrorO` | KEEP |
| AgentCore | Operator | `AgentSessionError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A12SessionErrorO` | KEEP |
| AgentCore | Case | `AgentSessionError.durableJournalRequired` | `Sources/AgentCore/AgentSession.swift:350` | `s:9AgentCore0A12SessionErrorO22durableJournalRequiredyA2CmF` | KEEP |
| AgentCore | Case | `AgentSessionError.emptyInput` | `Sources/AgentCore/AgentSession.swift:348` | `s:9AgentCore0A12SessionErrorO10emptyInputyA2CmF` | KEEP |
| AgentCore | Instance Property | `AgentSessionError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:9AgentCore0A12SessionErrorO` | KEEP |
| AgentCore | Case | `AgentSessionError.runInProgress` | `Sources/AgentCore/AgentSession.swift:349` | `s:9AgentCore0A12SessionErrorO13runInProgressyA2CmF` | KEEP |
| AgentCore | Structure | `AgentToolReceipt` | `Sources/AgentCore/AgentEvent.swift:116` | `s:9AgentCore0A11ToolReceiptV` | KEEP |
| AgentCore | Operator | `AgentToolReceipt.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore0A11ToolReceiptV` | KEEP |
| AgentCore | Instance Property | `AgentToolReceipt.callID` | `Sources/AgentCore/AgentEvent.swift:117` | `s:9AgentCore0A11ToolReceiptV6callID0A6Models0c4CallF0Vvp` | KEEP |
| AgentCore | Instance Property | `AgentToolReceipt.effect` | `Sources/AgentCore/AgentEvent.swift:118` | `s:9AgentCore0A11ToolReceiptV6effect0A5Tools0C6PolicyV6EffectOvp` | KEEP |
| AgentCore | Initializer | `AgentToolReceipt.init(callID:effect:receipt:)` | `Sources/AgentCore/AgentEvent.swift:121` | `s:9AgentCore0A11ToolReceiptV6callID6effect7receiptAC0A6Models0c4CallF0V_0A5Tools0C6PolicyV6EffectOAJ0cD0Vtcfc` | KEEP |
| AgentCore | Initializer | `AgentToolReceipt.init(from:)` | `-` | `s:9AgentCore0A11ToolReceiptV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentCore | Instance Property | `AgentToolReceipt.receipt` | `Sources/AgentCore/AgentEvent.swift:119` | `s:9AgentCore0A11ToolReceiptV7receipt0A5Tools0cD0Vvp` | KEEP |
| AgentCore | Structure | `PendingMutationIntent` | `Sources/AgentCore/AgentJournal.swift:96` | `s:9AgentCore21PendingMutationIntentV` | KEEP |
| AgentCore | Operator | `PendingMutationIntent.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore21PendingMutationIntentV` | KEEP |
| AgentCore | Instance Property | `PendingMutationIntent.call` | `Sources/AgentCore/AgentJournal.swift:97` | `s:9AgentCore21PendingMutationIntentV4call0A6Models8ToolCallVvp` | KEEP |
| AgentCore | Instance Property | `PendingMutationIntent.idempotencyKey` | `Sources/AgentCore/AgentJournal.swift:99` | `s:9AgentCore21PendingMutationIntentV14idempotencyKeySSvp` | KEEP |
| AgentCore | Initializer | `PendingMutationIntent.init(call:resources:idempotencyKey:receiptExpectation:)` | `Sources/AgentCore/AgentJournal.swift:102` | `s:9AgentCore21PendingMutationIntentV4call9resources14idempotencyKey18receiptExpectationAC0A6Models8ToolCallV_Say0A5Tools0M8ResourceOGSSAK0m7ReceiptK0VSgtKcfc` | KEEP |
| AgentCore | Initializer | `PendingMutationIntent.init(from:)` | `-` | `s:9AgentCore21PendingMutationIntentV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentCore | Instance Property | `PendingMutationIntent.receiptExpectation` | `Sources/AgentCore/AgentJournal.swift:100` | `s:9AgentCore21PendingMutationIntentV18receiptExpectation0A5Tools011ToolReceiptG0VSgvp` | KEEP |
| AgentCore | Instance Property | `PendingMutationIntent.resources` | `Sources/AgentCore/AgentJournal.swift:98` | `s:9AgentCore21PendingMutationIntentV9resourcesSay0A5Tools12ToolResourceOGvp` | KEEP |
| AgentCore | Structure | `PendingMutationRecovery` | `Sources/AgentCore/AgentJournal.swift:59` | `s:9AgentCore23PendingMutationRecoveryV` | KEEP |
| AgentCore | Operator | `PendingMutationRecovery.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:9AgentCore23PendingMutationRecoveryV` | KEEP |
| AgentCore | Initializer | `PendingMutationRecovery.init(sessionID:runID:intent:state:)` | `Sources/AgentCore/AgentJournal.swift:65` | `s:9AgentCore23PendingMutationRecoveryV9sessionID03runG06intent5stateAC10Foundation4UUIDV_AjA0cD6IntentVAA0aD5StateOtcfc` | KEEP |
| AgentCore | Instance Property | `PendingMutationRecovery.intent` | `Sources/AgentCore/AgentJournal.swift:62` | `s:9AgentCore23PendingMutationRecoveryV6intentAA0cD6IntentVvp` | KEEP |
| AgentCore | Instance Property | `PendingMutationRecovery.runID` | `Sources/AgentCore/AgentJournal.swift:61` | `s:9AgentCore23PendingMutationRecoveryV5runID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Property | `PendingMutationRecovery.sessionID` | `Sources/AgentCore/AgentJournal.swift:60` | `s:9AgentCore23PendingMutationRecoveryV9sessionID10Foundation4UUIDVvp` | KEEP |
| AgentCore | Instance Property | `PendingMutationRecovery.state` | `Sources/AgentCore/AgentJournal.swift:63` | `s:9AgentCore23PendingMutationRecoveryV5stateAA0aD5StateOvp` | KEEP |
| AgentModels | Enumeration | `JSONValue` | `Sources/AgentModels/JSONValue.swift:5` | `s:11AgentModels9JSONValueO` | KEEP |
| AgentModels | Operator | `JSONValue.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels9JSONValueO` | KEEP |
| AgentModels | Case | `JSONValue.array(_:)` | `Sources/AgentModels/JSONValue.swift:10` | `s:11AgentModels9JSONValueO5arrayyACSayACGcACmF` | KEEP |
| AgentModels | Case | `JSONValue.bool(_:)` | `Sources/AgentModels/JSONValue.swift:7` | `s:11AgentModels9JSONValueO4boolyACSbcACmF` | KEEP |
| AgentModels | Instance Method | `JSONValue.encode(to:)` | `Sources/AgentModels/JSONValue.swift:23` | `s:11AgentModels9JSONValueO6encode2toys7Encoder_p_tKF` | KEEP |
| AgentModels | Initializer | `JSONValue.init(from:)` | `Sources/AgentModels/JSONValue.swift:13` | `s:11AgentModels9JSONValueO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Case | `JSONValue.null` | `Sources/AgentModels/JSONValue.swift:6` | `s:11AgentModels9JSONValueO4nullyA2CmF` | KEEP |
| AgentModels | Case | `JSONValue.number(_:)` | `Sources/AgentModels/JSONValue.swift:8` | `s:11AgentModels9JSONValueO6numberyACSo9NSDecimalacACmF` | KEEP |
| AgentModels | Case | `JSONValue.object(_:)` | `Sources/AgentModels/JSONValue.swift:11` | `s:11AgentModels9JSONValueO6objectyACSDySSACGcACmF` | KEEP |
| AgentModels | Case | `JSONValue.string(_:)` | `Sources/AgentModels/JSONValue.swift:9` | `s:11AgentModels9JSONValueO6stringyACSScACmF` | KEEP |
| AgentModels | Structure | `ModelCapabilities` | `Sources/AgentModels/ModelMetadata.swift:1` | `s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Operator | `ModelCapabilities.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.contains(_:)` | `-` | `s:s9OptionSetPs7ElementQzRszrlE8containsySbxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.encode(to:)` | `-` | `s:SYsSERzs6UInt64V8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.formIntersection(_:)` | `-` | `s:s9OptionSetPss17FixedWidthInteger8RawValueRpzrlE16formIntersectionyyxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.formSymmetricDifference(_:)` | `-` | `s:s9OptionSetPss17FixedWidthInteger8RawValueRpzrlE23formSymmetricDifferenceyyxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.formUnion(_:)` | `-` | `s:s9OptionSetPss17FixedWidthInteger8RawValueRpzrlE9formUnionyyxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Property | `ModelCapabilities.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Initializer | `ModelCapabilities.init(_:)` | `-` | `s:s10SetAlgebraPsEyxqd__ncSTRd__7ElementQyd__ACRtzlufc::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Initializer | `ModelCapabilities.init()` | `-` | `s:s9OptionSetPss17FixedWidthInteger8RawValueRpzrlExycfc::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Initializer | `ModelCapabilities.init(arrayLiteral:)` | `-` | `s:s10SetAlgebraPs7ElementQz012ArrayLiteralC0RtzrlE05arrayE0xAFd_tcfc::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Initializer | `ModelCapabilities.init(from:)` | `-` | `s:SYsSeRzs6UInt64V8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Initializer | `ModelCapabilities.init(rawValue:)` | `Sources/AgentModels/ModelMetadata.swift:4` | `s:11AgentModels17ModelCapabilitiesV8rawValueACs6UInt64V_tcfc` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.insert(_:)` | `-` | `s:s9OptionSetPs7ElementQzRszrlE6insertySb8inserted_x17memberAfterInserttxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.insert(_:)` | `-` | `s:s9OptionSetPs7ElementQzRszs17FixedWidthInteger8RawValueRpzrlE6insertySb8inserted_x17memberAfterInserttxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.intersection(_:)` | `-` | `s:s9OptionSetPsE12intersectionyxxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.isDisjoint(with:)` | `-` | `s:s10SetAlgebraPsE10isDisjoint4withSbx_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Property | `ModelCapabilities.isEmpty` | `-` | `s:s10SetAlgebraPsE7isEmptySbvp::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.isStrictSubset(of:)` | `-` | `s:s10SetAlgebraPsE14isStrictSubset2ofSbx_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.isStrictSuperset(of:)` | `-` | `s:s10SetAlgebraPsE16isStrictSuperset2ofSbx_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.isSubset(of:)` | `-` | `s:s10SetAlgebraPsE8isSubset2ofSbx_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.isSuperset(of:)` | `-` | `s:s10SetAlgebraPsE10isSuperset2ofSbx_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Type Property | `ModelCapabilities.multiTurn` | `Sources/AgentModels/ModelMetadata.swift:9` | `s:11AgentModels17ModelCapabilitiesV9multiTurnACvpZ` | KEEP |
| AgentModels | Instance Property | `ModelCapabilities.rawValue` | `Sources/AgentModels/ModelMetadata.swift:2` | `s:11AgentModels17ModelCapabilitiesV8rawValues6UInt64Vvp` | KEEP |
| AgentModels | Type Property | `ModelCapabilities.reasoning` | `Sources/AgentModels/ModelMetadata.swift:12` | `s:11AgentModels17ModelCapabilitiesV9reasoningACvpZ` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.remove(_:)` | `-` | `s:s9OptionSetPs7ElementQzRszrlE6removeyxSgxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Type Property | `ModelCapabilities.streaming` | `Sources/AgentModels/ModelMetadata.swift:8` | `s:11AgentModels17ModelCapabilitiesV9streamingACvpZ` | KEEP |
| AgentModels | Type Property | `ModelCapabilities.structuredOutput` | `Sources/AgentModels/ModelMetadata.swift:11` | `s:11AgentModels17ModelCapabilitiesV16structuredOutputACvpZ` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.subtract(_:)` | `-` | `s:s10SetAlgebraPsE8subtractyyxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.subtracting(_:)` | `-` | `s:s10SetAlgebraPsE11subtractingyxxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.symmetricDifference(_:)` | `-` | `s:s9OptionSetPsE19symmetricDifferenceyxxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Type Property | `ModelCapabilities.tools` | `Sources/AgentModels/ModelMetadata.swift:10` | `s:11AgentModels17ModelCapabilitiesV5toolsACvpZ` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.union(_:)` | `-` | `s:s9OptionSetPsE5unionyxxF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Instance Method | `ModelCapabilities.update(with:)` | `-` | `s:s9OptionSetPs7ElementQzRszrlE6update4withxSgx_tF::SYNTHESIZED::s:11AgentModels17ModelCapabilitiesV` | KEEP |
| AgentModels | Enumeration | `ModelContent` | `Sources/AgentModels/ModelMessage.swift:5` | `s:11AgentModels12ModelContentO` | KEEP |
| AgentModels | Operator | `ModelContent.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels12ModelContentO` | KEEP |
| AgentModels | Initializer | `ModelContent.init(from:)` | `-` | `s:11AgentModels12ModelContentO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Case | `ModelContent.json(_:)` | `Sources/AgentModels/ModelMessage.swift:8` | `s:11AgentModels12ModelContentO4jsonyAcA9JSONValueOcACmF` | KEEP |
| AgentModels | Case | `ModelContent.providerContinuation(_:)` | `Sources/AgentModels/ModelMessage.swift:9` | `s:11AgentModels12ModelContentO20providerContinuationyAcA0c8ProviderF0VcACmF` | KEEP |
| AgentModels | Case | `ModelContent.reasoning(_:)` | `Sources/AgentModels/ModelMessage.swift:7` | `s:11AgentModels12ModelContentO9reasoningyACSScACmF` | KEEP |
| AgentModels | Case | `ModelContent.text(_:)` | `Sources/AgentModels/ModelMessage.swift:6` | `s:11AgentModels12ModelContentO4textyACSScACmF` | KEEP |
| AgentModels | Enumeration | `ModelEvent` | `Sources/AgentModels/ModelEvent.swift:44` | `s:11AgentModels10ModelEventO` | KEEP |
| AgentModels | Operator | `ModelEvent.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels10ModelEventO` | KEEP |
| AgentModels | Initializer | `ModelEvent.init(from:)` | `-` | `s:11AgentModels10ModelEventO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Case | `ModelEvent.providerContinuation(_:)` | `Sources/AgentModels/ModelEvent.swift:48` | `s:11AgentModels10ModelEventO20providerContinuationyAcA0c8ProviderF0VcACmF` | KEEP |
| AgentModels | Case | `ModelEvent.reasoningDelta(_:)` | `Sources/AgentModels/ModelEvent.swift:47` | `s:11AgentModels10ModelEventO14reasoningDeltayACSScACmF` | KEEP |
| AgentModels | Case | `ModelEvent.responseCompleted(_:)` | `Sources/AgentModels/ModelEvent.swift:54` | `s:11AgentModels10ModelEventO17responseCompletedyAcA0C8ResponseVcACmF` | KEEP |
| AgentModels | Case | `ModelEvent.responseStarted(_:)` | `Sources/AgentModels/ModelEvent.swift:45` | `s:11AgentModels10ModelEventO15responseStartedyAcA12ResponseInfoVcACmF` | KEEP |
| AgentModels | Case | `ModelEvent.textDelta(_:)` | `Sources/AgentModels/ModelEvent.swift:46` | `s:11AgentModels10ModelEventO9textDeltayACSScACmF` | KEEP |
| AgentModels | Case | `ModelEvent.toolCallArgumentsDelta(_:_:)` | `Sources/AgentModels/ModelEvent.swift:50` | `s:11AgentModels10ModelEventO22toolCallArgumentsDeltayAcA04ToolF2IDV_SStcACmF` | KEEP |
| AgentModels | Case | `ModelEvent.toolCallCompleted(_:)` | `Sources/AgentModels/ModelEvent.swift:51` | `s:11AgentModels10ModelEventO17toolCallCompletedyAcA04ToolF0VcACmF` | KEEP |
| AgentModels | Case | `ModelEvent.toolCallStarted(_:name:)` | `Sources/AgentModels/ModelEvent.swift:49` | `s:11AgentModels10ModelEventO15toolCallStartedyAcA04ToolF2IDV_SStcACmF` | KEEP |
| AgentModels | Case | `ModelEvent.usage(_:)` | `Sources/AgentModels/ModelEvent.swift:53` | `s:11AgentModels10ModelEventO5usageyAcA0C5UsageVcACmF` | KEEP |
| AgentModels | Structure | `ModelEventAccumulator` | `Sources/AgentModels/ModelEventAccumulator.swift:4` | `s:11AgentModels21ModelEventAccumulatorV` | KEEP |
| AgentModels | Instance Method | `ModelEventAccumulator.append(_:)` | `Sources/AgentModels/ModelEventAccumulator.swift:15` | `s:11AgentModels21ModelEventAccumulatorV6appendyyAA0cD0OKF` | KEEP |
| AgentModels | Instance Method | `ModelEventAccumulator.finish()` | `Sources/AgentModels/ModelEventAccumulator.swift:118` | `s:11AgentModels21ModelEventAccumulatorV6finishAA0C8ResponseVyKF` | KEEP |
| AgentModels | Initializer | `ModelEventAccumulator.init()` | `Sources/AgentModels/ModelEventAccumulator.swift:13` | `s:11AgentModels21ModelEventAccumulatorVACycfc` | KEEP |
| AgentModels | Enumeration | `ModelEventStream` | `Sources/AgentModels/ModelEventStream.swift:2` | `s:11AgentModels16ModelEventStreamO` | KEEP |
| AgentModels | Type Alias | `ModelEventStream.Emit` | `Sources/AgentModels/ModelEventStream.swift:3` | `s:11AgentModels16ModelEventStreamO4Emita` | KEEP |
| AgentModels | Type Method | `ModelEventStream.make(_:)` | `Sources/AgentModels/ModelEventStream.swift:5` | `s:11AgentModels16ModelEventStreamO4makeyScsyAA0cD0Os5Error_pGyyAFYbKcYaYbKcFZ` | KEEP |
| AgentModels | Structure | `ModelID` | `Sources/AgentModels/ModelRequest.swift:3` | `s:11AgentModels7ModelIDV` | KEEP |
| AgentModels | Operator | `ModelID.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels7ModelIDV` | KEEP |
| AgentModels | Operator | `ModelID.==(_:_:)` | `Sources/AgentModels/ModelRequest.swift:13` | `s:11AgentModels7ModelIDV2eeoiySbAC_ACtFZ` | KEEP |
| AgentModels | Instance Method | `ModelID.hash(into:)` | `Sources/AgentModels/ModelRequest.swift:17` | `s:11AgentModels7ModelIDV4hash4intoys6HasherVz_tF` | KEEP |
| AgentModels | Initializer | `ModelID.init(from:)` | `-` | `s:11AgentModels7ModelIDV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelID.init(provider:name:)` | `Sources/AgentModels/ModelRequest.swift:8` | `s:11AgentModels7ModelIDV8provider4nameACSS_SStcfc` | KEEP |
| AgentModels | Instance Property | `ModelID.name` | `Sources/AgentModels/ModelRequest.swift:6` | `s:11AgentModels7ModelIDV4nameSSvp` | KEEP |
| AgentModels | Instance Property | `ModelID.provider` | `Sources/AgentModels/ModelRequest.swift:5` | `s:11AgentModels7ModelIDV8providerSSvp` | KEEP |
| AgentModels | Enumeration | `ModelMessage` | `Sources/AgentModels/ModelMessage.swift:13` | `s:11AgentModels12ModelMessageO` | KEEP |
| AgentModels | Operator | `ModelMessage.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels12ModelMessageO` | KEEP |
| AgentModels | Case | `ModelMessage.assistant(content:toolCalls:)` | `Sources/AgentModels/ModelMessage.swift:17` | `s:11AgentModels12ModelMessageO9assistantyACSayAA0C7ContentOG_SayAA8ToolCallVGtcACmF` | KEEP |
| AgentModels | Case | `ModelMessage.developer(_:)` | `Sources/AgentModels/ModelMessage.swift:15` | `s:11AgentModels12ModelMessageO9developeryACSScACmF` | KEEP |
| AgentModels | Initializer | `ModelMessage.init(from:)` | `-` | `s:11AgentModels12ModelMessageO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Instance Property | `ModelMessage.role` | `Sources/AgentModels/ModelMessage.swift:20` | `s:11AgentModels12ModelMessageO4roleAA0C4RoleOvp` | KEEP |
| AgentModels | Case | `ModelMessage.system(_:)` | `Sources/AgentModels/ModelMessage.swift:14` | `s:11AgentModels12ModelMessageO6systemyACSScACmF` | KEEP |
| AgentModels | Case | `ModelMessage.tool(_:)` | `Sources/AgentModels/ModelMessage.swift:18` | `s:11AgentModels12ModelMessageO4toolyAcA010ToolResultD0VcACmF` | KEEP |
| AgentModels | Case | `ModelMessage.user(_:)` | `Sources/AgentModels/ModelMessage.swift:16` | `s:11AgentModels12ModelMessageO4useryACSayAA0C7ContentOGcACmF` | KEEP |
| AgentModels | Protocol | `ModelProvider` | `Sources/AgentModels/ModelProvider.swift:10` | `s:11AgentModels13ModelProviderP` | KEEP |
| AgentModels | Instance Property | `ModelProvider.descriptor` | `Sources/AgentModels/ModelProvider.swift:11` | `s:11AgentModels13ModelProviderP10descriptorAA0cD10DescriptorVvp` | KEEP |
| AgentModels | Instance Method | `ModelProvider.stream(request:)` | `Sources/AgentModels/ModelProvider.swift:15` | `s:11AgentModels13ModelProviderP6stream7requestScsyAA0C5EventOs5Error_pGAA0C7RequestV_tF` | KEEP |
| AgentModels | Structure | `ModelProviderContinuation` | `Sources/AgentModels/ModelProviderContinuation.swift:4` | `s:11AgentModels25ModelProviderContinuationV` | KEEP |
| AgentModels | Operator | `ModelProviderContinuation.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels25ModelProviderContinuationV` | KEEP |
| AgentModels | Operator | `ModelProviderContinuation.==(_:_:)` | `Sources/AgentModels/ModelProviderContinuation.swift:15` | `s:11AgentModels25ModelProviderContinuationV2eeoiySbAC_ACtFZ` | KEEP |
| AgentModels | Instance Property | `ModelProviderContinuation.format` | `Sources/AgentModels/ModelProviderContinuation.swift:6` | `s:11AgentModels25ModelProviderContinuationV6formatSSvp` | KEEP |
| AgentModels | Instance Method | `ModelProviderContinuation.hash(into:)` | `Sources/AgentModels/ModelProviderContinuation.swift:21` | `s:11AgentModels25ModelProviderContinuationV4hash4intoys6HasherVz_tF` | KEEP |
| AgentModels | Initializer | `ModelProviderContinuation.init(from:)` | `-` | `s:11AgentModels25ModelProviderContinuationV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelProviderContinuation.init(model:format:payload:)` | `Sources/AgentModels/ModelProviderContinuation.swift:9` | `s:11AgentModels25ModelProviderContinuationV5model6format7payloadAcA0C2IDV_SS10Foundation4DataVtcfc` | KEEP |
| AgentModels | Instance Property | `ModelProviderContinuation.model` | `Sources/AgentModels/ModelProviderContinuation.swift:5` | `s:11AgentModels25ModelProviderContinuationV5modelAA0C2IDVvp` | KEEP |
| AgentModels | Instance Property | `ModelProviderContinuation.payload` | `Sources/AgentModels/ModelProviderContinuation.swift:7` | `s:11AgentModels25ModelProviderContinuationV7payload10Foundation4DataVvp` | KEEP |
| AgentModels | Structure | `ModelProviderDescriptor` | `Sources/AgentModels/ModelProvider.swift:32` | `s:11AgentModels23ModelProviderDescriptorV` | KEEP |
| AgentModels | Operator | `ModelProviderDescriptor.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels23ModelProviderDescriptorV` | KEEP |
| AgentModels | Instance Property | `ModelProviderDescriptor.capabilities` | `Sources/AgentModels/ModelProvider.swift:36` | `s:11AgentModels23ModelProviderDescriptorV12capabilitiesAA0C12CapabilitiesVvp` | KEEP |
| AgentModels | Instance Property | `ModelProviderDescriptor.id` | `Sources/AgentModels/ModelProvider.swift:34` | `s:11AgentModels23ModelProviderDescriptorV2idSSvp` | KEEP |
| AgentModels | Initializer | `ModelProviderDescriptor.init(from:)` | `-` | `s:11AgentModels23ModelProviderDescriptorV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelProviderDescriptor.init(id:capabilities:)` | `Sources/AgentModels/ModelProvider.swift:38` | `s:11AgentModels23ModelProviderDescriptorV2id12capabilitiesACSS_AA0C12CapabilitiesVtcfc` | KEEP |
| AgentModels | Structure | `ModelProviderError` | `Sources/AgentModels/ModelProvider.swift:46` | `s:11AgentModels18ModelProviderErrorV` | KEEP |
| AgentModels | Operator | `ModelProviderError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV` | KEEP |
| AgentModels | Initializer | `ModelProviderError.init(kind:message:retryAfter:)` | `Sources/AgentModels/ModelProvider.swift:64` | `s:11AgentModels18ModelProviderErrorV4kind7message10retryAfterA2C4KindO_SSs8DurationVSgtcfc` | KEEP |
| AgentModels | Instance Property | `ModelProviderError.kind` | `Sources/AgentModels/ModelProvider.swift:59` | `s:11AgentModels18ModelProviderErrorV4kindAC4KindOvp` | KEEP |
| AgentModels | Enumeration | `ModelProviderError.Kind` | `Sources/AgentModels/ModelProvider.swift:47` | `s:11AgentModels18ModelProviderErrorV4KindO` | KEEP |
| AgentModels | Operator | `ModelProviderError.Kind.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV4KindO` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.authentication` | `Sources/AgentModels/ModelProvider.swift:48` | `s:11AgentModels18ModelProviderErrorV4KindO14authenticationyA2EmF` | KEEP |
| AgentModels | Instance Method | `ModelProviderError.Kind.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV4KindO` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.fallbackBlocked` | `Sources/AgentModels/ModelProvider.swift:56` | `s:11AgentModels18ModelProviderErrorV4KindO15fallbackBlockedyA2EmF` | KEEP |
| AgentModels | Instance Method | `ModelProviderError.Kind.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV4KindO` | KEEP |
| AgentModels | Instance Property | `ModelProviderError.Kind.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV4KindO` | KEEP |
| AgentModels | Initializer | `ModelProviderError.Kind.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV4KindO` | KEEP |
| AgentModels | Initializer | `ModelProviderError.Kind.init(rawValue:)` | `-` | `s:11AgentModels18ModelProviderErrorV4KindO8rawValueAESgSS_tcfc` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.invalidRequest` | `Sources/AgentModels/ModelProvider.swift:50` | `s:11AgentModels18ModelProviderErrorV4KindO14invalidRequestyA2EmF` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.invalidResponse` | `Sources/AgentModels/ModelProvider.swift:55` | `s:11AgentModels18ModelProviderErrorV4KindO15invalidResponseyA2EmF` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.permissionDenied` | `Sources/AgentModels/ModelProvider.swift:49` | `s:11AgentModels18ModelProviderErrorV4KindO16permissionDeniedyA2EmF` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.rateLimited` | `Sources/AgentModels/ModelProvider.swift:52` | `s:11AgentModels18ModelProviderErrorV4KindO11rateLimitedyA2EmF` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.transport` | `Sources/AgentModels/ModelProvider.swift:54` | `s:11AgentModels18ModelProviderErrorV4KindO9transportyA2EmF` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.unavailable` | `Sources/AgentModels/ModelProvider.swift:53` | `s:11AgentModels18ModelProviderErrorV4KindO11unavailableyA2EmF` | KEEP |
| AgentModels | Case | `ModelProviderError.Kind.unsupportedCapability` | `Sources/AgentModels/ModelProvider.swift:51` | `s:11AgentModels18ModelProviderErrorV4KindO21unsupportedCapabilityyA2EmF` | KEEP |
| AgentModels | Instance Property | `ModelProviderError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:11AgentModels18ModelProviderErrorV` | KEEP |
| AgentModels | Instance Property | `ModelProviderError.message` | `Sources/AgentModels/ModelProvider.swift:61` | `s:11AgentModels18ModelProviderErrorV7messageSSvp` | KEEP |
| AgentModels | Instance Property | `ModelProviderError.retryAfter` | `Sources/AgentModels/ModelProvider.swift:62` | `s:11AgentModels18ModelProviderErrorV10retryAfters8DurationVSgvp` | KEEP |
| AgentModels | Protocol | `ModelProviderMutationBoundary` | `Sources/AgentModels/ModelProvider.swift:27` | `s:11AgentModels29ModelProviderMutationBoundaryP` | KEEP |
| AgentModels | Instance Method | `ModelProviderMutationBoundary.clearMutationBoundary(sessionID:runID:)` | `Sources/AgentModels/ModelProvider.swift:29` | `s:11AgentModels29ModelProviderMutationBoundaryP05cleareF09sessionID03runI0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentModels | Instance Method | `ModelProviderMutationBoundary.markMutationBoundary(sessionID:runID:)` | `Sources/AgentModels/ModelProvider.swift:28` | `s:11AgentModels29ModelProviderMutationBoundaryP04markeF09sessionID03runI0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentModels | Protocol | `ModelProviderRunDrain` | `Sources/AgentModels/ModelProvider.swift:22` | `s:11AgentModels21ModelProviderRunDrainP` | KEEP |
| AgentModels | Instance Method | `ModelProviderRunDrain.waitForRunToDrain(sessionID:runID:)` | `Sources/AgentModels/ModelProvider.swift:23` | `s:11AgentModels21ModelProviderRunDrainP07waitFore2ToF09sessionID03runK0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentModels | Structure | `ModelRequest` | `Sources/AgentModels/ModelRequest.swift:54` | `s:11AgentModels12ModelRequestV` | KEEP |
| AgentModels | Operator | `ModelRequest.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels12ModelRequestV` | KEEP |
| AgentModels | Initializer | `ModelRequest.init(from:)` | `-` | `s:11AgentModels12ModelRequestV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelRequest.init(model:messages:tools:structuredOutput:sessionID:runID:)` | `Sources/AgentModels/ModelRequest.swift:63` | `s:11AgentModels12ModelRequestV5model8messages5tools16structuredOutput9sessionID03runK0AcA0cK0V_SayAA0C7MessageOGSayAA0C14ToolDefinitionVGAA010StructuredI6SchemaVSg10Foundation4UUIDVSgAXtcfc` | KEEP |
| AgentModels | Instance Property | `ModelRequest.messages` | `Sources/AgentModels/ModelRequest.swift:56` | `s:11AgentModels12ModelRequestV8messagesSayAA0C7MessageOGvp` | KEEP |
| AgentModels | Instance Property | `ModelRequest.model` | `Sources/AgentModels/ModelRequest.swift:55` | `s:11AgentModels12ModelRequestV5modelAA0C2IDVvp` | KEEP |
| AgentModels | Instance Property | `ModelRequest.runID` | `Sources/AgentModels/ModelRequest.swift:61` | `s:11AgentModels12ModelRequestV5runID10Foundation4UUIDVSgvp` | KEEP |
| AgentModels | Instance Property | `ModelRequest.sessionID` | `Sources/AgentModels/ModelRequest.swift:60` | `s:11AgentModels12ModelRequestV9sessionID10Foundation4UUIDVSgvp` | KEEP |
| AgentModels | Instance Property | `ModelRequest.structuredOutput` | `Sources/AgentModels/ModelRequest.swift:58` | `s:11AgentModels12ModelRequestV16structuredOutputAA010StructuredF6SchemaVSgvp` | KEEP |
| AgentModels | Instance Property | `ModelRequest.tools` | `Sources/AgentModels/ModelRequest.swift:57` | `s:11AgentModels12ModelRequestV5toolsSayAA0C14ToolDefinitionVGvp` | KEEP |
| AgentModels | Structure | `ModelResponse` | `Sources/AgentModels/ModelEvent.swift:20` | `s:11AgentModels13ModelResponseV` | KEEP |
| AgentModels | Operator | `ModelResponse.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels13ModelResponseV` | KEEP |
| AgentModels | Instance Property | `ModelResponse.content` | `Sources/AgentModels/ModelEvent.swift:22` | `s:11AgentModels13ModelResponseV7contentSayAA0C7ContentOGvp` | KEEP |
| AgentModels | Instance Property | `ModelResponse.info` | `Sources/AgentModels/ModelEvent.swift:21` | `s:11AgentModels13ModelResponseV4infoAA0D4InfoVvp` | KEEP |
| AgentModels | Initializer | `ModelResponse.init(from:)` | `-` | `s:11AgentModels13ModelResponseV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelResponse.init(info:content:toolCalls:usage:stopReason:)` | `Sources/AgentModels/ModelEvent.swift:27` | `s:11AgentModels13ModelResponseV4info7content9toolCalls5usage10stopReasonAcA0D4InfoV_SayAA0C7ContentOGSayAA8ToolCallVGAA0C5UsageVAA04StopK0Otcfc` | KEEP |
| AgentModels | Instance Property | `ModelResponse.stopReason` | `Sources/AgentModels/ModelEvent.swift:25` | `s:11AgentModels13ModelResponseV10stopReasonAA04StopF0Ovp` | KEEP |
| AgentModels | Instance Property | `ModelResponse.toolCalls` | `Sources/AgentModels/ModelEvent.swift:23` | `s:11AgentModels13ModelResponseV9toolCallsSayAA8ToolCallVGvp` | KEEP |
| AgentModels | Instance Property | `ModelResponse.usage` | `Sources/AgentModels/ModelEvent.swift:24` | `s:11AgentModels13ModelResponseV5usageAA0C5UsageVvp` | KEEP |
| AgentModels | Enumeration | `ModelRole` | `Sources/AgentModels/ModelMessage.swift:1` | `s:11AgentModels9ModelRoleO` | KEEP |
| AgentModels | Operator | `ModelRole.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels9ModelRoleO` | KEEP |
| AgentModels | Case | `ModelRole.assistant` | `Sources/AgentModels/ModelMessage.swift:2` | `s:11AgentModels9ModelRoleO9assistantyA2CmF` | KEEP |
| AgentModels | Case | `ModelRole.developer` | `Sources/AgentModels/ModelMessage.swift:2` | `s:11AgentModels9ModelRoleO9developeryA2CmF` | KEEP |
| AgentModels | Instance Method | `ModelRole.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:11AgentModels9ModelRoleO` | KEEP |
| AgentModels | Instance Method | `ModelRole.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:11AgentModels9ModelRoleO` | KEEP |
| AgentModels | Instance Property | `ModelRole.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:11AgentModels9ModelRoleO` | KEEP |
| AgentModels | Initializer | `ModelRole.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:11AgentModels9ModelRoleO` | KEEP |
| AgentModels | Initializer | `ModelRole.init(rawValue:)` | `-` | `s:11AgentModels9ModelRoleO8rawValueACSgSS_tcfc` | KEEP |
| AgentModels | Case | `ModelRole.system` | `Sources/AgentModels/ModelMessage.swift:2` | `s:11AgentModels9ModelRoleO6systemyA2CmF` | KEEP |
| AgentModels | Case | `ModelRole.tool` | `Sources/AgentModels/ModelMessage.swift:2` | `s:11AgentModels9ModelRoleO4toolyA2CmF` | KEEP |
| AgentModels | Case | `ModelRole.user` | `Sources/AgentModels/ModelMessage.swift:2` | `s:11AgentModels9ModelRoleO4useryA2CmF` | KEEP |
| AgentModels | Enumeration | `ModelStreamError` | `Sources/AgentModels/ModelEventAccumulator.swift:129` | `s:11AgentModels16ModelStreamErrorO` | KEEP |
| AgentModels | Operator | `ModelStreamError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels16ModelStreamErrorO` | KEEP |
| AgentModels | Case | `ModelStreamError.duplicateStart` | `Sources/AgentModels/ModelEventAccumulator.swift:132` | `s:11AgentModels16ModelStreamErrorO14duplicateStartyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.duplicateToolCall(_:)` | `Sources/AgentModels/ModelEventAccumulator.swift:138` | `s:11AgentModels16ModelStreamErrorO17duplicateToolCallyAcA0gH2IDVcACmF` | KEEP |
| AgentModels | Case | `ModelStreamError.eventAfterTerminal` | `Sources/AgentModels/ModelEventAccumulator.swift:133` | `s:11AgentModels16ModelStreamErrorO18eventAfterTerminalyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.invalidContinuation` | `Sources/AgentModels/ModelEventAccumulator.swift:136` | `s:11AgentModels16ModelStreamErrorO19invalidContinuationyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.invalidToolArguments(_:)` | `Sources/AgentModels/ModelEventAccumulator.swift:141` | `s:11AgentModels16ModelStreamErrorO20invalidToolArgumentsyAcA0G6CallIDVcACmF` | KEEP |
| AgentModels | Case | `ModelStreamError.invalidToolIdentity` | `Sources/AgentModels/ModelEventAccumulator.swift:142` | `s:11AgentModels16ModelStreamErrorO19invalidToolIdentityyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.invalidToolStop` | `Sources/AgentModels/ModelEventAccumulator.swift:143` | `s:11AgentModels16ModelStreamErrorO15invalidToolStopyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.invalidUsage` | `Sources/AgentModels/ModelEventAccumulator.swift:135` | `s:11AgentModels16ModelStreamErrorO12invalidUsageyA2CmF` | KEEP |
| AgentModels | Instance Property | `ModelStreamError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:11AgentModels16ModelStreamErrorO` | KEEP |
| AgentModels | Case | `ModelStreamError.missingStart` | `Sources/AgentModels/ModelEventAccumulator.swift:131` | `s:11AgentModels16ModelStreamErrorO12missingStartyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.missingTerminal` | `Sources/AgentModels/ModelEventAccumulator.swift:130` | `s:11AgentModels16ModelStreamErrorO15missingTerminalyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.responseMismatch` | `Sources/AgentModels/ModelEventAccumulator.swift:134` | `s:11AgentModels16ModelStreamErrorO16responseMismatchyA2CmF` | KEEP |
| AgentModels | Case | `ModelStreamError.toolAlreadyCompleted(_:)` | `Sources/AgentModels/ModelEventAccumulator.swift:139` | `s:11AgentModels16ModelStreamErrorO20toolAlreadyCompletedyAcA10ToolCallIDVcACmF` | KEEP |
| AgentModels | Case | `ModelStreamError.toolCallMismatch(_:)` | `Sources/AgentModels/ModelEventAccumulator.swift:140` | `s:11AgentModels16ModelStreamErrorO16toolCallMismatchyAcA04ToolG2IDVcACmF` | KEEP |
| AgentModels | Case | `ModelStreamError.unknownToolCall(_:)` | `Sources/AgentModels/ModelEventAccumulator.swift:137` | `s:11AgentModels16ModelStreamErrorO15unknownToolCallyAcA0gH2IDVcACmF` | KEEP |
| AgentModels | Structure | `ModelToolDefinition` | `Sources/AgentModels/ModelRequest.swift:24` | `s:11AgentModels19ModelToolDefinitionV` | KEEP |
| AgentModels | Operator | `ModelToolDefinition.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels19ModelToolDefinitionV` | KEEP |
| AgentModels | Instance Property | `ModelToolDefinition.description` | `Sources/AgentModels/ModelRequest.swift:26` | `s:11AgentModels19ModelToolDefinitionV11descriptionSSvp` | KEEP |
| AgentModels | Initializer | `ModelToolDefinition.init(from:)` | `-` | `s:11AgentModels19ModelToolDefinitionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelToolDefinition.init(name:description:inputSchema:outputSchema:)` | `Sources/AgentModels/ModelRequest.swift:30` | `s:11AgentModels19ModelToolDefinitionV4name11description11inputSchema06outputI0ACSS_SSAA9JSONValueOAISgtcfc` | KEEP |
| AgentModels | Instance Property | `ModelToolDefinition.inputSchema` | `Sources/AgentModels/ModelRequest.swift:27` | `s:11AgentModels19ModelToolDefinitionV11inputSchemaAA9JSONValueOvp` | KEEP |
| AgentModels | Instance Property | `ModelToolDefinition.name` | `Sources/AgentModels/ModelRequest.swift:25` | `s:11AgentModels19ModelToolDefinitionV4nameSSvp` | KEEP |
| AgentModels | Instance Property | `ModelToolDefinition.outputSchema` | `Sources/AgentModels/ModelRequest.swift:28` | `s:11AgentModels19ModelToolDefinitionV12outputSchemaAA9JSONValueOSgvp` | KEEP |
| AgentModels | Structure | `ModelUsage` | `Sources/AgentModels/ModelMetadata.swift:18` | `s:11AgentModels10ModelUsageV` | KEEP |
| AgentModels | Operator | `ModelUsage.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels10ModelUsageV` | KEEP |
| AgentModels | Instance Property | `ModelUsage.cachedInputTokens` | `Sources/AgentModels/ModelMetadata.swift:21` | `s:11AgentModels10ModelUsageV17cachedInputTokensSiSgvp` | KEEP |
| AgentModels | Instance Property | `ModelUsage.cacheWriteInputTokens` | `Sources/AgentModels/ModelMetadata.swift:22` | `s:11AgentModels10ModelUsageV21cacheWriteInputTokensSiSgvp` | KEEP |
| AgentModels | Initializer | `ModelUsage.init(from:)` | `-` | `s:11AgentModels10ModelUsageV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ModelUsage.init(inputTokens:outputTokens:cachedInputTokens:cacheWriteInputTokens:reasoningTokens:)` | `Sources/AgentModels/ModelMetadata.swift:25` | `s:11AgentModels10ModelUsageV11inputTokens06outputF0011cachedInputF0010cacheWriteiF009reasoningF0ACSiSg_A4Itcfc` | KEEP |
| AgentModels | Instance Property | `ModelUsage.inputTokens` | `Sources/AgentModels/ModelMetadata.swift:19` | `s:11AgentModels10ModelUsageV11inputTokensSiSgvp` | KEEP |
| AgentModels | Instance Property | `ModelUsage.outputTokens` | `Sources/AgentModels/ModelMetadata.swift:20` | `s:11AgentModels10ModelUsageV12outputTokensSiSgvp` | KEEP |
| AgentModels | Instance Property | `ModelUsage.reasoningTokens` | `Sources/AgentModels/ModelMetadata.swift:23` | `s:11AgentModels10ModelUsageV15reasoningTokensSiSgvp` | KEEP |
| AgentModels | Structure | `ResponseInfo` | `Sources/AgentModels/ModelEvent.swift:1` | `s:11AgentModels12ResponseInfoV` | KEEP |
| AgentModels | Operator | `ResponseInfo.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels12ResponseInfoV` | KEEP |
| AgentModels | Operator | `ResponseInfo.==(_:_:)` | `Sources/AgentModels/ModelEvent.swift:10` | `s:11AgentModels12ResponseInfoV2eeoiySbAC_ACtFZ` | KEEP |
| AgentModels | Instance Method | `ResponseInfo.hash(into:)` | `Sources/AgentModels/ModelEvent.swift:14` | `s:11AgentModels12ResponseInfoV4hash4intoys6HasherVz_tF` | KEEP |
| AgentModels | Instance Property | `ResponseInfo.id` | `Sources/AgentModels/ModelEvent.swift:2` | `s:11AgentModels12ResponseInfoV2idSSvp` | KEEP |
| AgentModels | Initializer | `ResponseInfo.init(from:)` | `-` | `s:11AgentModels12ResponseInfoV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ResponseInfo.init(id:model:)` | `Sources/AgentModels/ModelEvent.swift:5` | `s:11AgentModels12ResponseInfoV2id5modelACSS_AA7ModelIDVtcfc` | KEEP |
| AgentModels | Instance Property | `ResponseInfo.model` | `Sources/AgentModels/ModelEvent.swift:3` | `s:11AgentModels12ResponseInfoV5modelAA7ModelIDVvp` | KEEP |
| AgentModels | Enumeration | `StopReason` | `Sources/AgentModels/ModelMetadata.swift:41` | `s:11AgentModels10StopReasonO` | KEEP |
| AgentModels | Operator | `StopReason.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels10StopReasonO` | KEEP |
| AgentModels | Case | `StopReason.cancelled` | `Sources/AgentModels/ModelMetadata.swift:47` | `s:11AgentModels10StopReasonO9cancelledyA2CmF` | KEEP |
| AgentModels | Case | `StopReason.endTurn` | `Sources/AgentModels/ModelMetadata.swift:42` | `s:11AgentModels10StopReasonO7endTurnyA2CmF` | KEEP |
| AgentModels | Initializer | `StopReason.init(from:)` | `-` | `s:11AgentModels10StopReasonO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Case | `StopReason.maxOutputTokens` | `Sources/AgentModels/ModelMetadata.swift:44` | `s:11AgentModels10StopReasonO15maxOutputTokensyA2CmF` | KEEP |
| AgentModels | Case | `StopReason.refusal` | `Sources/AgentModels/ModelMetadata.swift:46` | `s:11AgentModels10StopReasonO7refusalyA2CmF` | KEEP |
| AgentModels | Case | `StopReason.stopSequence` | `Sources/AgentModels/ModelMetadata.swift:45` | `s:11AgentModels10StopReasonO12stopSequenceyA2CmF` | KEEP |
| AgentModels | Case | `StopReason.toolCalls` | `Sources/AgentModels/ModelMetadata.swift:43` | `s:11AgentModels10StopReasonO9toolCallsyA2CmF` | KEEP |
| AgentModels | Case | `StopReason.unknown(_:)` | `Sources/AgentModels/ModelMetadata.swift:48` | `s:11AgentModels10StopReasonO7unknownyACSScACmF` | KEEP |
| AgentModels | Structure | `StructuredOutputSchema` | `Sources/AgentModels/ModelRequest.swift:39` | `s:11AgentModels22StructuredOutputSchemaV` | KEEP |
| AgentModels | Operator | `StructuredOutputSchema.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels22StructuredOutputSchemaV` | KEEP |
| AgentModels | Instance Property | `StructuredOutputSchema.description` | `Sources/AgentModels/ModelRequest.swift:41` | `s:11AgentModels22StructuredOutputSchemaV11descriptionSSSgvp` | KEEP |
| AgentModels | Initializer | `StructuredOutputSchema.init(from:)` | `-` | `s:11AgentModels22StructuredOutputSchemaV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `StructuredOutputSchema.init(name:description:schema:strict:)` | `Sources/AgentModels/ModelRequest.swift:45` | `s:11AgentModels22StructuredOutputSchemaV4name11description6schema6strictACSS_SSSgAA9JSONValueOSbtcfc` | KEEP |
| AgentModels | Instance Property | `StructuredOutputSchema.name` | `Sources/AgentModels/ModelRequest.swift:40` | `s:11AgentModels22StructuredOutputSchemaV4nameSSvp` | KEEP |
| AgentModels | Instance Property | `StructuredOutputSchema.schema` | `Sources/AgentModels/ModelRequest.swift:42` | `s:11AgentModels22StructuredOutputSchemaV6schemaAA9JSONValueOvp` | KEEP |
| AgentModels | Instance Property | `StructuredOutputSchema.strict` | `Sources/AgentModels/ModelRequest.swift:43` | `s:11AgentModels22StructuredOutputSchemaV6strictSbvp` | KEEP |
| AgentModels | Structure | `ToolCall` | `Sources/AgentModels/ModelMessage.swift:47` | `s:11AgentModels8ToolCallV` | KEEP |
| AgentModels | Operator | `ToolCall.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels8ToolCallV` | KEEP |
| AgentModels | Operator | `ToolCall.==(_:_:)` | `Sources/AgentModels/ModelMessage.swift:71` | `s:11AgentModels8ToolCallV2eeoiySbAC_ACtFZ` | KEEP |
| AgentModels | Instance Property | `ToolCall.argumentsJSON` | `Sources/AgentModels/ModelMessage.swift:56` | `s:11AgentModels8ToolCallV13argumentsJSONSSvp` | KEEP |
| AgentModels | Instance Property | `ToolCall.completeness` | `Sources/AgentModels/ModelMessage.swift:57` | `s:11AgentModels8ToolCallV12completenessAC12CompletenessOvp` | KEEP |
| AgentModels | Enumeration | `ToolCall.Completeness` | `Sources/AgentModels/ModelMessage.swift:49` | `s:11AgentModels8ToolCallV12CompletenessO` | KEEP |
| AgentModels | Operator | `ToolCall.Completeness.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels8ToolCallV12CompletenessO` | KEEP |
| AgentModels | Case | `ToolCall.Completeness.complete` | `Sources/AgentModels/ModelMessage.swift:50` | `s:11AgentModels8ToolCallV12CompletenessO8completeyA2EmF` | KEEP |
| AgentModels | Instance Method | `ToolCall.Completeness.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:11AgentModels8ToolCallV12CompletenessO` | KEEP |
| AgentModels | Instance Method | `ToolCall.Completeness.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:11AgentModels8ToolCallV12CompletenessO` | KEEP |
| AgentModels | Instance Property | `ToolCall.Completeness.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:11AgentModels8ToolCallV12CompletenessO` | KEEP |
| AgentModels | Case | `ToolCall.Completeness.incomplete` | `Sources/AgentModels/ModelMessage.swift:50` | `s:11AgentModels8ToolCallV12CompletenessO10incompleteyA2EmF` | KEEP |
| AgentModels | Initializer | `ToolCall.Completeness.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:11AgentModels8ToolCallV12CompletenessO` | KEEP |
| AgentModels | Initializer | `ToolCall.Completeness.init(rawValue:)` | `-` | `s:11AgentModels8ToolCallV12CompletenessO8rawValueAESgSS_tcfc` | KEEP |
| AgentModels | Instance Method | `ToolCall.hash(into:)` | `Sources/AgentModels/ModelMessage.swift:77` | `s:11AgentModels8ToolCallV4hash4intoys6HasherVz_tF` | KEEP |
| AgentModels | Instance Property | `ToolCall.id` | `Sources/AgentModels/ModelMessage.swift:53` | `s:11AgentModels8ToolCallV2idAA0cD2IDVvp` | KEEP |
| AgentModels | Initializer | `ToolCall.init(from:)` | `-` | `s:11AgentModels8ToolCallV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Initializer | `ToolCall.init(id:name:argumentsJSON:completeness:)` | `Sources/AgentModels/ModelMessage.swift:59` | `s:11AgentModels8ToolCallV2id4name13argumentsJSON12completenessAcA0cD2IDV_S2SAC12CompletenessOtcfc` | KEEP |
| AgentModels | Instance Property | `ToolCall.name` | `Sources/AgentModels/ModelMessage.swift:54` | `s:11AgentModels8ToolCallV4nameSSvp` | KEEP |
| AgentModels | Structure | `ToolCallID` | `Sources/AgentModels/ModelMessage.swift:31` | `s:11AgentModels10ToolCallIDV` | KEEP |
| AgentModels | Operator | `ToolCallID.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels10ToolCallIDV` | KEEP |
| AgentModels | Operator | `ToolCallID.==(_:_:)` | `Sources/AgentModels/ModelMessage.swift:38` | `s:11AgentModels10ToolCallIDV2eeoiySbAC_ACtFZ` | KEEP |
| AgentModels | Instance Method | `ToolCallID.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:11AgentModels10ToolCallIDV` | KEEP |
| AgentModels | Instance Method | `ToolCallID.hash(into:)` | `Sources/AgentModels/ModelMessage.swift:42` | `s:11AgentModels10ToolCallIDV4hash4intoys6HasherVz_tF` | KEEP |
| AgentModels | Instance Property | `ToolCallID.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:11AgentModels10ToolCallIDV` | KEEP |
| AgentModels | Initializer | `ToolCallID.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:11AgentModels10ToolCallIDV` | KEEP |
| AgentModels | Initializer | `ToolCallID.init(rawValue:)` | `Sources/AgentModels/ModelMessage.swift:34` | `s:11AgentModels10ToolCallIDV8rawValueACSS_tcfc` | KEEP |
| AgentModels | Instance Property | `ToolCallID.rawValue` | `Sources/AgentModels/ModelMessage.swift:32` | `s:11AgentModels10ToolCallIDV8rawValueSSvp` | KEEP |
| AgentModels | Structure | `ToolResultMessage` | `Sources/AgentModels/ModelMessage.swift:86` | `s:11AgentModels17ToolResultMessageV` | KEEP |
| AgentModels | Operator | `ToolResultMessage.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:11AgentModels17ToolResultMessageV` | KEEP |
| AgentModels | Instance Property | `ToolResultMessage.callID` | `Sources/AgentModels/ModelMessage.swift:87` | `s:11AgentModels17ToolResultMessageV6callIDAA0c4CallG0Vvp` | KEEP |
| AgentModels | Instance Property | `ToolResultMessage.content` | `Sources/AgentModels/ModelMessage.swift:88` | `s:11AgentModels17ToolResultMessageV7contentSayAA12ModelContentOGvp` | KEEP |
| AgentModels | Initializer | `ToolResultMessage.init(callID:content:isError:)` | `Sources/AgentModels/ModelMessage.swift:91` | `s:11AgentModels17ToolResultMessageV6callID7content7isErrorAcA0c4CallG0V_SayAA12ModelContentOGSbtcfc` | KEEP |
| AgentModels | Initializer | `ToolResultMessage.init(from:)` | `-` | `s:11AgentModels17ToolResultMessageV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentModels | Instance Property | `ToolResultMessage.isError` | `Sources/AgentModels/ModelMessage.swift:89` | `s:11AgentModels17ToolResultMessageV7isErrorSbvp` | KEEP |
| AgentProviders | Structure | `AnthropicProvider` | `Sources/AgentProviders/AnthropicProvider.swift:13` | `s:14AgentProviders17AnthropicProviderV` | KEEP |
| AgentProviders | Instance Property | `AnthropicProvider.customMirror` | `Sources/AgentProviders/AnthropicProvider.swift:27` | `s:14AgentProviders17AnthropicProviderV12customMirrors0F0Vvp` | KEEP |
| AgentProviders | Instance Property | `AnthropicProvider.debugDescription` | `Sources/AgentProviders/AnthropicProvider.swift:26` | `s:14AgentProviders17AnthropicProviderV16debugDescriptionSSvp` | KEEP |
| AgentProviders | Instance Property | `AnthropicProvider.description` | `Sources/AgentProviders/AnthropicProvider.swift:25` | `s:14AgentProviders17AnthropicProviderV11descriptionSSvp` | KEEP |
| AgentProviders | Instance Property | `AnthropicProvider.descriptor` | `Sources/AgentProviders/AnthropicProvider.swift:14` | `s:14AgentProviders17AnthropicProviderV10descriptor0A6Models05ModelD10DescriptorVvp` | KEEP |
| AgentProviders | Initializer | `AnthropicProvider.init(apiKey:endpoint:maximumOutputTokens:thinking:resolvedModelIDsByAlias:transport:)` | `Sources/AgentProviders/AnthropicProvider.swift:42` | `s:14AgentProviders17AnthropicProviderV6apiKey8endpoint19maximumOutputTokens8thinking23resolvedModelIDsByAlias9transportACSS_10Foundation3URLVSgSiAA0C8ThinkingOSDyS2SGAA0D13HTTPTransport_ptKcfc` | KEEP |
| AgentProviders | Initializer | `AnthropicProvider.init(apiKey:endpoint:maximumOutputTokens:thinking:transport:)` | `Sources/AgentProviders/AnthropicProvider.swift:29` | `s:14AgentProviders17AnthropicProviderV6apiKey8endpoint19maximumOutputTokens8thinking9transportACSS_10Foundation3URLVSgSiAA0C8ThinkingOAA0D13HTTPTransport_ptKcfc` | KEEP |
| AgentProviders | Instance Method | `AnthropicProvider.stream(request:)` | `Sources/AgentProviders/AnthropicProvider.swift:74` | `s:14AgentProviders17AnthropicProviderV6stream7requestScsy0A6Models10ModelEventOs5Error_pGAF0H7RequestV_tF` | KEEP |
| AgentProviders | Enumeration | `AnthropicThinking` | `Sources/AgentProviders/AnthropicProvider.swift:7` | `s:14AgentProviders17AnthropicThinkingO` | KEEP |
| AgentProviders | Operator | `AnthropicThinking.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentProviders17AnthropicThinkingO` | KEEP |
| AgentProviders | Case | `AnthropicThinking.adaptive` | `Sources/AgentProviders/AnthropicProvider.swift:9` | `s:14AgentProviders17AnthropicThinkingO8adaptiveyA2CmF` | KEEP |
| AgentProviders | Case | `AnthropicThinking.disabled` | `Sources/AgentProviders/AnthropicProvider.swift:8` | `s:14AgentProviders17AnthropicThinkingO8disabledyA2CmF` | KEEP |
| AgentProviders | Case | `AnthropicThinking.enabled(budgetTokens:)` | `Sources/AgentProviders/AnthropicProvider.swift:10` | `s:14AgentProviders17AnthropicThinkingO7enabledyACSi_tcACmF` | KEEP |
| AgentProviders | Enumeration | `DeepSeekReasoningEffort` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:8` | `s:14AgentProviders23DeepSeekReasoningEffortO` | KEEP |
| AgentProviders | Operator | `DeepSeekReasoningEffort.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentProviders23DeepSeekReasoningEffortO` | KEEP |
| AgentProviders | Instance Method | `DeepSeekReasoningEffort.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:14AgentProviders23DeepSeekReasoningEffortO` | KEEP |
| AgentProviders | Instance Method | `DeepSeekReasoningEffort.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:14AgentProviders23DeepSeekReasoningEffortO` | KEEP |
| AgentProviders | Instance Property | `DeepSeekReasoningEffort.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:14AgentProviders23DeepSeekReasoningEffortO` | KEEP |
| AgentProviders | Case | `DeepSeekReasoningEffort.high` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:11` | `s:14AgentProviders23DeepSeekReasoningEffortO4highyA2CmF` | KEEP |
| AgentProviders | Initializer | `DeepSeekReasoningEffort.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:14AgentProviders23DeepSeekReasoningEffortO` | KEEP |
| AgentProviders | Initializer | `DeepSeekReasoningEffort.init(rawValue:)` | `-` | `s:14AgentProviders23DeepSeekReasoningEffortO8rawValueACSgSS_tcfc` | KEEP |
| AgentProviders | Case | `DeepSeekReasoningEffort.low` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:10` | `s:14AgentProviders23DeepSeekReasoningEffortO3lowyA2CmF` | KEEP |
| AgentProviders | Case | `DeepSeekReasoningEffort.max` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:12` | `s:14AgentProviders23DeepSeekReasoningEffortO3maxyA2CmF` | KEEP |
| AgentProviders | Case | `DeepSeekReasoningEffort.none` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:9` | `s:14AgentProviders23DeepSeekReasoningEffortO4noneyA2CmF` | KEEP |
| AgentProviders | Structure | `DeepSeekResponsesProvider` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:17` | `s:14AgentProviders25DeepSeekResponsesProviderV` | KEEP |
| AgentProviders | Instance Property | `DeepSeekResponsesProvider.customMirror` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:32` | `s:14AgentProviders25DeepSeekResponsesProviderV12customMirrors0H0Vvp` | KEEP |
| AgentProviders | Instance Property | `DeepSeekResponsesProvider.debugDescription` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:31` | `s:14AgentProviders25DeepSeekResponsesProviderV16debugDescriptionSSvp` | KEEP |
| AgentProviders | Instance Property | `DeepSeekResponsesProvider.description` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:30` | `s:14AgentProviders25DeepSeekResponsesProviderV11descriptionSSvp` | KEEP |
| AgentProviders | Instance Property | `DeepSeekResponsesProvider.descriptor` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:19` | `s:14AgentProviders25DeepSeekResponsesProviderV10descriptor0A6Models05ModelF10DescriptorVvp` | KEEP |
| AgentProviders | Initializer | `DeepSeekResponsesProvider.init(apiKey:endpoint:maximumOutputTokens:reasoningEffort:resolvedModelIDsByAlias:transport:)` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:34` | `s:14AgentProviders25DeepSeekResponsesProviderV6apiKey8endpoint19maximumOutputTokens15reasoningEffort23resolvedModelIDsByAlias9transportACSS_10Foundation3URLVSgSiAA0cd9ReasoningN0OSDyS2SGAA0F13HTTPTransport_ptKcfc` | KEEP |
| AgentProviders | Instance Method | `DeepSeekResponsesProvider.stream(request:)` | `Sources/AgentProviders/DeepSeekResponsesProvider.swift:68` | `s:14AgentProviders25DeepSeekResponsesProviderV6stream7requestScsy0A6Models10ModelEventOs5Error_pGAF0J7RequestV_tF` | KEEP |
| AgentProviders | Structure | `ModelProviderFallbackPolicy` | `Sources/AgentProviders/ModelProviderRoute.swift:5` | `s:14AgentProviders27ModelProviderFallbackPolicyV` | KEEP |
| AgentProviders | Operator | `ModelProviderFallbackPolicy.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentProviders27ModelProviderFallbackPolicyV` | KEEP |
| AgentProviders | Initializer | `ModelProviderFallbackPolicy.init(from:)` | `-` | `s:14AgentProviders27ModelProviderFallbackPolicyV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentProviders | Initializer | `ModelProviderFallbackPolicy.init(maxAttempts:maxRetriesPerProvider:retryableKinds:)` | `Sources/AgentProviders/ModelProviderRoute.swift:10` | `s:14AgentProviders27ModelProviderFallbackPolicyV11maxAttempts0g10RetriesPerD014retryableKindsACSi_SiShy0A6Models0cD5ErrorV4KindOGtKcfc` | KEEP |
| AgentProviders | Instance Property | `ModelProviderFallbackPolicy.maxAttempts` | `Sources/AgentProviders/ModelProviderRoute.swift:6` | `s:14AgentProviders27ModelProviderFallbackPolicyV11maxAttemptsSivp` | KEEP |
| AgentProviders | Instance Property | `ModelProviderFallbackPolicy.maxRetriesPerProvider` | `Sources/AgentProviders/ModelProviderRoute.swift:7` | `s:14AgentProviders27ModelProviderFallbackPolicyV013maxRetriesPerD0Sivp` | KEEP |
| AgentProviders | Instance Property | `ModelProviderFallbackPolicy.retryableKinds` | `Sources/AgentProviders/ModelProviderRoute.swift:8` | `s:14AgentProviders27ModelProviderFallbackPolicyV14retryableKindsShy0A6Models0cD5ErrorV4KindOGvp` | KEEP |
| AgentProviders | Enumeration | `ModelProviderFallbackPolicyError` | `Sources/AgentProviders/ModelProviderRoute.swift:27` | `s:14AgentProviders32ModelProviderFallbackPolicyErrorO` | KEEP |
| AgentProviders | Operator | `ModelProviderFallbackPolicyError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentProviders32ModelProviderFallbackPolicyErrorO` | KEEP |
| AgentProviders | Case | `ModelProviderFallbackPolicyError.candidateProviderIDMismatch(routeID:candidateID:)` | `Sources/AgentProviders/ModelProviderRoute.swift:31` | `s:14AgentProviders32ModelProviderFallbackPolicyErrorO09candidateD10IDMismatchyACSS_SStcACmF` | KEEP |
| AgentProviders | Case | `ModelProviderFallbackPolicyError.emptyCandidates` | `Sources/AgentProviders/ModelProviderRoute.swift:30` | `s:14AgentProviders32ModelProviderFallbackPolicyErrorO15emptyCandidatesyA2CmF` | KEEP |
| AgentProviders | Case | `ModelProviderFallbackPolicyError.invalidLimits` | `Sources/AgentProviders/ModelProviderRoute.swift:28` | `s:14AgentProviders32ModelProviderFallbackPolicyErrorO13invalidLimitsyA2CmF` | KEEP |
| AgentProviders | Case | `ModelProviderFallbackPolicyError.invalidRetryableKinds` | `Sources/AgentProviders/ModelProviderRoute.swift:29` | `s:14AgentProviders32ModelProviderFallbackPolicyErrorO21invalidRetryableKindsyA2CmF` | KEEP |
| AgentProviders | Instance Property | `ModelProviderFallbackPolicyError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:14AgentProviders32ModelProviderFallbackPolicyErrorO` | KEEP |
| AgentProviders | Structure | `ModelProviderRoute` | `Sources/AgentProviders/ModelProviderRoute.swift:36` | `s:14AgentProviders18ModelProviderRouteV` | KEEP |
| AgentProviders | Instance Method | `ModelProviderRoute.clearMutationBoundary(sessionID:runID:)` | `Sources/AgentProviders/ModelProviderRoute.swift:81` | `s:14AgentProviders18ModelProviderRouteV21clearMutationBoundary9sessionID03runJ0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentProviders | Instance Property | `ModelProviderRoute.descriptor` | `Sources/AgentProviders/ModelProviderRoute.swift:37` | `s:14AgentProviders18ModelProviderRouteV10descriptor0A6Models0cD10DescriptorVvp` | KEEP |
| AgentProviders | Initializer | `ModelProviderRoute.init(id:candidates:policy:)` | `Sources/AgentProviders/ModelProviderRoute.swift:42` | `s:14AgentProviders18ModelProviderRouteV2id10candidates6policyACSS_Say0A6Models0cD0_pGAA0cD14FallbackPolicyVtKcfc` | KEEP |
| AgentProviders | Instance Method | `ModelProviderRoute.markMutationBoundary(sessionID:runID:)` | `Sources/AgentProviders/ModelProviderRoute.swift:73` | `s:14AgentProviders18ModelProviderRouteV20markMutationBoundary9sessionID03runJ0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentProviders | Instance Method | `ModelProviderRoute.stream(request:)` | `Sources/AgentProviders/ModelProviderRoute.swift:67` | `s:14AgentProviders18ModelProviderRouteV6stream7requestScsy0A6Models0C5EventOs5Error_pGAF0C7RequestV_tF` | KEEP |
| AgentProviders | Instance Method | `ModelProviderRoute.waitForRunToDrain(sessionID:runID:)` | `Sources/AgentProviders/ModelProviderRoute.swift:89` | `s:14AgentProviders18ModelProviderRouteV17waitForRunToDrain9sessionID03runL0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentProviders | Structure | `OpenAIReasoningEffort` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:8` | `s:14AgentProviders21OpenAIReasoningEffortV` | KEEP |
| AgentProviders | Operator | `OpenAIReasoningEffort.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentProviders21OpenAIReasoningEffortV` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.disabled` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:12` | `s:14AgentProviders21OpenAIReasoningEffortV8disabledACvpZ` | KEEP |
| AgentProviders | Instance Method | `OpenAIReasoningEffort.encode(to:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:24` | `s:14AgentProviders21OpenAIReasoningEffortV6encode2toys7Encoder_p_tKF` | KEEP |
| AgentProviders | Instance Method | `OpenAIReasoningEffort.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:14AgentProviders21OpenAIReasoningEffortV` | KEEP |
| AgentProviders | Instance Property | `OpenAIReasoningEffort.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:14AgentProviders21OpenAIReasoningEffortV` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.high` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:16` | `s:14AgentProviders21OpenAIReasoningEffortV4highACvpZ` | KEEP |
| AgentProviders | Initializer | `OpenAIReasoningEffort.init(from:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:20` | `s:14AgentProviders21OpenAIReasoningEffortV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentProviders | Initializer | `OpenAIReasoningEffort.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:14AgentProviders21OpenAIReasoningEffortV` | KEEP |
| AgentProviders | Initializer | `OpenAIReasoningEffort.init(rawValue:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:10` | `s:14AgentProviders21OpenAIReasoningEffortV8rawValueACSS_tcfc` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.low` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:14` | `s:14AgentProviders21OpenAIReasoningEffortV3lowACvpZ` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.max` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:18` | `s:14AgentProviders21OpenAIReasoningEffortV3maxACvpZ` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.medium` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:15` | `s:14AgentProviders21OpenAIReasoningEffortV6mediumACvpZ` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.minimal` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:13` | `s:14AgentProviders21OpenAIReasoningEffortV7minimalACvpZ` | KEEP |
| AgentProviders | Instance Property | `OpenAIReasoningEffort.rawValue` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:9` | `s:14AgentProviders21OpenAIReasoningEffortV8rawValueSSvp` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningEffort.xhigh` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:17` | `s:14AgentProviders21OpenAIReasoningEffortV5xhighACvpZ` | KEEP |
| AgentProviders | Structure | `OpenAIReasoningSummary` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:31` | `s:14AgentProviders22OpenAIReasoningSummaryV` | KEEP |
| AgentProviders | Operator | `OpenAIReasoningSummary.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentProviders22OpenAIReasoningSummaryV` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningSummary.auto` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:35` | `s:14AgentProviders22OpenAIReasoningSummaryV4autoACvpZ` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningSummary.concise` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:36` | `s:14AgentProviders22OpenAIReasoningSummaryV7conciseACvpZ` | KEEP |
| AgentProviders | Type Property | `OpenAIReasoningSummary.detailed` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:37` | `s:14AgentProviders22OpenAIReasoningSummaryV8detailedACvpZ` | KEEP |
| AgentProviders | Instance Method | `OpenAIReasoningSummary.encode(to:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:43` | `s:14AgentProviders22OpenAIReasoningSummaryV6encode2toys7Encoder_p_tKF` | KEEP |
| AgentProviders | Instance Method | `OpenAIReasoningSummary.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:14AgentProviders22OpenAIReasoningSummaryV` | KEEP |
| AgentProviders | Instance Property | `OpenAIReasoningSummary.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:14AgentProviders22OpenAIReasoningSummaryV` | KEEP |
| AgentProviders | Initializer | `OpenAIReasoningSummary.init(from:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:39` | `s:14AgentProviders22OpenAIReasoningSummaryV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentProviders | Initializer | `OpenAIReasoningSummary.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:14AgentProviders22OpenAIReasoningSummaryV` | KEEP |
| AgentProviders | Initializer | `OpenAIReasoningSummary.init(rawValue:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:33` | `s:14AgentProviders22OpenAIReasoningSummaryV8rawValueACSS_tcfc` | KEEP |
| AgentProviders | Instance Property | `OpenAIReasoningSummary.rawValue` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:32` | `s:14AgentProviders22OpenAIReasoningSummaryV8rawValueSSvp` | KEEP |
| AgentProviders | Structure | `OpenAIResponsesProvider` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:51` | `s:14AgentProviders23OpenAIResponsesProviderV` | KEEP |
| AgentProviders | Instance Property | `OpenAIResponsesProvider.customMirror` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:68` | `s:14AgentProviders23OpenAIResponsesProviderV12customMirrors0G0Vvp` | KEEP |
| AgentProviders | Instance Property | `OpenAIResponsesProvider.debugDescription` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:67` | `s:14AgentProviders23OpenAIResponsesProviderV16debugDescriptionSSvp` | KEEP |
| AgentProviders | Instance Property | `OpenAIResponsesProvider.description` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:66` | `s:14AgentProviders23OpenAIResponsesProviderV11descriptionSSvp` | KEEP |
| AgentProviders | Instance Property | `OpenAIResponsesProvider.descriptor` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:52` | `s:14AgentProviders23OpenAIResponsesProviderV10descriptor0A6Models05ModelE10DescriptorVvp` | KEEP |
| AgentProviders | Initializer | `OpenAIResponsesProvider.init(apiKey:endpoint:maximumOutputTokens:reasoningEffort:reasoningSummary:resolvedModelIDsByAlias:transport:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:83` | `s:14AgentProviders23OpenAIResponsesProviderV6apiKey8endpoint19maximumOutputTokens15reasoningEffort0L7Summary23resolvedModelIDsByAlias9transportACSS_10Foundation3URLVSgSiAA0c11AIReasoningM0VSgAA0cwN0VSgSDyS2SGAA0E13HTTPTransport_ptKcfc` | KEEP |
| AgentProviders | Initializer | `OpenAIResponsesProvider.init(apiKey:endpoint:maximumOutputTokens:reasoningEffort:reasoningSummary:transport:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:70` | `s:14AgentProviders23OpenAIResponsesProviderV6apiKey8endpoint19maximumOutputTokens15reasoningEffort0L7Summary9transportACSS_10Foundation3URLVSgSiAA0c11AIReasoningM0VSgAA0crN0VSgAA0E13HTTPTransport_ptKcfc` | KEEP |
| AgentProviders | Instance Method | `OpenAIResponsesProvider.stream(request:)` | `Sources/AgentProviders/OpenAIResponsesProvider.swift:124` | `s:14AgentProviders23OpenAIResponsesProviderV6stream7requestScsy0A6Models10ModelEventOs5Error_pGAF0I7RequestV_tF` | KEEP |
| AgentProviders | Enumeration | `ProviderHTTPEvent` | `Sources/AgentProviders/ProviderHTTPTransport.swift:7` | `s:14AgentProviders17ProviderHTTPEventO` | KEEP |
| AgentProviders | Case | `ProviderHTTPEvent.data(_:)` | `Sources/AgentProviders/ProviderHTTPTransport.swift:9` | `s:14AgentProviders17ProviderHTTPEventO4datayAC10Foundation4DataVcACmF` | KEEP |
| AgentProviders | Case | `ProviderHTTPEvent.response(status:headers:)` | `Sources/AgentProviders/ProviderHTTPTransport.swift:8` | `s:14AgentProviders17ProviderHTTPEventO8responseyACSi_SDyS2SGtcACmF` | KEEP |
| AgentProviders | Protocol | `ProviderHTTPTransport` | `Sources/AgentProviders/ProviderHTTPTransport.swift:12` | `s:14AgentProviders21ProviderHTTPTransportP` | KEEP |
| AgentProviders | Instance Method | `ProviderHTTPTransport.stream(_:)` | `Sources/AgentProviders/ProviderHTTPTransport.swift:13` | `s:14AgentProviders21ProviderHTTPTransportP6streamyScsyAA0C9HTTPEventOs5Error_pG10Foundation10URLRequestVF` | KEEP |
| AgentProviders | Structure | `URLSessionProviderHTTPTransport` | `Sources/AgentProviders/ProviderHTTPTransport.swift:16` | `s:14AgentProviders31URLSessionProviderHTTPTransportV` | KEEP |
| AgentProviders | Initializer | `URLSessionProviderHTTPTransport.init()` | `Sources/AgentProviders/ProviderHTTPTransport.swift:19` | `s:14AgentProviders31URLSessionProviderHTTPTransportVACycfc` | KEEP |
| AgentProviders | Instance Method | `URLSessionProviderHTTPTransport.stream(_:)` | `Sources/AgentProviders/ProviderHTTPTransport.swift:25` | `s:14AgentProviders31URLSessionProviderHTTPTransportV6streamyScsyAA0D9HTTPEventOs5Error_pG10Foundation10URLRequestVF` | KEEP |
| AgentTools | Protocol | `AgentTool` | `Sources/AgentTools/AgentTool.swift:7` | `s:10AgentTools0A4ToolP` | KEEP |
| AgentTools | Instance Method | `AgentTool.authorize(_:context:)` | `Sources/AgentTools/AgentTool.swift:20` | `s:10AgentTools0A4ToolP9authorize_7contextAA0C13AuthorizationO5InputQz_AA0C7ContextVtYaKF` | KEEP |
| AgentTools | Instance Method | `AgentTool.authorize(_:context:)` | `Sources/AgentTools/AgentTool.swift:103` | `s:10AgentTools0A4ToolPAAE9authorize_7contextAA0C13AuthorizationO5InputQz_AA0C7ContextVtYaKF` | KEEP |
| AgentTools | Type Property | `AgentTool.description` | `Sources/AgentTools/AgentTool.swift:12` | `s:10AgentTools0A4ToolP11descriptionSSvpZ` | KEEP |
| AgentTools | Instance Method | `AgentTool.evidenceRequirements(for:)` | `Sources/AgentTools/AgentTool.swift:17` | `s:10AgentTools0A4ToolP20evidenceRequirements3forSayAA19EvidenceRequirementVG5InputQz_tKF` | KEEP |
| AgentTools | Instance Method | `AgentTool.evidenceRequirements(for:)` | `Sources/AgentTools/AgentTool.swift:100` | `s:10AgentTools0A4ToolPAAE20evidenceRequirements3forSayAA19EvidenceRequirementVG5InputQz_tKF` | KEEP |
| AgentTools | Instance Method | `AgentTool.execute(_:context:)` | `Sources/AgentTools/AgentTool.swift:21` | `s:10AgentTools0A4ToolP7execute_7contextAA0C6ResultVy6OutputQzG5InputQz_AA0C7ContextVtYaKF` | KEEP |
| AgentTools | Associated Type | `AgentTool.Input` | `Sources/AgentTools/AgentTool.swift:8` | `s:10AgentTools0A4ToolP5InputQa` | KEEP |
| AgentTools | Type Property | `AgentTool.inputSchema` | `Sources/AgentTools/AgentTool.swift:13` | `s:10AgentTools0A4ToolP11inputSchemaAA0cE0VvpZ` | KEEP |
| AgentTools | Type Property | `AgentTool.name` | `Sources/AgentTools/AgentTool.swift:11` | `s:10AgentTools0A4ToolP4nameSSvpZ` | KEEP |
| AgentTools | Associated Type | `AgentTool.Output` | `Sources/AgentTools/AgentTool.swift:9` | `s:10AgentTools0A4ToolP6OutputQa` | KEEP |
| AgentTools | Type Property | `AgentTool.outputSchema` | `Sources/AgentTools/AgentTool.swift:14` | `s:10AgentTools0A4ToolP12outputSchemaAA0cE0VvpZ` | KEEP |
| AgentTools | Instance Property | `AgentTool.policy` | `Sources/AgentTools/AgentTool.swift:15` | `s:10AgentTools0A4ToolP6policyAA0C6PolicyVvp` | KEEP |
| AgentTools | Instance Method | `AgentTool.receiptExpectation(for:)` | `Sources/AgentTools/AgentTool.swift:19` | `s:10AgentTools0A4ToolP18receiptExpectation3forAA0c7ReceiptE0VSg5InputQz_tKF` | KEEP |
| AgentTools | Instance Method | `AgentTool.receiptExpectation(for:)` | `Sources/AgentTools/AgentTool.swift:102` | `s:10AgentTools0A4ToolPAAE18receiptExpectation3forAA0c7ReceiptE0VSg5InputQz_tKF` | KEEP |
| AgentTools | Instance Method | `AgentTool.resourceRequirements(for:)` | `Sources/AgentTools/AgentTool.swift:18` | `s:10AgentTools0A4ToolP20resourceRequirements3forSayAA0C8ResourceOG5InputQz_tKF` | KEEP |
| AgentTools | Instance Method | `AgentTool.resourceRequirements(for:)` | `Sources/AgentTools/AgentTool.swift:101` | `s:10AgentTools0A4ToolPAAE20resourceRequirements3forSayAA0C8ResourceOG5InputQz_tKF` | KEEP |
| AgentTools | Structure | `Evidence` | `Sources/AgentTools/Evidence.swift:31` | `s:10AgentTools8EvidenceV` | KEEP |
| AgentTools | Operator | `Evidence.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools8EvidenceV` | KEEP |
| AgentTools | Operator | `Evidence.==(_:_:)` | `Sources/AgentTools/Evidence.swift:47` | `s:10AgentTools8EvidenceV2eeoiySbAC_ACtFZ` | KEEP |
| AgentTools | Instance Property | `Evidence.expiresAt` | `Sources/AgentTools/Evidence.swift:35` | `s:10AgentTools8EvidenceV9expiresAt10Foundation4DateVSgvp` | KEEP |
| AgentTools | Instance Method | `Evidence.hash(into:)` | `Sources/AgentTools/Evidence.swift:52` | `s:10AgentTools8EvidenceV4hash4intoys6HasherVz_tF` | KEEP |
| AgentTools | Instance Property | `Evidence.id` | `Sources/AgentTools/Evidence.swift:33` | `s:10AgentTools8EvidenceV2idSSvp` | KEEP |
| AgentTools | Initializer | `Evidence.init(from:)` | `-` | `s:10AgentTools8EvidenceV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Initializer | `Evidence.init(namespace:id:issuedAt:expiresAt:metadata:)` | `Sources/AgentTools/Evidence.swift:39` | `s:10AgentTools8EvidenceV9namespace2id8issuedAt07expiresG08metadataACSS_SS10Foundation4DateVAKSgSDySS0A6Models9JSONValueOGtcfc` | KEEP |
| AgentTools | Instance Property | `Evidence.issuedAt` | `Sources/AgentTools/Evidence.swift:34` | `s:10AgentTools8EvidenceV8issuedAt10Foundation4DateVvp` | KEEP |
| AgentTools | Instance Property | `Evidence.metadata` | `Sources/AgentTools/Evidence.swift:36` | `s:10AgentTools8EvidenceV8metadataSDySS0A6Models9JSONValueOGvp` | KEEP |
| AgentTools | Instance Property | `Evidence.namespace` | `Sources/AgentTools/Evidence.swift:32` | `s:10AgentTools8EvidenceV9namespaceSSvp` | KEEP |
| AgentTools | Instance Property | `Evidence.reference` | `Sources/AgentTools/Evidence.swift:37` | `s:10AgentTools8EvidenceV9referenceAA0C9ReferenceVvp` | KEEP |
| AgentTools | Enumeration | `EvidenceError` | `Sources/AgentTools/EvidenceLedger.swift:82` | `s:10AgentTools13EvidenceErrorO` | KEEP |
| AgentTools | Operator | `EvidenceError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools13EvidenceErrorO` | KEEP |
| AgentTools | Case | `EvidenceError.deadlineExceeded` | `Sources/AgentTools/EvidenceLedger.swift:90` | `s:10AgentTools13EvidenceErrorO16deadlineExceededyA2CmF` | KEEP |
| AgentTools | Case | `EvidenceError.duplicateEvidence(_:)` | `Sources/AgentTools/EvidenceLedger.swift:85` | `s:10AgentTools13EvidenceErrorO09duplicateC0yAcA0C9ReferenceVcACmF` | KEEP |
| AgentTools | Case | `EvidenceError.emptyRequirements` | `Sources/AgentTools/EvidenceLedger.swift:88` | `s:10AgentTools13EvidenceErrorO17emptyRequirementsyA2CmF` | KEEP |
| AgentTools | Case | `EvidenceError.invalidClock` | `Sources/AgentTools/EvidenceLedger.swift:89` | `s:10AgentTools13EvidenceErrorO12invalidClockyA2CmF` | KEEP |
| AgentTools | Case | `EvidenceError.invalidEvidence(_:)` | `Sources/AgentTools/EvidenceLedger.swift:84` | `s:10AgentTools13EvidenceErrorO07invalidC0yAcA0C9ReferenceVcACmF` | KEEP |
| AgentTools | Case | `EvidenceError.invalidRequirement(_:)` | `Sources/AgentTools/EvidenceLedger.swift:87` | `s:10AgentTools13EvidenceErrorO18invalidRequirementyAcA0C9ReferenceVcACmF` | KEEP |
| AgentTools | Instance Property | `EvidenceError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools13EvidenceErrorO` | KEEP |
| AgentTools | Case | `EvidenceError.staleEvidence(_:)` | `Sources/AgentTools/EvidenceLedger.swift:86` | `s:10AgentTools13EvidenceErrorO05staleC0yAcA0C9ReferenceVcACmF` | KEEP |
| AgentTools | Case | `EvidenceError.unavailable(_:)` | `Sources/AgentTools/EvidenceLedger.swift:83` | `s:10AgentTools13EvidenceErrorO11unavailableyAcA0C9ReferenceVcACmF` | KEEP |
| AgentTools | Class | `EvidenceLedger` | `Sources/AgentTools/EvidenceLedger.swift:5` | `s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Operator | `EvidenceLedger.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Operator | `EvidenceLedger.==(_:_:)` | `Sources/AgentTools/EvidenceLedger.swift:6` | `s:10AgentTools14EvidenceLedgerC2eeoiySbAC_ACtFZ` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.assertIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assertIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.assumeIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assumeIsolated_4file4lineqd__qd__xYiKXE_s12StaticStringVSutKs8SendableRd__lF::SYNTHESIZED::s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Initializer | `EvidenceLedger.init(now:)` | `Sources/AgentTools/EvidenceLedger.swift:12` | `s:10AgentTools14EvidenceLedgerC3nowAC10Foundation4DateVyYbc_tcfc` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.preconditionIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE20preconditionIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.record(_:sessionID:runID:deadline:)` | `Sources/AgentTools/EvidenceLedger.swift:14` | `s:10AgentTools14EvidenceLedgerC6record_9sessionID03runG08deadlineySayAA0C0VG_10Foundation4UUIDVAM12_Concurrency15ContinuousClockV7InstantVSgtKF` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.resolve(_:sessionID:runID:deadline:)` | `Sources/AgentTools/EvidenceLedger.swift:39` | `s:10AgentTools14EvidenceLedgerC7resolve_9sessionID03runG08deadlineSayAA0C0VGSayAA0C11RequirementVG_10Foundation4UUIDVAP12_Concurrency15ContinuousClockV7InstantVSgtKF` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.validate(_:sessionID:runID:deadline:)` | `Sources/AgentTools/EvidenceLedger.swift:34` | `s:10AgentTools14EvidenceLedgerC8validate_9sessionID03runG08deadlineySayAA0C11RequirementVG_10Foundation4UUIDVAM12_Concurrency15ContinuousClockV7InstantVSgtKF` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pqd_0_YKXEqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Instance Method | `EvidenceLedger.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pYaqd_0_YKYCXEYaqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:10AgentTools14EvidenceLedgerC` | KEEP |
| AgentTools | Structure | `EvidenceReference` | `Sources/AgentTools/Evidence.swift:4` | `s:10AgentTools17EvidenceReferenceV` | KEEP |
| AgentTools | Operator | `EvidenceReference.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools17EvidenceReferenceV` | KEEP |
| AgentTools | Operator | `EvidenceReference.==(_:_:)` | `Sources/AgentTools/Evidence.swift:13` | `s:10AgentTools17EvidenceReferenceV2eeoiySbAC_ACtFZ` | KEEP |
| AgentTools | Instance Method | `EvidenceReference.hash(into:)` | `Sources/AgentTools/Evidence.swift:17` | `s:10AgentTools17EvidenceReferenceV4hash4intoys6HasherVz_tF` | KEEP |
| AgentTools | Instance Property | `EvidenceReference.id` | `Sources/AgentTools/Evidence.swift:6` | `s:10AgentTools17EvidenceReferenceV2idSSvp` | KEEP |
| AgentTools | Initializer | `EvidenceReference.init(from:)` | `-` | `s:10AgentTools17EvidenceReferenceV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Initializer | `EvidenceReference.init(namespace:id:)` | `Sources/AgentTools/Evidence.swift:8` | `s:10AgentTools17EvidenceReferenceV9namespace2idACSS_SStcfc` | KEEP |
| AgentTools | Instance Property | `EvidenceReference.namespace` | `Sources/AgentTools/Evidence.swift:5` | `s:10AgentTools17EvidenceReferenceV9namespaceSSvp` | KEEP |
| AgentTools | Structure | `EvidenceRequirement` | `Sources/AgentTools/Evidence.swift:62` | `s:10AgentTools19EvidenceRequirementV` | KEEP |
| AgentTools | Operator | `EvidenceRequirement.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools19EvidenceRequirementV` | KEEP |
| AgentTools | Operator | `EvidenceRequirement.==(_:_:)` | `Sources/AgentTools/Evidence.swift:73` | `s:10AgentTools19EvidenceRequirementV2eeoiySbAC_ACtFZ` | KEEP |
| AgentTools | Instance Method | `EvidenceRequirement.hash(into:)` | `Sources/AgentTools/Evidence.swift:78` | `s:10AgentTools19EvidenceRequirementV4hash4intoys6HasherVz_tF` | KEEP |
| AgentTools | Initializer | `EvidenceRequirement.init(reference:scope:metadata:)` | `Sources/AgentTools/Evidence.swift:67` | `s:10AgentTools19EvidenceRequirementV9reference5scope8metadataAcA0C9ReferenceV_AA0C5ScopeOSDySS0A6Models9JSONValueOGtcfc` | KEEP |
| AgentTools | Instance Property | `EvidenceRequirement.metadata` | `Sources/AgentTools/Evidence.swift:65` | `s:10AgentTools19EvidenceRequirementV8metadataSDySS0A6Models9JSONValueOGvp` | KEEP |
| AgentTools | Instance Property | `EvidenceRequirement.reference` | `Sources/AgentTools/Evidence.swift:63` | `s:10AgentTools19EvidenceRequirementV9referenceAA0C9ReferenceVvp` | KEEP |
| AgentTools | Instance Property | `EvidenceRequirement.scope` | `Sources/AgentTools/Evidence.swift:64` | `s:10AgentTools19EvidenceRequirementV5scopeAA0C5ScopeOvp` | KEEP |
| AgentTools | Enumeration | `EvidenceScope` | `Sources/AgentTools/Evidence.swift:60` | `s:10AgentTools13EvidenceScopeO` | KEEP |
| AgentTools | Operator | `EvidenceScope.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools13EvidenceScopeO` | KEEP |
| AgentTools | Instance Method | `EvidenceScope.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools13EvidenceScopeO` | KEEP |
| AgentTools | Instance Method | `EvidenceScope.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools13EvidenceScopeO` | KEEP |
| AgentTools | Instance Property | `EvidenceScope.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools13EvidenceScopeO` | KEEP |
| AgentTools | Initializer | `EvidenceScope.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools13EvidenceScopeO` | KEEP |
| AgentTools | Initializer | `EvidenceScope.init(rawValue:)` | `-` | `s:10AgentTools13EvidenceScopeO8rawValueACSgSS_tcfc` | KEEP |
| AgentTools | Case | `EvidenceScope.sameRun` | `Sources/AgentTools/Evidence.swift:60` | `s:10AgentTools13EvidenceScopeO7sameRunyA2CmF` | KEEP |
| AgentTools | Case | `EvidenceScope.sameSession` | `Sources/AgentTools/Evidence.swift:60` | `s:10AgentTools13EvidenceScopeO11sameSessionyA2CmF` | KEEP |
| AgentTools | Structure | `RecoverableToolError` | `Sources/AgentTools/AgentTool.swift:70` | `s:10AgentTools20RecoverableToolErrorV` | KEEP |
| AgentTools | Operator | `RecoverableToolError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools20RecoverableToolErrorV` | KEEP |
| AgentTools | Instance Property | `RecoverableToolError.code` | `Sources/AgentTools/AgentTool.swift:71` | `s:10AgentTools20RecoverableToolErrorV4codeSSvp` | KEEP |
| AgentTools | Instance Property | `RecoverableToolError.details` | `Sources/AgentTools/AgentTool.swift:73` | `s:10AgentTools20RecoverableToolErrorV7details0A6Models9JSONValueOSgvp` | KEEP |
| AgentTools | Initializer | `RecoverableToolError.init(code:message:details:)` | `Sources/AgentTools/AgentTool.swift:75` | `s:10AgentTools20RecoverableToolErrorV4code7message7detailsACSS_SS0A6Models9JSONValueOSgtKcfc` | KEEP |
| AgentTools | Instance Property | `RecoverableToolError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools20RecoverableToolErrorV` | KEEP |
| AgentTools | Instance Property | `RecoverableToolError.message` | `Sources/AgentTools/AgentTool.swift:72` | `s:10AgentTools20RecoverableToolErrorV7messageSSvp` | KEEP |
| AgentTools | Enumeration | `RecoverableToolErrorValidationError` | `Sources/AgentTools/AgentTool.swift:94` | `s:10AgentTools030RecoverableToolErrorValidationE0O` | KEEP |
| AgentTools | Operator | `RecoverableToolErrorValidationError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools030RecoverableToolErrorValidationE0O` | KEEP |
| AgentTools | Case | `RecoverableToolErrorValidationError.emptyCode` | `Sources/AgentTools/AgentTool.swift:95` | `s:10AgentTools030RecoverableToolErrorValidationE0O9emptyCodeyA2CmF` | KEEP |
| AgentTools | Case | `RecoverableToolErrorValidationError.emptyMessage` | `Sources/AgentTools/AgentTool.swift:96` | `s:10AgentTools030RecoverableToolErrorValidationE0O12emptyMessageyA2CmF` | KEEP |
| AgentTools | Instance Property | `RecoverableToolErrorValidationError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools030RecoverableToolErrorValidationE0O` | KEEP |
| AgentTools | Enumeration | `ToolAuthorization` | `Sources/AgentTools/AgentTool.swift:66` | `s:10AgentTools17ToolAuthorizationO` | KEEP |
| AgentTools | Operator | `ToolAuthorization.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools17ToolAuthorizationO` | KEEP |
| AgentTools | Case | `ToolAuthorization.allowed` | `Sources/AgentTools/AgentTool.swift:66` | `s:10AgentTools17ToolAuthorizationO7allowedyA2CmF` | KEEP |
| AgentTools | Case | `ToolAuthorization.denied` | `Sources/AgentTools/AgentTool.swift:66` | `s:10AgentTools17ToolAuthorizationO6deniedyA2CmF` | KEEP |
| AgentTools | Structure | `ToolContext` | `Sources/AgentTools/ToolContext.swift:4` | `s:10AgentTools11ToolContextV` | KEEP |
| AgentTools | Operator | `ToolContext.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools11ToolContextV` | KEEP |
| AgentTools | Operator | `ToolContext.==(_:_:)` | `Sources/AgentTools/ToolContext.swift:54` | `s:10AgentTools11ToolContextV2eeoiySbAC_ACtFZ` | KEEP |
| AgentTools | Instance Property | `ToolContext.argumentsJSON` | `Sources/AgentTools/ToolContext.swift:11` | `s:10AgentTools11ToolContextV13argumentsJSONSSSgvp` | KEEP |
| AgentTools | Instance Property | `ToolContext.callID` | `Sources/AgentTools/ToolContext.swift:7` | `s:10AgentTools11ToolContextV6callID0A6Models0c4CallF0Vvp` | KEEP |
| AgentTools | Instance Property | `ToolContext.deadline` | `Sources/AgentTools/ToolContext.swift:8` | `s:10AgentTools11ToolContextV8deadline12_Concurrency15ContinuousClockV7InstantVSgvp` | KEEP |
| AgentTools | Instance Property | `ToolContext.idempotencyKey` | `Sources/AgentTools/ToolContext.swift:9` | `s:10AgentTools11ToolContextV14idempotencyKeySSSgvp` | KEEP |
| AgentTools | Initializer | `ToolContext.init(sessionID:runID:callID:deadline:idempotencyKey:argumentsJSON:evidenceLedger:)` | `Sources/AgentTools/ToolContext.swift:15` | `s:10AgentTools11ToolContextV9sessionID03runF004callF08deadline14idempotencyKey13argumentsJSON14evidenceLedgerAC10Foundation4UUIDV_AM0A6Models0c4CallF0V12_Concurrency15ContinuousClockV7InstantVSgSSSgAwA08EvidenceO0CSgtcfc` | KEEP |
| AgentTools | Instance Method | `ToolContext.requireEvidence(_:)` | `Sources/AgentTools/ToolContext.swift:71` | `s:10AgentTools11ToolContextV15requireEvidenceyySayAA0F11RequirementVGYaKF` | KEEP |
| AgentTools | Instance Method | `ToolContext.resolveEvidence(_:)` | `Sources/AgentTools/ToolContext.swift:76` | `s:10AgentTools11ToolContextV15resolveEvidenceySayAA0F0VGSayAA0F11RequirementVGYaKF` | KEEP |
| AgentTools | Instance Property | `ToolContext.runID` | `Sources/AgentTools/ToolContext.swift:6` | `s:10AgentTools11ToolContextV5runID10Foundation4UUIDVvp` | KEEP |
| AgentTools | Instance Property | `ToolContext.sessionID` | `Sources/AgentTools/ToolContext.swift:5` | `s:10AgentTools11ToolContextV9sessionID10Foundation4UUIDVvp` | KEEP |
| AgentTools | Enumeration | `ToolInvocationError` | `Sources/AgentTools/AnyAgentTool.swift:137` | `s:10AgentTools19ToolInvocationErrorO` | KEEP |
| AgentTools | Operator | `ToolInvocationError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools19ToolInvocationErrorO` | KEEP |
| AgentTools | Case | `ToolInvocationError.authorizationDenied` | `Sources/AgentTools/AnyAgentTool.swift:143` | `s:10AgentTools19ToolInvocationErrorO19authorizationDeniedyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.deadlineExceeded` | `Sources/AgentTools/AnyAgentTool.swift:142` | `s:10AgentTools19ToolInvocationErrorO16deadlineExceededyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.evidenceUnavailable` | `Sources/AgentTools/AnyAgentTool.swift:146` | `s:10AgentTools19ToolInvocationErrorO19evidenceUnavailableyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.invalidArguments` | `Sources/AgentTools/AnyAgentTool.swift:139` | `s:10AgentTools19ToolInvocationErrorO16invalidArgumentsyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.invalidDefinition` | `Sources/AgentTools/AnyAgentTool.swift:138` | `s:10AgentTools19ToolInvocationErrorO17invalidDefinitionyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.invalidOutput` | `Sources/AgentTools/AnyAgentTool.swift:140` | `s:10AgentTools19ToolInvocationErrorO13invalidOutputyA2CmF` | KEEP |
| AgentTools | Instance Property | `ToolInvocationError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools19ToolInvocationErrorO` | KEEP |
| AgentTools | Case | `ToolInvocationError.missingIdempotencyKey` | `Sources/AgentTools/AnyAgentTool.swift:141` | `s:10AgentTools19ToolInvocationErrorO21missingIdempotencyKeyyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.mutationIntegrityUnavailable` | `Sources/AgentTools/AnyAgentTool.swift:144` | `s:10AgentTools19ToolInvocationErrorO28mutationIntegrityUnavailableyA2CmF` | KEEP |
| AgentTools | Case | `ToolInvocationError.receiptValidationUnavailable` | `Sources/AgentTools/AnyAgentTool.swift:145` | `s:10AgentTools19ToolInvocationErrorO28receiptValidationUnavailableyA2CmF` | KEEP |
| AgentTools | Structure | `ToolPolicy` | `Sources/AgentTools/ToolPolicy.swift:3` | `s:10AgentTools10ToolPolicyV` | KEEP |
| AgentTools | Operator | `ToolPolicy.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.authorization` | `Sources/AgentTools/ToolPolicy.swift:16` | `s:10AgentTools10ToolPolicyV13authorizationAC13AuthorizationOvp` | KEEP |
| AgentTools | Enumeration | `ToolPolicy.Authorization` | `Sources/AgentTools/ToolPolicy.swift:7` | `s:10AgentTools10ToolPolicyV13AuthorizationO` | KEEP |
| AgentTools | Operator | `ToolPolicy.Authorization.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV13AuthorizationO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Authorization.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools10ToolPolicyV13AuthorizationO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Authorization.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools10ToolPolicyV13AuthorizationO` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.Authorization.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools10ToolPolicyV13AuthorizationO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Authorization.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools10ToolPolicyV13AuthorizationO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Authorization.init(rawValue:)` | `-` | `s:10AgentTools10ToolPolicyV13AuthorizationO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolPolicy.Authorization.notRequired` | `Sources/AgentTools/ToolPolicy.swift:7` | `s:10AgentTools10ToolPolicyV13AuthorizationO11notRequiredyA2EmF` | KEEP |
| AgentTools | Case | `ToolPolicy.Authorization.required` | `Sources/AgentTools/ToolPolicy.swift:7` | `s:10AgentTools10ToolPolicyV13AuthorizationO8requiredyA2EmF` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.effect` | `Sources/AgentTools/ToolPolicy.swift:11` | `s:10AgentTools10ToolPolicyV6effectAC6EffectOvp` | KEEP |
| AgentTools | Enumeration | `ToolPolicy.Effect` | `Sources/AgentTools/ToolPolicy.swift:4` | `s:10AgentTools10ToolPolicyV6EffectO` | KEEP |
| AgentTools | Operator | `ToolPolicy.Effect.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV6EffectO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Effect.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools10ToolPolicyV6EffectO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Effect.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools10ToolPolicyV6EffectO` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.Effect.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools10ToolPolicyV6EffectO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Effect.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools10ToolPolicyV6EffectO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Effect.init(rawValue:)` | `-` | `s:10AgentTools10ToolPolicyV6EffectO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolPolicy.Effect.mutation` | `Sources/AgentTools/ToolPolicy.swift:4` | `s:10AgentTools10ToolPolicyV6EffectO8mutationyA2EmF` | KEEP |
| AgentTools | Case | `ToolPolicy.Effect.readOnly` | `Sources/AgentTools/ToolPolicy.swift:4` | `s:10AgentTools10ToolPolicyV6EffectO8readOnlyyA2EmF` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.encode(to:)` | `Sources/AgentTools/ToolPolicy.swift:90` | `s:10AgentTools10ToolPolicyV6encode2toys7Encoder_p_tKF` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.evidence` | `Sources/AgentTools/ToolPolicy.swift:17` | `s:10AgentTools10ToolPolicyV8evidenceAC08EvidenceD0Ovp` | KEEP |
| AgentTools | Enumeration | `ToolPolicy.EvidencePolicy` | `Sources/AgentTools/ToolPolicy.swift:8` | `s:10AgentTools10ToolPolicyV08EvidenceD0O` | KEEP |
| AgentTools | Operator | `ToolPolicy.EvidencePolicy.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV08EvidenceD0O` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.EvidencePolicy.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools10ToolPolicyV08EvidenceD0O` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.EvidencePolicy.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools10ToolPolicyV08EvidenceD0O` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.EvidencePolicy.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools10ToolPolicyV08EvidenceD0O` | KEEP |
| AgentTools | Initializer | `ToolPolicy.EvidencePolicy.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools10ToolPolicyV08EvidenceD0O` | KEEP |
| AgentTools | Initializer | `ToolPolicy.EvidencePolicy.init(rawValue:)` | `-` | `s:10AgentTools10ToolPolicyV08EvidenceD0O8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolPolicy.EvidencePolicy.none` | `Sources/AgentTools/ToolPolicy.swift:8` | `s:10AgentTools10ToolPolicyV08EvidenceD0O4noneyA2EmF` | KEEP |
| AgentTools | Case | `ToolPolicy.EvidencePolicy.required` | `Sources/AgentTools/ToolPolicy.swift:8` | `s:10AgentTools10ToolPolicyV08EvidenceD0O8requiredyA2EmF` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.execution` | `Sources/AgentTools/ToolPolicy.swift:12` | `s:10AgentTools10ToolPolicyV9executionAC9ExecutionOvp` | KEEP |
| AgentTools | Enumeration | `ToolPolicy.Execution` | `Sources/AgentTools/ToolPolicy.swift:5` | `s:10AgentTools10ToolPolicyV9ExecutionO` | KEEP |
| AgentTools | Operator | `ToolPolicy.Execution.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV9ExecutionO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Execution.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools10ToolPolicyV9ExecutionO` | KEEP |
| AgentTools | Case | `ToolPolicy.Execution.exclusive` | `Sources/AgentTools/ToolPolicy.swift:5` | `s:10AgentTools10ToolPolicyV9ExecutionO9exclusiveyA2EmF` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Execution.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools10ToolPolicyV9ExecutionO` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.Execution.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools10ToolPolicyV9ExecutionO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Execution.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools10ToolPolicyV9ExecutionO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Execution.init(rawValue:)` | `-` | `s:10AgentTools10ToolPolicyV9ExecutionO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolPolicy.Execution.parallel` | `Sources/AgentTools/ToolPolicy.swift:5` | `s:10AgentTools10ToolPolicyV9ExecutionO8parallelyA2EmF` | KEEP |
| AgentTools | Case | `ToolPolicy.Execution.sequential` | `Sources/AgentTools/ToolPolicy.swift:5` | `s:10AgentTools10ToolPolicyV9ExecutionO10sequentialyA2EmF` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.idempotency` | `Sources/AgentTools/ToolPolicy.swift:13` | `s:10AgentTools10ToolPolicyV11idempotencyAC11IdempotencyOvp` | KEEP |
| AgentTools | Enumeration | `ToolPolicy.Idempotency` | `Sources/AgentTools/ToolPolicy.swift:6` | `s:10AgentTools10ToolPolicyV11IdempotencyO` | KEEP |
| AgentTools | Operator | `ToolPolicy.Idempotency.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV11IdempotencyO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Idempotency.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools10ToolPolicyV11IdempotencyO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.Idempotency.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools10ToolPolicyV11IdempotencyO` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.Idempotency.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools10ToolPolicyV11IdempotencyO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Idempotency.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools10ToolPolicyV11IdempotencyO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.Idempotency.init(rawValue:)` | `-` | `s:10AgentTools10ToolPolicyV11IdempotencyO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolPolicy.Idempotency.keyed` | `Sources/AgentTools/ToolPolicy.swift:6` | `s:10AgentTools10ToolPolicyV11IdempotencyO5keyedyA2EmF` | KEEP |
| AgentTools | Case | `ToolPolicy.Idempotency.requiresReceipt` | `Sources/AgentTools/ToolPolicy.swift:6` | `s:10AgentTools10ToolPolicyV11IdempotencyO15requiresReceiptyA2EmF` | KEEP |
| AgentTools | Case | `ToolPolicy.Idempotency.safe` | `Sources/AgentTools/ToolPolicy.swift:6` | `s:10AgentTools10ToolPolicyV11IdempotencyO4safeyA2EmF` | KEEP |
| AgentTools | Initializer | `ToolPolicy.init(effect:execution:idempotency:timeout:authorization:evidence:recoverableErrors:)` | `Sources/AgentTools/ToolPolicy.swift:24` | `s:10AgentTools10ToolPolicyV6effect9execution11idempotency7timeout13authorization8evidence17recoverableErrorsA2C6EffectO_AC9ExecutionOAC11IdempotencyOs8DurationVAC13AuthorizationOAC08EvidenceD0OAC011RecoverableL0OtKcfc` | KEEP |
| AgentTools | Initializer | `ToolPolicy.init(from:)` | `Sources/AgentTools/ToolPolicy.swift:77` | `s:10AgentTools10ToolPolicyV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Type Method | `ToolPolicy.mutation(idempotency:timeout:authorization:evidence:)` | `Sources/AgentTools/ToolPolicy.swift:65` | `s:10AgentTools10ToolPolicyV8mutation11idempotency7timeout13authorization8evidenceA2C11IdempotencyO_s8DurationVAC13AuthorizationOAC08EvidenceD0OtKFZ` | KEEP |
| AgentTools | Type Method | `ToolPolicy.readOnly(timeout:authorization:evidence:recoverableErrors:)` | `Sources/AgentTools/ToolPolicy.swift:50` | `s:10AgentTools10ToolPolicyV8readOnly7timeout13authorization8evidence17recoverableErrorsACs8DurationV_AC13AuthorizationOAC08EvidenceD0OAC011RecoverableK0OtKFZ` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.recoverableErrors` | `Sources/AgentTools/ToolPolicy.swift:18` | `s:10AgentTools10ToolPolicyV17recoverableErrorsAC011RecoverableF0Ovp` | KEEP |
| AgentTools | Enumeration | `ToolPolicy.RecoverableErrors` | `Sources/AgentTools/ToolPolicy.swift:9` | `s:10AgentTools10ToolPolicyV17RecoverableErrorsO` | KEEP |
| AgentTools | Operator | `ToolPolicy.RecoverableErrors.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolPolicyV17RecoverableErrorsO` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.RecoverableErrors.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools10ToolPolicyV17RecoverableErrorsO` | KEEP |
| AgentTools | Case | `ToolPolicy.RecoverableErrors.failClosed` | `Sources/AgentTools/ToolPolicy.swift:9` | `s:10AgentTools10ToolPolicyV17RecoverableErrorsO10failClosedyA2EmF` | KEEP |
| AgentTools | Instance Method | `ToolPolicy.RecoverableErrors.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools10ToolPolicyV17RecoverableErrorsO` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.RecoverableErrors.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools10ToolPolicyV17RecoverableErrorsO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.RecoverableErrors.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools10ToolPolicyV17RecoverableErrorsO` | KEEP |
| AgentTools | Initializer | `ToolPolicy.RecoverableErrors.init(rawValue:)` | `-` | `s:10AgentTools10ToolPolicyV17RecoverableErrorsO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolPolicy.RecoverableErrors.modelVisible` | `Sources/AgentTools/ToolPolicy.swift:9` | `s:10AgentTools10ToolPolicyV17RecoverableErrorsO12modelVisibleyA2EmF` | KEEP |
| AgentTools | Instance Property | `ToolPolicy.timeout` | `Sources/AgentTools/ToolPolicy.swift:15` | `s:10AgentTools10ToolPolicyV7timeouts8DurationVvp` | KEEP |
| AgentTools | Enumeration | `ToolPolicyError` | `Sources/AgentTools/ToolPolicy.swift:102` | `s:10AgentTools15ToolPolicyErrorO` | KEEP |
| AgentTools | Operator | `ToolPolicyError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools15ToolPolicyErrorO` | KEEP |
| AgentTools | Case | `ToolPolicyError.invalidTimeout` | `Sources/AgentTools/ToolPolicy.swift:103` | `s:10AgentTools15ToolPolicyErrorO14invalidTimeoutyA2CmF` | KEEP |
| AgentTools | Instance Property | `ToolPolicyError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools15ToolPolicyErrorO` | KEEP |
| AgentTools | Case | `ToolPolicyError.mutationCannotExposeRecoverableErrors` | `Sources/AgentTools/ToolPolicy.swift:105` | `s:10AgentTools15ToolPolicyErrorO37mutationCannotExposeRecoverableErrorsyA2CmF` | KEEP |
| AgentTools | Case | `ToolPolicyError.mutationRequiresExclusiveExecution` | `Sources/AgentTools/ToolPolicy.swift:104` | `s:10AgentTools15ToolPolicyErrorO34mutationRequiresExclusiveExecutionyA2CmF` | KEEP |
| AgentTools | Structure | `ToolReceipt` | `Sources/AgentTools/ToolReceipt.swift:5` | `s:10AgentTools11ToolReceiptV` | KEEP |
| AgentTools | Operator | `ToolReceipt.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools11ToolReceiptV` | KEEP |
| AgentTools | Operator | `ToolReceipt.==(_:_:)` | `Sources/AgentTools/ToolReceipt.swift:24` | `s:10AgentTools11ToolReceiptV2eeoiySbAC_ACtFZ` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.confirmedTargets` | `Sources/AgentTools/ToolReceipt.swift:11` | `s:10AgentTools11ToolReceiptV16confirmedTargetsSayAA17EvidenceReferenceVGvp` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.failure` | `Sources/AgentTools/ToolReceipt.swift:13` | `s:10AgentTools11ToolReceiptV7failureAC7FailureOSgvp` | KEEP |
| AgentTools | Enumeration | `ToolReceipt.Failure` | `Sources/AgentTools/ToolReceipt.swift:7` | `s:10AgentTools11ToolReceiptV7FailureO` | KEEP |
| AgentTools | Operator | `ToolReceipt.Failure.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools11ToolReceiptV7FailureO` | KEEP |
| AgentTools | Case | `ToolReceipt.Failure.conflict` | `Sources/AgentTools/ToolReceipt.swift:7` | `s:10AgentTools11ToolReceiptV7FailureO8conflictyA2EmF` | KEEP |
| AgentTools | Instance Method | `ToolReceipt.Failure.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools11ToolReceiptV7FailureO` | KEEP |
| AgentTools | Instance Method | `ToolReceipt.Failure.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools11ToolReceiptV7FailureO` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.Failure.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools11ToolReceiptV7FailureO` | KEEP |
| AgentTools | Initializer | `ToolReceipt.Failure.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools11ToolReceiptV7FailureO` | KEEP |
| AgentTools | Initializer | `ToolReceipt.Failure.init(rawValue:)` | `-` | `s:10AgentTools11ToolReceiptV7FailureO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolReceipt.Failure.rejected` | `Sources/AgentTools/ToolReceipt.swift:7` | `s:10AgentTools11ToolReceiptV7FailureO8rejectedyA2EmF` | KEEP |
| AgentTools | Case | `ToolReceipt.Failure.unavailable` | `Sources/AgentTools/ToolReceipt.swift:7` | `s:10AgentTools11ToolReceiptV7FailureO11unavailableyA2EmF` | KEEP |
| AgentTools | Case | `ToolReceipt.Failure.unknown` | `Sources/AgentTools/ToolReceipt.swift:7` | `s:10AgentTools11ToolReceiptV7FailureO7unknownyA2EmF` | KEEP |
| AgentTools | Initializer | `ToolReceipt.init(from:)` | `-` | `s:10AgentTools11ToolReceiptV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Initializer | `ToolReceipt.init(operationID:status:confirmedTargets:revision:failure:)` | `Sources/AgentTools/ToolReceipt.swift:15` | `s:10AgentTools11ToolReceiptV11operationID6status16confirmedTargets8revision7failureACSS_AC6StatusOSayAA17EvidenceReferenceVGSSSgAC7FailureOSgtcfc` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.operationID` | `Sources/AgentTools/ToolReceipt.swift:9` | `s:10AgentTools11ToolReceiptV11operationIDSSvp` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.revision` | `Sources/AgentTools/ToolReceipt.swift:12` | `s:10AgentTools11ToolReceiptV8revisionSSSgvp` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.status` | `Sources/AgentTools/ToolReceipt.swift:10` | `s:10AgentTools11ToolReceiptV6statusAC6StatusOvp` | KEEP |
| AgentTools | Enumeration | `ToolReceipt.Status` | `Sources/AgentTools/ToolReceipt.swift:6` | `s:10AgentTools11ToolReceiptV6StatusO` | KEEP |
| AgentTools | Operator | `ToolReceipt.Status.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools11ToolReceiptV6StatusO` | KEEP |
| AgentTools | Instance Method | `ToolReceipt.Status.encode(to:)` | `-` | `s:SYsSERzSS8RawValueSYRtzrlE6encode2toys7Encoder_p_tKF::SYNTHESIZED::s:10AgentTools11ToolReceiptV6StatusO` | KEEP |
| AgentTools | Case | `ToolReceipt.Status.failed` | `Sources/AgentTools/ToolReceipt.swift:6` | `s:10AgentTools11ToolReceiptV6StatusO6failedyA2EmF` | KEEP |
| AgentTools | Instance Method | `ToolReceipt.Status.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:10AgentTools11ToolReceiptV6StatusO` | KEEP |
| AgentTools | Instance Property | `ToolReceipt.Status.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:10AgentTools11ToolReceiptV6StatusO` | KEEP |
| AgentTools | Case | `ToolReceipt.Status.indeterminate` | `Sources/AgentTools/ToolReceipt.swift:6` | `s:10AgentTools11ToolReceiptV6StatusO13indeterminateyA2EmF` | KEEP |
| AgentTools | Initializer | `ToolReceipt.Status.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:10AgentTools11ToolReceiptV6StatusO` | KEEP |
| AgentTools | Initializer | `ToolReceipt.Status.init(rawValue:)` | `-` | `s:10AgentTools11ToolReceiptV6StatusO8rawValueAESgSS_tcfc` | KEEP |
| AgentTools | Case | `ToolReceipt.Status.succeeded` | `Sources/AgentTools/ToolReceipt.swift:6` | `s:10AgentTools11ToolReceiptV6StatusO9succeededyA2EmF` | KEEP |
| AgentTools | Enumeration | `ToolReceiptError` | `Sources/AgentTools/ToolReceipt.swift:82` | `s:10AgentTools16ToolReceiptErrorO` | KEEP |
| AgentTools | Operator | `ToolReceiptError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools16ToolReceiptErrorO` | KEEP |
| AgentTools | Case | `ToolReceiptError.inconsistentStatus` | `Sources/AgentTools/ToolReceipt.swift:88` | `s:10AgentTools16ToolReceiptErrorO18inconsistentStatusyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.invalidExpectation` | `Sources/AgentTools/ToolReceipt.swift:83` | `s:10AgentTools16ToolReceiptErrorO18invalidExpectationyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.invalidOperationID` | `Sources/AgentTools/ToolReceipt.swift:84` | `s:10AgentTools16ToolReceiptErrorO18invalidOperationIDyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.invalidRevision` | `Sources/AgentTools/ToolReceipt.swift:91` | `s:10AgentTools16ToolReceiptErrorO15invalidRevisionyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.invalidTargets` | `Sources/AgentTools/ToolReceipt.swift:89` | `s:10AgentTools16ToolReceiptErrorO14invalidTargetsyA2CmF` | KEEP |
| AgentTools | Instance Property | `ToolReceiptError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools16ToolReceiptErrorO` | KEEP |
| AgentTools | Case | `ToolReceiptError.missing` | `Sources/AgentTools/ToolReceipt.swift:85` | `s:10AgentTools16ToolReceiptErrorO7missingyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.operationMismatch` | `Sources/AgentTools/ToolReceipt.swift:86` | `s:10AgentTools16ToolReceiptErrorO17operationMismatchyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.revisionMismatch` | `Sources/AgentTools/ToolReceipt.swift:92` | `s:10AgentTools16ToolReceiptErrorO16revisionMismatchyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.targetsMismatch` | `Sources/AgentTools/ToolReceipt.swift:90` | `s:10AgentTools16ToolReceiptErrorO15targetsMismatchyA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.unexpectedReceipt` | `Sources/AgentTools/ToolReceipt.swift:93` | `s:10AgentTools16ToolReceiptErrorO010unexpectedD0yA2CmF` | KEEP |
| AgentTools | Case | `ToolReceiptError.unsuccessful(_:_:)` | `Sources/AgentTools/ToolReceipt.swift:87` | `s:10AgentTools16ToolReceiptErrorO12unsuccessfulyAcA0cD0V6StatusO_AF7FailureOSgtcACmF` | KEEP |
| AgentTools | Structure | `ToolReceiptExpectation` | `Sources/AgentTools/ToolReceipt.swift:31` | `s:10AgentTools22ToolReceiptExpectationV` | KEEP |
| AgentTools | Operator | `ToolReceiptExpectation.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools22ToolReceiptExpectationV` | KEEP |
| AgentTools | Initializer | `ToolReceiptExpectation.init(from:)` | `-` | `s:10AgentTools22ToolReceiptExpectationV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Initializer | `ToolReceiptExpectation.init(targets:revision:)` | `Sources/AgentTools/ToolReceipt.swift:42` | `s:10AgentTools22ToolReceiptExpectationV7targets8revisionACSayAA17EvidenceReferenceVG_AC8RevisionOtKcfc` | KEEP |
| AgentTools | Instance Property | `ToolReceiptExpectation.revision` | `Sources/AgentTools/ToolReceipt.swift:40` | `s:10AgentTools22ToolReceiptExpectationV8revisionAC8RevisionOvp` | KEEP |
| AgentTools | Enumeration | `ToolReceiptExpectation.Revision` | `Sources/AgentTools/ToolReceipt.swift:32` | `s:10AgentTools22ToolReceiptExpectationV8RevisionO` | KEEP |
| AgentTools | Operator | `ToolReceiptExpectation.Revision.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools22ToolReceiptExpectationV8RevisionO` | KEEP |
| AgentTools | Case | `ToolReceiptExpectation.Revision.changed(from:)` | `Sources/AgentTools/ToolReceipt.swift:36` | `s:10AgentTools22ToolReceiptExpectationV8RevisionO7changedyAESS_tcAEmF` | KEEP |
| AgentTools | Case | `ToolReceiptExpectation.Revision.exact(_:)` | `Sources/AgentTools/ToolReceipt.swift:35` | `s:10AgentTools22ToolReceiptExpectationV8RevisionO5exactyAESScAEmF` | KEEP |
| AgentTools | Initializer | `ToolReceiptExpectation.Revision.init(from:)` | `-` | `s:10AgentTools22ToolReceiptExpectationV8RevisionO4fromAEs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Case | `ToolReceiptExpectation.Revision.optional` | `Sources/AgentTools/ToolReceipt.swift:33` | `s:10AgentTools22ToolReceiptExpectationV8RevisionO8optionalyA2EmF` | KEEP |
| AgentTools | Case | `ToolReceiptExpectation.Revision.present` | `Sources/AgentTools/ToolReceipt.swift:34` | `s:10AgentTools22ToolReceiptExpectationV8RevisionO7presentyA2EmF` | KEEP |
| AgentTools | Instance Property | `ToolReceiptExpectation.targets` | `Sources/AgentTools/ToolReceipt.swift:39` | `s:10AgentTools22ToolReceiptExpectationV7targetsSayAA17EvidenceReferenceVGvp` | KEEP |
| AgentTools | Enumeration | `ToolReceiptValidator` | `Sources/AgentTools/ToolReceipt.swift:56` | `s:10AgentTools20ToolReceiptValidatorO` | KEEP |
| AgentTools | Type Method | `ToolReceiptValidator.validate(_:operationID:expectation:)` | `Sources/AgentTools/ToolReceipt.swift:57` | `s:10AgentTools20ToolReceiptValidatorO8validate_11operationID11expectationyAA0cD0VSg_SSAA0cD11ExpectationVtKFZ` | KEEP |
| AgentTools | Enumeration | `ToolRegistryError` | `Sources/AgentTools/ToolRegistry.swift:103` | `s:10AgentTools17ToolRegistryErrorO` | KEEP |
| AgentTools | Operator | `ToolRegistryError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools17ToolRegistryErrorO` | KEEP |
| AgentTools | Case | `ToolRegistryError.callIdentityMismatch` | `Sources/AgentTools/ToolRegistry.swift:107` | `s:10AgentTools17ToolRegistryErrorO20callIdentityMismatchyA2CmF` | KEEP |
| AgentTools | Case | `ToolRegistryError.duplicateName(_:)` | `Sources/AgentTools/ToolRegistry.swift:105` | `s:10AgentTools17ToolRegistryErrorO13duplicateNameyACSScACmF` | KEEP |
| AgentTools | Case | `ToolRegistryError.invalidArguments(_:)` | `Sources/AgentTools/ToolRegistry.swift:110` | `s:10AgentTools17ToolRegistryErrorO16invalidArgumentsyAcA0c16SchemaValidationE0VcACmF` | KEEP |
| AgentTools | Case | `ToolRegistryError.invalidJSON` | `Sources/AgentTools/ToolRegistry.swift:108` | `s:10AgentTools17ToolRegistryErrorO11invalidJSONyA2CmF` | KEEP |
| AgentTools | Case | `ToolRegistryError.invalidOutput(_:)` | `Sources/AgentTools/ToolRegistry.swift:111` | `s:10AgentTools17ToolRegistryErrorO13invalidOutputyAcA0c16SchemaValidationE0VcACmF` | KEEP |
| AgentTools | Case | `ToolRegistryError.invalidSchema(tool:issue:)` | `Sources/AgentTools/ToolRegistry.swift:109` | `s:10AgentTools17ToolRegistryErrorO13invalidSchemayACSS_AA0cg10ValidationE0VtcACmF` | KEEP |
| AgentTools | Instance Property | `ToolRegistryError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools17ToolRegistryErrorO` | KEEP |
| AgentTools | Case | `ToolRegistryError.truncatedCall` | `Sources/AgentTools/ToolRegistry.swift:106` | `s:10AgentTools17ToolRegistryErrorO13truncatedCallyA2CmF` | KEEP |
| AgentTools | Case | `ToolRegistryError.unknownTool(_:)` | `Sources/AgentTools/ToolRegistry.swift:104` | `s:10AgentTools17ToolRegistryErrorO07unknownC0yACSScACmF` | KEEP |
| AgentTools | Enumeration | `ToolResource` | `Sources/AgentTools/ToolResource.swift:1` | `s:10AgentTools12ToolResourceO` | KEEP |
| AgentTools | Operator | `ToolResource.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools12ToolResourceO` | KEEP |
| AgentTools | Case | `ToolResource.global` | `Sources/AgentTools/ToolResource.swift:2` | `s:10AgentTools12ToolResourceO6globalyA2CmF` | KEEP |
| AgentTools | Initializer | `ToolResource.init(from:)` | `-` | `s:10AgentTools12ToolResourceO4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentTools | Case | `ToolResource.named(_:)` | `Sources/AgentTools/ToolResource.swift:3` | `s:10AgentTools12ToolResourceO5namedyAcA17EvidenceReferenceVcACmF` | KEEP |
| AgentTools | Enumeration | `ToolResourceError` | `Sources/AgentTools/ToolResource.swift:17` | `s:10AgentTools17ToolResourceErrorO` | KEEP |
| AgentTools | Operator | `ToolResourceError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools17ToolResourceErrorO` | KEEP |
| AgentTools | Case | `ToolResourceError.duplicate` | `Sources/AgentTools/ToolResource.swift:20` | `s:10AgentTools17ToolResourceErrorO9duplicateyA2CmF` | KEEP |
| AgentTools | Case | `ToolResourceError.empty` | `Sources/AgentTools/ToolResource.swift:18` | `s:10AgentTools17ToolResourceErrorO5emptyyA2CmF` | KEEP |
| AgentTools | Case | `ToolResourceError.invalidReference(_:)` | `Sources/AgentTools/ToolResource.swift:19` | `s:10AgentTools17ToolResourceErrorO16invalidReferenceyAcA08EvidenceG0VcACmF` | KEEP |
| AgentTools | Instance Property | `ToolResourceError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools17ToolResourceErrorO` | KEEP |
| AgentTools | Structure | `ToolResult` | `Sources/AgentTools/AgentTool.swift:107` | `s:10AgentTools10ToolResultV` | KEEP |
| AgentTools | Instance Property | `ToolResult.evidence` | `Sources/AgentTools/AgentTool.swift:109` | `s:10AgentTools10ToolResultV8evidenceSayAA8EvidenceVGvp` | KEEP |
| AgentTools | Initializer | `ToolResult.init(output:evidence:receipt:)` | `Sources/AgentTools/AgentTool.swift:114` | `s:10AgentTools10ToolResultV6output8evidence7receiptACyxGx_SayAA8EvidenceVGAA0C7ReceiptVSgtcfc` | KEEP |
| AgentTools | Instance Property | `ToolResult.output` | `Sources/AgentTools/AgentTool.swift:108` | `s:10AgentTools10ToolResultV6outputxvp` | KEEP |
| AgentTools | Instance Property | `ToolResult.receipt` | `Sources/AgentTools/AgentTool.swift:110` | `s:10AgentTools10ToolResultV7receiptAA0C7ReceiptVSgvp` | KEEP |
| AgentTools | Structure | `ToolScheduler` | `Sources/AgentTools/ToolScheduler.swift:8` | `s:10AgentTools13ToolSchedulerV` | KEEP |
| AgentTools | Initializer | `ToolScheduler.init()` | `Sources/AgentTools/ToolScheduler.swift:12` | `s:10AgentTools13ToolSchedulerVACycfc` | KEEP |
| AgentTools | Instance Method | `ToolScheduler.waitForRunToDrain(sessionID:runID:)` | `Sources/AgentTools/ToolScheduler.swift:16` | `s:10AgentTools13ToolSchedulerV17waitForRunToDrain9sessionID03runK0y10Foundation4UUIDV_AItYaF` | KEEP |
| AgentTools | Enumeration | `ToolSchedulerError` | `Sources/AgentTools/ToolScheduler.swift:159` | `s:10AgentTools18ToolSchedulerErrorO` | KEEP |
| AgentTools | Operator | `ToolSchedulerError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools18ToolSchedulerErrorO` | KEEP |
| AgentTools | Case | `ToolSchedulerError.deadlineExceeded` | `Sources/AgentTools/ToolScheduler.swift:160` | `s:10AgentTools18ToolSchedulerErrorO16deadlineExceededyA2CmF` | KEEP |
| AgentTools | Instance Property | `ToolSchedulerError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools18ToolSchedulerErrorO` | KEEP |
| AgentTools | Case | `ToolSchedulerError.toolTimedOut(_:)` | `Sources/AgentTools/ToolScheduler.swift:161` | `s:10AgentTools18ToolSchedulerErrorO12toolTimedOutyAC0A6Models0C6CallIDVcACmF` | KEEP |
| AgentTools | Structure | `ToolSchema` | `Sources/AgentTools/ToolSchema.swift:4` | `s:10AgentTools10ToolSchemaV` | KEEP |
| AgentTools | Operator | `ToolSchema.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools10ToolSchemaV` | KEEP |
| AgentTools | Type Method | `ToolSchema.array(items:)` | `Sources/AgentTools/ToolSchema.swift:30` | `s:10AgentTools10ToolSchemaV5array5itemsA2C_tFZ` | KEEP |
| AgentTools | Type Property | `ToolSchema.boolean` | `Sources/AgentTools/ToolSchema.swift:14` | `s:10AgentTools10ToolSchemaV7booleanACvpZ` | KEEP |
| AgentTools | Type Method | `ToolSchema.enumeration(_:)` | `Sources/AgentTools/ToolSchema.swift:34` | `s:10AgentTools10ToolSchemaV11enumerationyACSay0A6Models9JSONValueOGFZ` | KEEP |
| AgentTools | Initializer | `ToolSchema.init(json:)` | `Sources/AgentTools/ToolSchema.swift:7` | `s:10AgentTools10ToolSchemaV4jsonAC0A6Models9JSONValueO_tcfc` | KEEP |
| AgentTools | Type Property | `ToolSchema.integer` | `Sources/AgentTools/ToolSchema.swift:12` | `s:10AgentTools10ToolSchemaV7integerACvpZ` | KEEP |
| AgentTools | Instance Property | `ToolSchema.json` | `Sources/AgentTools/ToolSchema.swift:5` | `s:10AgentTools10ToolSchemaV4json0A6Models9JSONValueOvp` | KEEP |
| AgentTools | Type Property | `ToolSchema.null` | `Sources/AgentTools/ToolSchema.swift:15` | `s:10AgentTools10ToolSchemaV4nullACvpZ` | KEEP |
| AgentTools | Type Property | `ToolSchema.number` | `Sources/AgentTools/ToolSchema.swift:13` | `s:10AgentTools10ToolSchemaV6numberACvpZ` | KEEP |
| AgentTools | Type Method | `ToolSchema.object(properties:required:additionalProperties:)` | `Sources/AgentTools/ToolSchema.swift:17` | `s:10AgentTools10ToolSchemaV6object10properties8required20additionalPropertiesACSDySSACG_ShySSGSbtFZ` | KEEP |
| AgentTools | Type Property | `ToolSchema.string` | `Sources/AgentTools/ToolSchema.swift:11` | `s:10AgentTools10ToolSchemaV6stringACvpZ` | KEEP |
| AgentTools | Structure | `ToolSchemaValidationError` | `Sources/AgentTools/ToolSchemaValidator.swift:173` | `s:10AgentTools25ToolSchemaValidationErrorV` | KEEP |
| AgentTools | Operator | `ToolSchemaValidationError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools25ToolSchemaValidationErrorV` | KEEP |
| AgentTools | Instance Property | `ToolSchemaValidationError.keyword` | `Sources/AgentTools/ToolSchemaValidator.swift:178` | `s:10AgentTools25ToolSchemaValidationErrorV7keywordSSvp` | KEEP |
| AgentTools | Instance Property | `ToolSchemaValidationError.kind` | `Sources/AgentTools/ToolSchemaValidator.swift:175` | `s:10AgentTools25ToolSchemaValidationErrorV4kindAC4KindOvp` | KEEP |
| AgentTools | Enumeration | `ToolSchemaValidationError.Kind` | `Sources/AgentTools/ToolSchemaValidator.swift:174` | `s:10AgentTools25ToolSchemaValidationErrorV4KindO` | KEEP |
| AgentTools | Operator | `ToolSchemaValidationError.Kind.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentTools25ToolSchemaValidationErrorV4KindO` | KEEP |
| AgentTools | Case | `ToolSchemaValidationError.Kind.invalidSchema` | `Sources/AgentTools/ToolSchemaValidator.swift:174` | `s:10AgentTools25ToolSchemaValidationErrorV4KindO07invalidD0yA2EmF` | KEEP |
| AgentTools | Case | `ToolSchemaValidationError.Kind.unsupportedKeyword` | `Sources/AgentTools/ToolSchemaValidator.swift:174` | `s:10AgentTools25ToolSchemaValidationErrorV4KindO18unsupportedKeywordyA2EmF` | KEEP |
| AgentTools | Case | `ToolSchemaValidationError.Kind.violation` | `Sources/AgentTools/ToolSchemaValidator.swift:174` | `s:10AgentTools25ToolSchemaValidationErrorV4KindO9violationyA2EmF` | KEEP |
| AgentTools | Instance Property | `ToolSchemaValidationError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentTools25ToolSchemaValidationErrorV` | KEEP |
| AgentTools | Instance Property | `ToolSchemaValidationError.path` | `Sources/AgentTools/ToolSchemaValidator.swift:177` | `s:10AgentTools25ToolSchemaValidationErrorV4pathSSvp` | KEEP |
| WorkspaceAgent | Structure | `WorkspaceAgentHost` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:7` | `s:14WorkspaceAgent0aB4HostV` | KEEP |
| WorkspaceAgent | Type Method | `WorkspaceAgentHost.anthropic(root:apiKey:model:journal:scheduler:)` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:68` | `s:14WorkspaceAgent0aB4HostV9anthropic4root6apiKey5model7journal9schedulerAC10Foundation3URLV_S2S0B4Core0B7JournalC0B5Tools13ToolSchedulerVtKFZ` | KEEP |
| WorkspaceAgent | Type Property | `WorkspaceAgentHost.defaultInstructions` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:8` | `s:14WorkspaceAgent0aB4HostV19defaultInstructionsSSvpZ` | KEEP |
| WorkspaceAgent | Initializer | `WorkspaceAgentHost.init(root:provider:model:journal:scheduler:instructions:)` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:40` | `s:14WorkspaceAgent0aB4HostV4root8provider5model7journal9scheduler12instructionsAC10Foundation3URLV_0B6Models13ModelProvider_pAM0M2IDV0B4Core0B7JournalC0B5Tools13ToolSchedulerVSStKcfc` | KEEP |
| WorkspaceAgent | Initializer | `WorkspaceAgentHost.init(store:provider:model:journal:scheduler:instructions:tools:)` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:20` | `s:14WorkspaceAgent0aB4HostV5store8provider5model7journal9scheduler12instructions5toolsAcA0A9FileStoreC_0B6Models13ModelProvider_pAM0N2IDV0B4Core0B7JournalC0B5Tools13ToolSchedulerVSSSayAT0bT0_pGSgtKcfc` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceAgentHost.journal` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:17` | `s:14WorkspaceAgent0aB4HostV7journal0B4Core0B7JournalCvp` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceAgentHost.makeSession(id:)` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:84` | `s:14WorkspaceAgent0aB4HostV11makeSession2id0B4Core0bE0C10Foundation4UUIDV_tKF` | KEEP |
| WorkspaceAgent | Type Method | `WorkspaceAgentHost.makeTools(store:)` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:58` | `s:14WorkspaceAgent0aB4HostV9makeTools5storeSay0bE00B4Tool_pGAA0A9FileStoreC_tKFZ` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceAgentHost.scheduler` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:16` | `s:14WorkspaceAgent0aB4HostV9scheduler0B5Tools13ToolSchedulerVvp` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceAgentHost.store` | `Sources/WorkspaceAgent/WorkspaceAgentHost.swift:15` | `s:14WorkspaceAgent0aB4HostV5storeAA0A9FileStoreCvp` | KEEP |
| WorkspaceAgent | Enumeration | `WorkspaceFileError` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:1` | `s:14WorkspaceAgent0A9FileErrorO` | KEEP |
| WorkspaceAgent | Operator | `WorkspaceFileError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14WorkspaceAgent0A9FileErrorO` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.alreadyExists(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:8` | `s:14WorkspaceAgent0A9FileErrorO13alreadyExistsyACSScACmF` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceFileError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:14WorkspaceAgent0A9FileErrorO` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.missingEvidence(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:6` | `s:14WorkspaceAgent0A9FileErrorO15missingEvidenceyACSScACmF` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.notFound(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:4` | `s:14WorkspaceAgent0A9FileErrorO8notFoundyACSScACmF` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.notUnicode(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:5` | `s:14WorkspaceAgent0A9FileErrorO10notUnicodeyACSScACmF` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.parentMissing(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:9` | `s:14WorkspaceAgent0A9FileErrorO13parentMissingyACSScACmF` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.rejectedPath(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:3` | `s:14WorkspaceAgent0A9FileErrorO12rejectedPathyACSScACmF` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.rootUnavailable` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:2` | `s:14WorkspaceAgent0A9FileErrorO15rootUnavailableyA2CmF` | KEEP |
| WorkspaceAgent | Case | `WorkspaceFileError.staleEvidence(_:)` | `Sources/WorkspaceAgent/WorkspaceFileError.swift:7` | `s:14WorkspaceAgent0A9FileErrorO13staleEvidenceyACSScACmF` | KEEP |
| WorkspaceAgent | Structure | `WorkspaceFileRevision` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:24` | `s:14WorkspaceAgent0A12FileRevisionV` | KEEP |
| WorkspaceAgent | Operator | `WorkspaceFileRevision.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14WorkspaceAgent0A12FileRevisionV` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceFileRevision.created` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:27` | `s:14WorkspaceAgent0A12FileRevisionV7createdSbvp` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceFileRevision.hash` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:26` | `s:14WorkspaceAgent0A12FileRevisionV4hashSSvp` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceFileRevision.path` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:25` | `s:14WorkspaceAgent0A12FileRevisionV4pathAA0A4PathVvp` | KEEP |
| WorkspaceAgent | Class | `WorkspaceFileStore` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:30` | `s:14WorkspaceAgent0A9FileStoreC` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceFileStore.assertIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assertIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:14WorkspaceAgent0A9FileStoreC` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceFileStore.assumeIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assumeIsolated_4file4lineqd__qd__xYiKXE_s12StaticStringVSutKs8SendableRd__lF::SYNTHESIZED::s:14WorkspaceAgent0A9FileStoreC` | KEEP |
| WorkspaceAgent | Initializer | `WorkspaceFileStore.init(root:)` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:44` | `s:14WorkspaceAgent0A9FileStoreC4rootAC10Foundation3URLV_tKcfc` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceFileStore.preconditionIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE20preconditionIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:14WorkspaceAgent0A9FileStoreC` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceFileStore.root` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:31` | `s:14WorkspaceAgent0A9FileStoreC4root10Foundation3URLVvp` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceFileStore.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pqd_0_YKXEqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:14WorkspaceAgent0A9FileStoreC` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceFileStore.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pYaqd_0_YKYCXEYaqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:14WorkspaceAgent0A9FileStoreC` | KEEP |
| WorkspaceAgent | Structure | `WorkspaceListedFile` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:12` | `s:14WorkspaceAgent0A10ListedFileV` | KEEP |
| WorkspaceAgent | Operator | `WorkspaceListedFile.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14WorkspaceAgent0A10ListedFileV` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceListedFile.hash` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:14` | `s:14WorkspaceAgent0A10ListedFileV4hashSSvp` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceListedFile.path` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:13` | `s:14WorkspaceAgent0A10ListedFileV4pathAA0A4PathVvp` | KEEP |
| WorkspaceAgent | Structure | `WorkspacePath` | `Sources/WorkspaceAgent/WorkspacePath.swift:13` | `s:14WorkspaceAgent0A4PathV` | KEEP |
| WorkspaceAgent | Operator | `WorkspacePath.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14WorkspaceAgent0A4PathV` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspacePath.parentRelativePath` | `Sources/WorkspaceAgent/WorkspacePath.swift:17` | `s:14WorkspaceAgent0A4PathV014parentRelativeC0SSvp` | KEEP |
| WorkspaceAgent | Type Method | `WorkspacePath.parse(_:root:)` | `Sources/WorkspaceAgent/WorkspacePath.swift:27` | `s:14WorkspaceAgent0A4PathV5parse_4rootACSS_10Foundation3URLVtKFZ` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspacePath.relativePath` | `Sources/WorkspaceAgent/WorkspacePath.swift:14` | `s:14WorkspaceAgent0A4PathV08relativeC0SSvp` | KEEP |
| WorkspaceAgent | Type Method | `WorkspacePath.root(in:)` | `Sources/WorkspaceAgent/WorkspacePath.swift:23` | `s:14WorkspaceAgent0A4PathV4root2inAC10Foundation3URLV_tFZ` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspacePath.url` | `Sources/WorkspaceAgent/WorkspacePath.swift:15` | `s:14WorkspaceAgent0A4PathV3url10Foundation3URLVvp` | KEEP |
| WorkspaceAgent | Structure | `WorkspaceSearchMatch` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:17` | `s:14WorkspaceAgent0A11SearchMatchV` | KEEP |
| WorkspaceAgent | Operator | `WorkspaceSearchMatch.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14WorkspaceAgent0A11SearchMatchV` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceSearchMatch.kind` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:19` | `s:14WorkspaceAgent0A11SearchMatchV4kindAC4KindOvp` | KEEP |
| WorkspaceAgent | Enumeration | `WorkspaceSearchMatch.Kind` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:21` | `s:14WorkspaceAgent0A11SearchMatchV4KindO` | KEEP |
| WorkspaceAgent | Operator | `WorkspaceSearchMatch.Kind.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14WorkspaceAgent0A11SearchMatchV4KindO` | KEEP |
| WorkspaceAgent | Case | `WorkspaceSearchMatch.Kind.content` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:21` | `s:14WorkspaceAgent0A11SearchMatchV4KindO7contentyA2EmF` | KEEP |
| WorkspaceAgent | Instance Method | `WorkspaceSearchMatch.Kind.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:14WorkspaceAgent0A11SearchMatchV4KindO` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceSearchMatch.Kind.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:14WorkspaceAgent0A11SearchMatchV4KindO` | KEEP |
| WorkspaceAgent | Initializer | `WorkspaceSearchMatch.Kind.init(rawValue:)` | `-` | `s:14WorkspaceAgent0A11SearchMatchV4KindO8rawValueAESgSS_tcfc` | KEEP |
| WorkspaceAgent | Case | `WorkspaceSearchMatch.Kind.name` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:21` | `s:14WorkspaceAgent0A11SearchMatchV4KindO4nameyA2EmF` | KEEP |
| WorkspaceAgent | Instance Property | `WorkspaceSearchMatch.path` | `Sources/WorkspaceAgent/WorkspaceFileStore.swift:18` | `s:14WorkspaceAgent0A11SearchMatchV4pathAA0A4PathVvp` | KEEP |
