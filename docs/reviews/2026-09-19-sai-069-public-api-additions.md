# SAI-069 Public API Additions

last-verified: 2026-09-20

Generated from the Swift 6.4 public symbol graph for the SAI-069 working tree.
AgentUsage contributes 139 precise identifiers and 15 top-level types.
They are additive to the 1,156-symbol pre-SAI-069 RC.2 development graph; no
previously public precise identifier is removed.

All entries are KEEP. The product is optional, depends only on AgentModels, and
contains Host-facing observation, diagnostic, aggregation, and explicit-window
APIs. Internal merge and validation helpers are absent from this inventory.

| Module | Kind | Symbol path | Source | Precise identifier | Decision |
| --- | --- | --- | --- | --- | --- |
| AgentUsage | Structure | `UsageAccumulator` | `Sources/AgentUsage/AgentUsage.swift:271` | `s:10AgentUsage0B11AccumulatorV` | KEEP |
| AgentUsage | Initializer | `UsageAccumulator.init()` | `Sources/AgentUsage/AgentUsage.swift:274` | `s:10AgentUsage0B11AccumulatorVACycfc` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.record(_:)` | `Sources/AgentUsage/AgentUsage.swift:277` | `s:10AgentUsage0B11AccumulatorV6recordyAA0B15RecordingResultVAA0B11ObservationVF` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.removeAll()` | `Sources/AgentUsage/AgentUsage.swift:351` | `s:10AgentUsage0B11AccumulatorV9removeAllyyF` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.summary()` | `Sources/AgentUsage/AgentUsage.swift:329` | `s:10AgentUsage0B11AccumulatorV7summaryAA0B7SummaryVyF` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.summary(identity:)` | `Sources/AgentUsage/AgentUsage.swift:333` | `s:10AgentUsage0B11AccumulatorV7summary8identityAA0B7SummaryVAA0B14RecordIdentityV_tF` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.summary(model:)` | `Sources/AgentUsage/AgentUsage.swift:347` | `s:10AgentUsage0B11AccumulatorV7summary5modelAA0B7SummaryV0A6Models7ModelIDV_tF` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.summary(sessionID:)` | `Sources/AgentUsage/AgentUsage.swift:343` | `s:10AgentUsage0B11AccumulatorV7summary9sessionIDAA0B7SummaryV10Foundation4UUIDV_tF` | KEEP |
| AgentUsage | Instance Method | `UsageAccumulator.summary(sessionID:runID:)` | `Sources/AgentUsage/AgentUsage.swift:337` | `s:10AgentUsage0B11AccumulatorV7summary9sessionID03runF0AA0B7SummaryV10Foundation4UUIDV_AKtF` | KEEP |
| AgentUsage | Structure | `UsageCoverage` | `Sources/AgentUsage/AgentUsage.swift:111` | `s:10AgentUsage0B8CoverageV` | KEEP |
| AgentUsage | Operator | `UsageCoverage.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B8CoverageV` | KEEP |
| AgentUsage | Type Property | `UsageCoverage.decisionResponses` | `Sources/AgentUsage/AgentUsage.swift:120` | `s:10AgentUsage0B8CoverageV17decisionResponsesACvpZ` | KEEP |
| AgentUsage | Initializer | `UsageCoverage.init(from:)` | `-` | `s:10AgentUsage0B8CoverageV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Type Property | `UsageCoverage.mixedVisibleResponses` | `Sources/AgentUsage/AgentUsage.swift:121` | `s:10AgentUsage0B8CoverageV21mixedVisibleResponsesACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageCoverage.noSamples` | `Sources/AgentUsage/AgentUsage.swift:118` | `s:10AgentUsage0B8CoverageV9noSamplesACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageCoverage.publicModelResponses` | `Sources/AgentUsage/AgentUsage.swift:119` | `s:10AgentUsage0B8CoverageV20publicModelResponsesACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageCoverage.rawValue` | `Sources/AgentUsage/AgentUsage.swift:112` | `s:10AgentUsage0B8CoverageV8rawValueSSvp` | KEEP |
| AgentUsage | Structure | `UsageDiagnostic` | `Sources/AgentUsage/AgentUsage.swift:231` | `s:10AgentUsage0B10DiagnosticV` | KEEP |
| AgentUsage | Operator | `UsageDiagnostic.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B10DiagnosticV` | KEEP |
| AgentUsage | Instance Property | `UsageDiagnostic.identity` | `Sources/AgentUsage/AgentUsage.swift:233` | `s:10AgentUsage0B10DiagnosticV8identityAA0B14RecordIdentityVvp` | KEEP |
| AgentUsage | Initializer | `UsageDiagnostic.init(from:)` | `-` | `s:10AgentUsage0B10DiagnosticV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Instance Property | `UsageDiagnostic.kind` | `Sources/AgentUsage/AgentUsage.swift:232` | `s:10AgentUsage0B10DiagnosticV4kindAA0bC4KindVvp` | KEEP |
| AgentUsage | Instance Property | `UsageDiagnostic.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:10AgentUsage0B10DiagnosticV` | KEEP |
| AgentUsage | Instance Property | `UsageDiagnostic.metric` | `Sources/AgentUsage/AgentUsage.swift:234` | `s:10AgentUsage0B10DiagnosticV6metricAA0B6MetricVSgvp` | KEEP |
| AgentUsage | Structure | `UsageDiagnosticKind` | `Sources/AgentUsage/AgentUsage.swift:215` | `s:10AgentUsage0B14DiagnosticKindV` | KEEP |
| AgentUsage | Operator | `UsageDiagnosticKind.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B14DiagnosticKindV` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.arithmeticOverflow` | `Sources/AgentUsage/AgentUsage.swift:228` | `s:10AgentUsage0B14DiagnosticKindV18arithmeticOverflowACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.decreasedValue` | `Sources/AgentUsage/AgentUsage.swift:225` | `s:10AgentUsage0B14DiagnosticKindV14decreasedValueACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.finalizedConflict` | `Sources/AgentUsage/AgentUsage.swift:227` | `s:10AgentUsage0B14DiagnosticKindV17finalizedConflictACvpZ` | KEEP |
| AgentUsage | Initializer | `UsageDiagnosticKind.init(from:)` | `-` | `s:10AgentUsage0B14DiagnosticKindV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.invalidIdentity` | `Sources/AgentUsage/AgentUsage.swift:222` | `s:10AgentUsage0B14DiagnosticKindV15invalidIdentityACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.invalidStatus` | `Sources/AgentUsage/AgentUsage.swift:223` | `s:10AgentUsage0B14DiagnosticKindV13invalidStatusACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.negativeValue` | `Sources/AgentUsage/AgentUsage.swift:224` | `s:10AgentUsage0B14DiagnosticKindV13negativeValueACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageDiagnosticKind.rawValue` | `Sources/AgentUsage/AgentUsage.swift:216` | `s:10AgentUsage0B14DiagnosticKindV8rawValueSSvp` | KEEP |
| AgentUsage | Type Property | `UsageDiagnosticKind.subsetExceedsTotal` | `Sources/AgentUsage/AgentUsage.swift:226` | `s:10AgentUsage0B14DiagnosticKindV18subsetExceedsTotalACvpZ` | KEEP |
| AgentUsage | Structure | `UsageFieldSummary` | `Sources/AgentUsage/AgentUsage.swift:66` | `s:10AgentUsage0B12FieldSummaryV` | KEEP |
| AgentUsage | Operator | `UsageFieldSummary.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B12FieldSummaryV` | KEEP |
| AgentUsage | Instance Property | `UsageFieldSummary.complete` | `Sources/AgentUsage/AgentUsage.swift:71` | `s:10AgentUsage0B12FieldSummaryV8completeSbvp` | KEEP |
| AgentUsage | Initializer | `UsageFieldSummary.init(from:)` | `-` | `s:10AgentUsage0B12FieldSummaryV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Instance Property | `UsageFieldSummary.missingCount` | `Sources/AgentUsage/AgentUsage.swift:69` | `s:10AgentUsage0B12FieldSummaryV12missingCountSivp` | KEEP |
| AgentUsage | Instance Property | `UsageFieldSummary.reportedCount` | `Sources/AgentUsage/AgentUsage.swift:68` | `s:10AgentUsage0B12FieldSummaryV13reportedCountSivp` | KEEP |
| AgentUsage | Instance Property | `UsageFieldSummary.reportedSubtotal` | `Sources/AgentUsage/AgentUsage.swift:67` | `s:10AgentUsage0B12FieldSummaryV16reportedSubtotalSiSgvp` | KEEP |
| AgentUsage | Class | `UsageLedger` | `Sources/AgentUsage/AgentUsage.swift:570` | `s:10AgentUsage0B6LedgerC` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.assertIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assertIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:10AgentUsage0B6LedgerC` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.assumeIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE14assumeIsolated_4file4lineqd__qd__xYiKXE_s12StaticStringVSutKs8SendableRd__lF::SYNTHESIZED::s:10AgentUsage0B6LedgerC` | KEEP |
| AgentUsage | Initializer | `UsageLedger.init()` | `Sources/AgentUsage/AgentUsage.swift:573` | `s:10AgentUsage0B6LedgerCACycfc` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.preconditionIsolated(_:file:line:)` | `-` | `s:ScA12_ConcurrencyE20preconditionIsolated_4file4lineySSyXK_s12StaticStringVSutF::SYNTHESIZED::s:10AgentUsage0B6LedgerC` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.record(_:)` | `Sources/AgentUsage/AgentUsage.swift:576` | `s:10AgentUsage0B6LedgerC6recordyAA0B15RecordingResultVAA0B11ObservationVF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.removeAll()` | `Sources/AgentUsage/AgentUsage.swift:600` | `s:10AgentUsage0B6LedgerC9removeAllyyF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.summary()` | `Sources/AgentUsage/AgentUsage.swift:580` | `s:10AgentUsage0B6LedgerC7summaryAA0B7SummaryVyF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.summary(identity:)` | `Sources/AgentUsage/AgentUsage.swift:584` | `s:10AgentUsage0B6LedgerC7summary8identityAA0B7SummaryVAA0B14RecordIdentityV_tF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.summary(model:)` | `Sources/AgentUsage/AgentUsage.swift:596` | `s:10AgentUsage0B6LedgerC7summary5modelAA0B7SummaryV0A6Models7ModelIDV_tF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.summary(sessionID:)` | `Sources/AgentUsage/AgentUsage.swift:592` | `s:10AgentUsage0B6LedgerC7summary9sessionIDAA0B7SummaryV10Foundation4UUIDV_tF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.summary(sessionID:runID:)` | `Sources/AgentUsage/AgentUsage.swift:588` | `s:10AgentUsage0B6LedgerC7summary9sessionID03runF0AA0B7SummaryV10Foundation4UUIDV_AKtF` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pqd_0_YKXEqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:10AgentUsage0B6LedgerC` | KEEP |
| AgentUsage | Instance Method | `UsageLedger.withSerialExecutor(_:)` | `-` | `s:ScA12_ConcurrencyE18withSerialExecutoryqd__qd__Scf_pYaqd_0_YKYCXEYaqd_0_YKs5ErrorRd_0_Ri_d__r0_lF::SYNTHESIZED::s:10AgentUsage0B6LedgerC` | KEEP |
| AgentUsage | Structure | `UsageMetric` | `Sources/AgentUsage/AgentUsage.swift:200` | `s:10AgentUsage0B6MetricV` | KEEP |
| AgentUsage | Operator | `UsageMetric.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B6MetricV` | KEEP |
| AgentUsage | Type Property | `UsageMetric.cachedInputTokens` | `Sources/AgentUsage/AgentUsage.swift:209` | `s:10AgentUsage0B6MetricV17cachedInputTokensACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageMetric.cacheWriteInputTokens` | `Sources/AgentUsage/AgentUsage.swift:210` | `s:10AgentUsage0B6MetricV21cacheWriteInputTokensACvpZ` | KEEP |
| AgentUsage | Initializer | `UsageMetric.init(from:)` | `-` | `s:10AgentUsage0B6MetricV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Type Property | `UsageMetric.inputTokens` | `Sources/AgentUsage/AgentUsage.swift:207` | `s:10AgentUsage0B6MetricV11inputTokensACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageMetric.outputTokens` | `Sources/AgentUsage/AgentUsage.swift:208` | `s:10AgentUsage0B6MetricV12outputTokensACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageMetric.rawValue` | `Sources/AgentUsage/AgentUsage.swift:201` | `s:10AgentUsage0B6MetricV8rawValueSSvp` | KEEP |
| AgentUsage | Type Property | `UsageMetric.reasoningTokens` | `Sources/AgentUsage/AgentUsage.swift:211` | `s:10AgentUsage0B6MetricV15reasoningTokensACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageMetric.totalTokens` | `Sources/AgentUsage/AgentUsage.swift:212` | `s:10AgentUsage0B6MetricV11totalTokensACvpZ` | KEEP |
| AgentUsage | Structure | `UsageObservation` | `Sources/AgentUsage/AgentUsage.swift:54` | `s:10AgentUsage0B11ObservationV` | KEEP |
| AgentUsage | Operator | `UsageObservation.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B11ObservationV` | KEEP |
| AgentUsage | Instance Property | `UsageObservation.identity` | `Sources/AgentUsage/AgentUsage.swift:55` | `s:10AgentUsage0B11ObservationV8identityAA0B14RecordIdentityVvp` | KEEP |
| AgentUsage | Initializer | `UsageObservation.init(from:)` | `-` | `s:10AgentUsage0B11ObservationV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Initializer | `UsageObservation.init(identity:usage:status:)` | `Sources/AgentUsage/AgentUsage.swift:59` | `s:10AgentUsage0B11ObservationV8identity5usage6statusAcA0B14RecordIdentityV_0A6Models05ModelB0VAA0bC6StatusVtcfc` | KEEP |
| AgentUsage | Instance Property | `UsageObservation.status` | `Sources/AgentUsage/AgentUsage.swift:57` | `s:10AgentUsage0B11ObservationV6statusAA0bC6StatusVvp` | KEEP |
| AgentUsage | Instance Property | `UsageObservation.usage` | `Sources/AgentUsage/AgentUsage.swift:56` | `s:10AgentUsage0B11ObservationV5usage0A6Models05ModelB0Vvp` | KEEP |
| AgentUsage | Structure | `UsageObservationStatus` | `Sources/AgentUsage/AgentUsage.swift:42` | `s:10AgentUsage0B17ObservationStatusV` | KEEP |
| AgentUsage | Operator | `UsageObservationStatus.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B17ObservationStatusV` | KEEP |
| AgentUsage | Type Property | `UsageObservationStatus.finalized` | `Sources/AgentUsage/AgentUsage.swift:50` | `s:10AgentUsage0B17ObservationStatusV9finalizedACvpZ` | KEEP |
| AgentUsage | Initializer | `UsageObservationStatus.init(from:)` | `-` | `s:10AgentUsage0B17ObservationStatusV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Type Property | `UsageObservationStatus.provisional` | `Sources/AgentUsage/AgentUsage.swift:49` | `s:10AgentUsage0B17ObservationStatusV11provisionalACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageObservationStatus.rawValue` | `Sources/AgentUsage/AgentUsage.swift:43` | `s:10AgentUsage0B17ObservationStatusV8rawValueSSvp` | KEEP |
| AgentUsage | Structure | `UsageRecordIdentity` | `Sources/AgentUsage/AgentUsage.swift:17` | `s:10AgentUsage0B14RecordIdentityV` | KEEP |
| AgentUsage | Operator | `UsageRecordIdentity.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B14RecordIdentityV` | KEEP |
| AgentUsage | Initializer | `UsageRecordIdentity.init(from:)` | `-` | `s:10AgentUsage0B14RecordIdentityV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Initializer | `UsageRecordIdentity.init(source:sessionID:runID:invocationID:providerResponseID:model:)` | `Sources/AgentUsage/AgentUsage.swift:25` | `s:10AgentUsage0B14RecordIdentityV6source9sessionID03runG0010invocationG0016providerResponseG05modelAcA0B6SourceV_10Foundation4UUIDVSgAOS2SSg0A6Models05ModelG0Vtcfc` | KEEP |
| AgentUsage | Instance Property | `UsageRecordIdentity.invocationID` | `Sources/AgentUsage/AgentUsage.swift:21` | `s:10AgentUsage0B14RecordIdentityV12invocationIDSSvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordIdentity.model` | `Sources/AgentUsage/AgentUsage.swift:23` | `s:10AgentUsage0B14RecordIdentityV5model0A6Models7ModelIDVvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordIdentity.providerResponseID` | `Sources/AgentUsage/AgentUsage.swift:22` | `s:10AgentUsage0B14RecordIdentityV18providerResponseIDSSSgvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordIdentity.runID` | `Sources/AgentUsage/AgentUsage.swift:20` | `s:10AgentUsage0B14RecordIdentityV5runID10Foundation4UUIDVSgvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordIdentity.sessionID` | `Sources/AgentUsage/AgentUsage.swift:19` | `s:10AgentUsage0B14RecordIdentityV9sessionID10Foundation4UUIDVSgvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordIdentity.source` | `Sources/AgentUsage/AgentUsage.swift:18` | `s:10AgentUsage0B14RecordIdentityV6sourceAA0B6SourceVvp` | KEEP |
| AgentUsage | Structure | `UsageRecordingDisposition` | `Sources/AgentUsage/AgentUsage.swift:243` | `s:10AgentUsage0B20RecordingDispositionV` | KEEP |
| AgentUsage | Operator | `UsageRecordingDisposition.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B20RecordingDispositionV` | KEEP |
| AgentUsage | Type Property | `UsageRecordingDisposition.duplicate` | `Sources/AgentUsage/AgentUsage.swift:252` | `s:10AgentUsage0B20RecordingDispositionV9duplicateACvpZ` | KEEP |
| AgentUsage | Initializer | `UsageRecordingDisposition.init(from:)` | `-` | `s:10AgentUsage0B20RecordingDispositionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Type Property | `UsageRecordingDisposition.inserted` | `Sources/AgentUsage/AgentUsage.swift:250` | `s:10AgentUsage0B20RecordingDispositionV8insertedACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageRecordingDisposition.rawValue` | `Sources/AgentUsage/AgentUsage.swift:244` | `s:10AgentUsage0B20RecordingDispositionV8rawValueSSvp` | KEEP |
| AgentUsage | Type Property | `UsageRecordingDisposition.rejected` | `Sources/AgentUsage/AgentUsage.swift:253` | `s:10AgentUsage0B20RecordingDispositionV8rejectedACvpZ` | KEEP |
| AgentUsage | Type Property | `UsageRecordingDisposition.updated` | `Sources/AgentUsage/AgentUsage.swift:251` | `s:10AgentUsage0B20RecordingDispositionV7updatedACvpZ` | KEEP |
| AgentUsage | Structure | `UsageRecordingResult` | `Sources/AgentUsage/AgentUsage.swift:256` | `s:10AgentUsage0B15RecordingResultV` | KEEP |
| AgentUsage | Operator | `UsageRecordingResult.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B15RecordingResultV` | KEEP |
| AgentUsage | Instance Property | `UsageRecordingResult.accepted` | `Sources/AgentUsage/AgentUsage.swift:260` | `s:10AgentUsage0B15RecordingResultV8acceptedSbvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordingResult.diagnostic` | `Sources/AgentUsage/AgentUsage.swift:258` | `s:10AgentUsage0B15RecordingResultV10diagnosticAA0B10DiagnosticVSgvp` | KEEP |
| AgentUsage | Instance Property | `UsageRecordingResult.disposition` | `Sources/AgentUsage/AgentUsage.swift:257` | `s:10AgentUsage0B15RecordingResultV11dispositionAA0bC11DispositionVvp` | KEEP |
| AgentUsage | Initializer | `UsageRecordingResult.init(from:)` | `-` | `s:10AgentUsage0B15RecordingResultV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Structure | `UsageSource` | `Sources/AgentUsage/AgentUsage.swift:5` | `s:10AgentUsage0B6SourceV` | KEEP |
| AgentUsage | Operator | `UsageSource.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B6SourceV` | KEEP |
| AgentUsage | Type Property | `UsageSource.decision` | `Sources/AgentUsage/AgentUsage.swift:13` | `s:10AgentUsage0B6SourceV8decisionACvpZ` | KEEP |
| AgentUsage | Initializer | `UsageSource.init(from:)` | `-` | `s:10AgentUsage0B6SourceV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Type Property | `UsageSource.modelResponse` | `Sources/AgentUsage/AgentUsage.swift:12` | `s:10AgentUsage0B6SourceV13modelResponseACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageSource.rawValue` | `Sources/AgentUsage/AgentUsage.swift:6` | `s:10AgentUsage0B6SourceV8rawValueSSvp` | KEEP |
| AgentUsage | Structure | `UsageSummary` | `Sources/AgentUsage/AgentUsage.swift:124` | `s:10AgentUsage0B7SummaryV` | KEEP |
| AgentUsage | Operator | `UsageSummary.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B7SummaryV` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.allResponsesFinalized` | `Sources/AgentUsage/AgentUsage.swift:141` | `s:10AgentUsage0B7SummaryV21allResponsesFinalizedSbvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.cachedInputTokens` | `Sources/AgentUsage/AgentUsage.swift:136` | `s:10AgentUsage0B7SummaryV17cachedInputTokensAA0b5FieldC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.cacheWriteInputTokens` | `Sources/AgentUsage/AgentUsage.swift:137` | `s:10AgentUsage0B7SummaryV21cacheWriteInputTokensAA0b5FieldC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.coverage` | `Sources/AgentUsage/AgentUsage.swift:132` | `s:10AgentUsage0B7SummaryV8coverageAA0B8CoverageVvp` | KEEP |
| AgentUsage | Type Property | `UsageSummary.empty` | `Sources/AgentUsage/AgentUsage.swift:156` | `s:10AgentUsage0B7SummaryV5emptyACvpZ` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.finalizedResponseCount` | `Sources/AgentUsage/AgentUsage.swift:126` | `s:10AgentUsage0B7SummaryV22finalizedResponseCountSivp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.finalizedUsage` | `Sources/AgentUsage/AgentUsage.swift:129` | `s:10AgentUsage0B7SummaryV09finalizedB0AA0b5TokenC0Vvp` | KEEP |
| AgentUsage | Initializer | `UsageSummary.init(from:)` | `-` | `s:10AgentUsage0B7SummaryV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.inputTokens` | `Sources/AgentUsage/AgentUsage.swift:134` | `s:10AgentUsage0B7SummaryV11inputTokensAA0b5FieldC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.observedResponseCount` | `Sources/AgentUsage/AgentUsage.swift:125` | `s:10AgentUsage0B7SummaryV21observedResponseCountSivp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.observedUsage` | `Sources/AgentUsage/AgentUsage.swift:128` | `s:10AgentUsage0B7SummaryV08observedB0AA0b5TokenC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.outputTokens` | `Sources/AgentUsage/AgentUsage.swift:135` | `s:10AgentUsage0B7SummaryV12outputTokensAA0b5FieldC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.provisionalResponseCount` | `Sources/AgentUsage/AgentUsage.swift:127` | `s:10AgentUsage0B7SummaryV24provisionalResponseCountSivp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.provisionalUsage` | `Sources/AgentUsage/AgentUsage.swift:130` | `s:10AgentUsage0B7SummaryV011provisionalB0AA0b5TokenC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.reasoningTokens` | `Sources/AgentUsage/AgentUsage.swift:138` | `s:10AgentUsage0B7SummaryV15reasoningTokensAA0b5FieldC0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.reportedUsage` | `Sources/AgentUsage/AgentUsage.swift:146` | `s:10AgentUsage0B7SummaryV08reportedB00A6Models05ModelB0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.sources` | `Sources/AgentUsage/AgentUsage.swift:131` | `s:10AgentUsage0B7SummaryV7sourcesShyAA0B6SourceVGvp` | KEEP |
| AgentUsage | Instance Property | `UsageSummary.totalTokens` | `Sources/AgentUsage/AgentUsage.swift:139` | `s:10AgentUsage0B7SummaryV11totalTokensSiSgvp` | KEEP |
| AgentUsage | Structure | `UsageTokenSummary` | `Sources/AgentUsage/AgentUsage.swift:83` | `s:10AgentUsage0B12TokenSummaryV` | KEEP |
| AgentUsage | Operator | `UsageTokenSummary.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:10AgentUsage0B12TokenSummaryV` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.cachedInputTokens` | `Sources/AgentUsage/AgentUsage.swift:87` | `s:10AgentUsage0B12TokenSummaryV17cachedInputTokensAA0b5FieldD0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.cacheWriteInputTokens` | `Sources/AgentUsage/AgentUsage.swift:88` | `s:10AgentUsage0B12TokenSummaryV21cacheWriteInputTokensAA0b5FieldD0Vvp` | KEEP |
| AgentUsage | Initializer | `UsageTokenSummary.init(from:)` | `-` | `s:10AgentUsage0B12TokenSummaryV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.inputTokens` | `Sources/AgentUsage/AgentUsage.swift:85` | `s:10AgentUsage0B12TokenSummaryV11inputTokensAA0b5FieldD0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.outputTokens` | `Sources/AgentUsage/AgentUsage.swift:86` | `s:10AgentUsage0B12TokenSummaryV12outputTokensAA0b5FieldD0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.reasoningTokens` | `Sources/AgentUsage/AgentUsage.swift:89` | `s:10AgentUsage0B12TokenSummaryV15reasoningTokensAA0b5FieldD0Vvp` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.sampleCount` | `Sources/AgentUsage/AgentUsage.swift:84` | `s:10AgentUsage0B12TokenSummaryV11sampleCountSivp` | KEEP |
| AgentUsage | Instance Property | `UsageTokenSummary.totalTokens` | `Sources/AgentUsage/AgentUsage.swift:90` | `s:10AgentUsage0B12TokenSummaryV11totalTokensSiSgvp` | KEEP |
