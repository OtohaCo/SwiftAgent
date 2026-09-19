# SAI-055 Public API Additions

last-verified: 2026-09-19

Generated from Swift 6.4 public symbol graphs for the final SAI-055 working tree.
These 138 precise identifiers are additive to the 1,013-symbol provider
remediation baseline at `d139e5d74bdb746a28b8fdf3a44c593502b44fc6`.
No previously public precise identifier is removed.

`AgentDecisions` contributes 131 symbols and 15 top-level types.
`AgentJevProvider` contributes 7 symbols and 1 top-level type. All are `KEEP`:
they comprise the vendor-neutral Host contract or the public Jev adapter.
Jev wire DTOs, HTTP transport, response decoder, endpoint validation, and
sanitization helpers remain internal.

| Module | Kind | Symbol path | Source | Precise identifier | Decision |
| --- | --- | --- | --- | --- | --- |
| AgentDecisions | Structure | `ChoiceDecision` | `Sources/AgentDecisions/DecisionModels.swift:207` | `s:14AgentDecisions14ChoiceDecisionV` | KEEP |
| AgentDecisions | Operator | `ChoiceDecision.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions14ChoiceDecisionV` | KEEP |
| AgentDecisions | Instance Property | `ChoiceDecision.confidence` | `Sources/AgentDecisions/DecisionModels.swift:211` | `s:14AgentDecisions14ChoiceDecisionV10confidenceSdvp` | KEEP |
| AgentDecisions | Initializer | `ChoiceDecision.init(from:)` | `-` | `s:14AgentDecisions14ChoiceDecisionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `ChoiceDecision.init(selected:confidence:probabilities:)` | `Sources/AgentDecisions/DecisionModels.swift:215` | `s:14AgentDecisions14ChoiceDecisionV8selected10confidence13probabilitiesACSS_SdSayAA0dC11ProbabilityVGtcfc` | KEEP |
| AgentDecisions | Instance Property | `ChoiceDecision.probabilities` | `Sources/AgentDecisions/DecisionModels.swift:213` | `s:14AgentDecisions14ChoiceDecisionV13probabilitiesSayAA0dC11ProbabilityVGvp` | KEEP |
| AgentDecisions | Instance Property | `ChoiceDecision.selected` | `Sources/AgentDecisions/DecisionModels.swift:209` | `s:14AgentDecisions14ChoiceDecisionV8selectedSSvp` | KEEP |
| AgentDecisions | Structure | `ChoiceQuestion` | `Sources/AgentDecisions/DecisionModels.swift:74` | `s:14AgentDecisions14ChoiceQuestionV` | KEEP |
| AgentDecisions | Operator | `ChoiceQuestion.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions14ChoiceQuestionV` | KEEP |
| AgentDecisions | Instance Property | `ChoiceQuestion.criteria` | `Sources/AgentDecisions/DecisionModels.swift:78` | `s:14AgentDecisions14ChoiceQuestionV8criteriaSayAA08DecisionC9CriterionVGvp` | KEEP |
| AgentDecisions | Initializer | `ChoiceQuestion.init(from:)` | `Sources/AgentDecisions/DecisionModels.swift:102` | `s:14AgentDecisions14ChoiceQuestionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `ChoiceQuestion.init(instructions:criteria:)` | `Sources/AgentDecisions/DecisionModels.swift:80` | `s:14AgentDecisions14ChoiceQuestionV12instructions8criteriaAC0A6Models9JSONValueOSg_SayAA08DecisionC9CriterionVGtKcfc` | KEEP |
| AgentDecisions | Instance Property | `ChoiceQuestion.instructions` | `Sources/AgentDecisions/DecisionModels.swift:76` | `s:14AgentDecisions14ChoiceQuestionV12instructions0A6Models9JSONValueOSgvp` | KEEP |
| AgentDecisions | Structure | `DecisionChoiceCriterion` | `Sources/AgentDecisions/DecisionModels.swift:61` | `s:14AgentDecisions23DecisionChoiceCriterionV` | KEEP |
| AgentDecisions | Operator | `DecisionChoiceCriterion.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions23DecisionChoiceCriterionV` | KEEP |
| AgentDecisions | Instance Property | `DecisionChoiceCriterion.description` | `Sources/AgentDecisions/DecisionModels.swift:65` | `s:14AgentDecisions23DecisionChoiceCriterionV11description0A6Models9JSONValueOSgvp` | KEEP |
| AgentDecisions | Initializer | `DecisionChoiceCriterion.init(from:)` | `-` | `s:14AgentDecisions23DecisionChoiceCriterionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionChoiceCriterion.init(name:description:)` | `Sources/AgentDecisions/DecisionModels.swift:67` | `s:14AgentDecisions23DecisionChoiceCriterionV4name11descriptionACSS_0A6Models9JSONValueOSgtcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionChoiceCriterion.name` | `Sources/AgentDecisions/DecisionModels.swift:63` | `s:14AgentDecisions23DecisionChoiceCriterionV4nameSSvp` | KEEP |
| AgentDecisions | Structure | `DecisionChoiceProbability` | `Sources/AgentDecisions/DecisionModels.swift:194` | `s:14AgentDecisions25DecisionChoiceProbabilityV` | KEEP |
| AgentDecisions | Operator | `DecisionChoiceProbability.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions25DecisionChoiceProbabilityV` | KEEP |
| AgentDecisions | Initializer | `DecisionChoiceProbability.init(from:)` | `-` | `s:14AgentDecisions25DecisionChoiceProbabilityV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionChoiceProbability.init(name:probability:)` | `Sources/AgentDecisions/DecisionModels.swift:200` | `s:14AgentDecisions25DecisionChoiceProbabilityV4name11probabilityACSS_Sdtcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionChoiceProbability.name` | `Sources/AgentDecisions/DecisionModels.swift:196` | `s:14AgentDecisions25DecisionChoiceProbabilityV4nameSSvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionChoiceProbability.probability` | `Sources/AgentDecisions/DecisionModels.swift:198` | `s:14AgentDecisions25DecisionChoiceProbabilityV11probabilitySdvp` | KEEP |
| AgentDecisions | Protocol | `DecisionProvider` | `Sources/AgentDecisions/DecisionProvider.swift:4` | `s:14AgentDecisions16DecisionProviderP` | KEEP |
| AgentDecisions | Instance Method | `DecisionProvider.decide(_:)` | `Sources/AgentDecisions/DecisionProvider.swift:8` | `s:14AgentDecisions16DecisionProviderP6decideyAA0C8ResponseVAA0C7RequestVYaKF` | KEEP |
| AgentDecisions | Instance Property | `DecisionProvider.descriptor` | `Sources/AgentDecisions/DecisionProvider.swift:6` | `s:14AgentDecisions16DecisionProviderP10descriptorAA0cD10DescriptorVvp` | KEEP |
| AgentDecisions | Structure | `DecisionProviderDescriptor` | `Sources/AgentDecisions/DecisionProvider.swift:12` | `s:14AgentDecisions26DecisionProviderDescriptorV` | KEEP |
| AgentDecisions | Operator | `DecisionProviderDescriptor.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions26DecisionProviderDescriptorV` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderDescriptor.id` | `Sources/AgentDecisions/DecisionProvider.swift:14` | `s:14AgentDecisions26DecisionProviderDescriptorV2idSSvp` | KEEP |
| AgentDecisions | Initializer | `DecisionProviderDescriptor.init(from:)` | `-` | `s:14AgentDecisions26DecisionProviderDescriptorV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionProviderDescriptor.init(id:)` | `Sources/AgentDecisions/DecisionProvider.swift:15` | `s:14AgentDecisions26DecisionProviderDescriptorV2idACSS_tcfc` | KEEP |
| AgentDecisions | Structure | `DecisionProviderError` | `Sources/AgentDecisions/DecisionProvider.swift:20` | `s:14AgentDecisions21DecisionProviderErrorV` | KEEP |
| AgentDecisions | Operator | `DecisionProviderError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions21DecisionProviderErrorV` | KEEP |
| AgentDecisions | Initializer | `DecisionProviderError.init(kind:message:retryAfter:requestID:)` | `Sources/AgentDecisions/DecisionProvider.swift:55` | `s:14AgentDecisions21DecisionProviderErrorV4kind7message10retryAfter9requestIDA2C4KindV_SSs8DurationVSgSSSgtcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.kind` | `Sources/AgentDecisions/DecisionProvider.swift:47` | `s:14AgentDecisions21DecisionProviderErrorV4kindAC4KindVvp` | KEEP |
| AgentDecisions | Structure | `DecisionProviderError.Kind` | `Sources/AgentDecisions/DecisionProvider.swift:22` | `s:14AgentDecisions21DecisionProviderErrorV4KindV` | KEEP |
| AgentDecisions | Operator | `DecisionProviderError.Kind.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions21DecisionProviderErrorV4KindV` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.authentication` | `Sources/AgentDecisions/DecisionProvider.swift:27` | `s:14AgentDecisions21DecisionProviderErrorV4KindV14authenticationAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.deadlineExceeded` | `Sources/AgentDecisions/DecisionProvider.swift:34` | `s:14AgentDecisions21DecisionProviderErrorV4KindV16deadlineExceededAEvpZ` | KEEP |
| AgentDecisions | Instance Method | `DecisionProviderError.Kind.encode(to:)` | `Sources/AgentDecisions/DecisionProvider.swift:40` | `s:14AgentDecisions21DecisionProviderErrorV4KindV6encode2toys7Encoder_p_tKF` | KEEP |
| AgentDecisions | Instance Method | `DecisionProviderError.Kind.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:14AgentDecisions21DecisionProviderErrorV4KindV` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.Kind.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:14AgentDecisions21DecisionProviderErrorV4KindV` | KEEP |
| AgentDecisions | Initializer | `DecisionProviderError.Kind.init(from:)` | `Sources/AgentDecisions/DecisionProvider.swift:36` | `s:14AgentDecisions21DecisionProviderErrorV4KindV4fromAEs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionProviderError.Kind.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:14AgentDecisions21DecisionProviderErrorV4KindV` | KEEP |
| AgentDecisions | Initializer | `DecisionProviderError.Kind.init(rawValue:)` | `Sources/AgentDecisions/DecisionProvider.swift:24` | `s:14AgentDecisions21DecisionProviderErrorV4KindV8rawValueAESS_tcfc` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.invalidConfiguration` | `Sources/AgentDecisions/DecisionProvider.swift:26` | `s:14AgentDecisions21DecisionProviderErrorV4KindV20invalidConfigurationAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.invalidRequest` | `Sources/AgentDecisions/DecisionProvider.swift:29` | `s:14AgentDecisions21DecisionProviderErrorV4KindV14invalidRequestAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.invalidResponse` | `Sources/AgentDecisions/DecisionProvider.swift:33` | `s:14AgentDecisions21DecisionProviderErrorV4KindV15invalidResponseAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.permissionDenied` | `Sources/AgentDecisions/DecisionProvider.swift:28` | `s:14AgentDecisions21DecisionProviderErrorV4KindV16permissionDeniedAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.rateLimited` | `Sources/AgentDecisions/DecisionProvider.swift:30` | `s:14AgentDecisions21DecisionProviderErrorV4KindV11rateLimitedAEvpZ` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.Kind.rawValue` | `Sources/AgentDecisions/DecisionProvider.swift:23` | `s:14AgentDecisions21DecisionProviderErrorV4KindV8rawValueSSvp` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.transport` | `Sources/AgentDecisions/DecisionProvider.swift:32` | `s:14AgentDecisions21DecisionProviderErrorV4KindV9transportAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionProviderError.Kind.unavailable` | `Sources/AgentDecisions/DecisionProvider.swift:31` | `s:14AgentDecisions21DecisionProviderErrorV4KindV11unavailableAEvpZ` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:14AgentDecisions21DecisionProviderErrorV` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.message` | `Sources/AgentDecisions/DecisionProvider.swift:49` | `s:14AgentDecisions21DecisionProviderErrorV7messageSSvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.requestID` | `Sources/AgentDecisions/DecisionProvider.swift:53` | `s:14AgentDecisions21DecisionProviderErrorV9requestIDSSSgvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionProviderError.retryAfter` | `Sources/AgentDecisions/DecisionProvider.swift:51` | `s:14AgentDecisions21DecisionProviderErrorV10retryAfters8DurationVSgvp` | KEEP |
| AgentDecisions | Structure | `DecisionRequest` | `Sources/AgentDecisions/DecisionModels.swift:138` | `s:14AgentDecisions15DecisionRequestV` | KEEP |
| AgentDecisions | Operator | `DecisionRequest.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions15DecisionRequestV` | KEEP |
| AgentDecisions | Instance Property | `DecisionRequest.choices` | `Sources/AgentDecisions/DecisionModels.swift:144` | `s:14AgentDecisions15DecisionRequestV7choicesSDySSAA14ChoiceQuestionVGvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionRequest.deadline` | `Sources/AgentDecisions/DecisionModels.swift:148` | `s:14AgentDecisions15DecisionRequestV8deadline12_Concurrency15ContinuousClockV7InstantVSgvp` | KEEP |
| AgentDecisions | Initializer | `DecisionRequest.init(state:nouls:choices:scores:deadline:)` | `Sources/AgentDecisions/DecisionModels.swift:153` | `s:14AgentDecisions15DecisionRequestV5state5nouls7choices6scores8deadlineAC0A6Models9JSONValueO_SDySSAA12NoulQuestionVGSDySSAA06ChoiceM0VGSDySSAA05ScoreM0VG12_Concurrency15ContinuousClockV7InstantVSgtKcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionRequest.nouls` | `Sources/AgentDecisions/DecisionModels.swift:142` | `s:14AgentDecisions15DecisionRequestV5noulsSDySSAA12NoulQuestionVGvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionRequest.questionCount` | `Sources/AgentDecisions/DecisionModels.swift:151` | `s:14AgentDecisions15DecisionRequestV13questionCountSivp` | KEEP |
| AgentDecisions | Instance Property | `DecisionRequest.scores` | `Sources/AgentDecisions/DecisionModels.swift:146` | `s:14AgentDecisions15DecisionRequestV6scoresSDySSAA13ScoreQuestionVGvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionRequest.state` | `Sources/AgentDecisions/DecisionModels.swift:140` | `s:14AgentDecisions15DecisionRequestV5state0A6Models9JSONValueOvp` | KEEP |
| AgentDecisions | Structure | `DecisionResponse` | `Sources/AgentDecisions/DecisionModels.swift:255` | `s:14AgentDecisions16DecisionResponseV` | KEEP |
| AgentDecisions | Operator | `DecisionResponse.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions16DecisionResponseV` | KEEP |
| AgentDecisions | Instance Property | `DecisionResponse.choices` | `Sources/AgentDecisions/DecisionModels.swift:261` | `s:14AgentDecisions16DecisionResponseV7choicesSDySSAA06ChoiceC0VGvp` | KEEP |
| AgentDecisions | Initializer | `DecisionResponse.init(from:)` | `-` | `s:14AgentDecisions16DecisionResponseV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionResponse.init(model:nouls:choices:scores:usage:)` | `Sources/AgentDecisions/DecisionModels.swift:267` | `s:14AgentDecisions16DecisionResponseV5model5nouls7choices6scores5usageACSS_SDySSAA04NoulC0VGSDySSAA06ChoiceC0VGSDySSAA05ScoreC0VGAA0C5UsageVSgtcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionResponse.model` | `Sources/AgentDecisions/DecisionModels.swift:257` | `s:14AgentDecisions16DecisionResponseV5modelSSvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionResponse.nouls` | `Sources/AgentDecisions/DecisionModels.swift:259` | `s:14AgentDecisions16DecisionResponseV5noulsSDySSAA04NoulC0VGvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionResponse.scores` | `Sources/AgentDecisions/DecisionModels.swift:263` | `s:14AgentDecisions16DecisionResponseV6scoresSDySSAA05ScoreC0VGvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionResponse.usage` | `Sources/AgentDecisions/DecisionModels.swift:265` | `s:14AgentDecisions16DecisionResponseV5usageAA0C5UsageVSgvp` | KEEP |
| AgentDecisions | Structure | `DecisionUsage` | `Sources/AgentDecisions/DecisionModels.swift:242` | `s:14AgentDecisions13DecisionUsageV` | KEEP |
| AgentDecisions | Operator | `DecisionUsage.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions13DecisionUsageV` | KEEP |
| AgentDecisions | Initializer | `DecisionUsage.init(from:)` | `-` | `s:14AgentDecisions13DecisionUsageV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionUsage.init(inputTokens:outputTokens:)` | `Sources/AgentDecisions/DecisionModels.swift:248` | `s:14AgentDecisions13DecisionUsageV11inputTokens06outputF0ACSi_Sitcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionUsage.inputTokens` | `Sources/AgentDecisions/DecisionModels.swift:244` | `s:14AgentDecisions13DecisionUsageV11inputTokensSivp` | KEEP |
| AgentDecisions | Instance Property | `DecisionUsage.outputTokens` | `Sources/AgentDecisions/DecisionModels.swift:246` | `s:14AgentDecisions13DecisionUsageV12outputTokensSivp` | KEEP |
| AgentDecisions | Structure | `DecisionValidationError` | `Sources/AgentDecisions/DecisionModels.swift:5` | `s:14AgentDecisions23DecisionValidationErrorV` | KEEP |
| AgentDecisions | Operator | `DecisionValidationError.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions23DecisionValidationErrorV` | KEEP |
| AgentDecisions | Instance Property | `DecisionValidationError.field` | `Sources/AgentDecisions/DecisionModels.swift:32` | `s:14AgentDecisions23DecisionValidationErrorV5fieldSSSgvp` | KEEP |
| AgentDecisions | Initializer | `DecisionValidationError.init(kind:field:)` | `Sources/AgentDecisions/DecisionModels.swift:34` | `s:14AgentDecisions23DecisionValidationErrorV4kind5fieldA2C4KindV_SSSgtcfc` | KEEP |
| AgentDecisions | Instance Property | `DecisionValidationError.kind` | `Sources/AgentDecisions/DecisionModels.swift:30` | `s:14AgentDecisions23DecisionValidationErrorV4kindAC4KindVvp` | KEEP |
| AgentDecisions | Structure | `DecisionValidationError.Kind` | `Sources/AgentDecisions/DecisionModels.swift:7` | `s:14AgentDecisions23DecisionValidationErrorV4KindV` | KEEP |
| AgentDecisions | Operator | `DecisionValidationError.Kind.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions23DecisionValidationErrorV4KindV` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.duplicateChoiceName` | `Sources/AgentDecisions/DecisionModels.swift:16` | `s:14AgentDecisions23DecisionValidationErrorV4KindV19duplicateChoiceNameAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.duplicateQuestionName` | `Sources/AgentDecisions/DecisionModels.swift:13` | `s:14AgentDecisions23DecisionValidationErrorV4KindV21duplicateQuestionNameAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.emptyChoiceCriteria` | `Sources/AgentDecisions/DecisionModels.swift:14` | `s:14AgentDecisions23DecisionValidationErrorV4KindV19emptyChoiceCriteriaAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.emptyQuestions` | `Sources/AgentDecisions/DecisionModels.swift:11` | `s:14AgentDecisions23DecisionValidationErrorV4KindV14emptyQuestionsAEvpZ` | KEEP |
| AgentDecisions | Instance Method | `DecisionValidationError.Kind.encode(to:)` | `Sources/AgentDecisions/DecisionModels.swift:23` | `s:14AgentDecisions23DecisionValidationErrorV4KindV6encode2toys7Encoder_p_tKF` | KEEP |
| AgentDecisions | Instance Method | `DecisionValidationError.Kind.hash(into:)` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE4hash4intoys6HasherVz_tF::SYNTHESIZED::s:14AgentDecisions23DecisionValidationErrorV4KindV` | KEEP |
| AgentDecisions | Instance Property | `DecisionValidationError.Kind.hashValue` | `-` | `s:SYsSHRzSH8RawValueSYRpzrlE04hashB0Sivp::SYNTHESIZED::s:14AgentDecisions23DecisionValidationErrorV4KindV` | KEEP |
| AgentDecisions | Initializer | `DecisionValidationError.Kind.init(from:)` | `Sources/AgentDecisions/DecisionModels.swift:19` | `s:14AgentDecisions23DecisionValidationErrorV4KindV4fromAEs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `DecisionValidationError.Kind.init(from:)` | `-` | `s:SYsSeRzSS8RawValueSYRtzrlE4fromxs7Decoder_p_tKcfc::SYNTHESIZED::s:14AgentDecisions23DecisionValidationErrorV4KindV` | KEEP |
| AgentDecisions | Initializer | `DecisionValidationError.Kind.init(rawValue:)` | `Sources/AgentDecisions/DecisionModels.swift:9` | `s:14AgentDecisions23DecisionValidationErrorV4KindV8rawValueAESS_tcfc` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.insufficientScoreCriteria` | `Sources/AgentDecisions/DecisionModels.swift:17` | `s:14AgentDecisions23DecisionValidationErrorV4KindV25insufficientScoreCriteriaAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.invalidChoiceName` | `Sources/AgentDecisions/DecisionModels.swift:15` | `s:14AgentDecisions23DecisionValidationErrorV4KindV17invalidChoiceNameAEvpZ` | KEEP |
| AgentDecisions | Type Property | `DecisionValidationError.Kind.invalidQuestionName` | `Sources/AgentDecisions/DecisionModels.swift:12` | `s:14AgentDecisions23DecisionValidationErrorV4KindV19invalidQuestionNameAEvpZ` | KEEP |
| AgentDecisions | Instance Property | `DecisionValidationError.Kind.rawValue` | `Sources/AgentDecisions/DecisionModels.swift:8` | `s:14AgentDecisions23DecisionValidationErrorV4KindV8rawValueSSvp` | KEEP |
| AgentDecisions | Instance Property | `DecisionValidationError.localizedDescription` | `-` | `s:s5ErrorP10FoundationE20localizedDescriptionSSvp::SYNTHESIZED::s:14AgentDecisions23DecisionValidationErrorV` | KEEP |
| AgentDecisions | Structure | `NoulDecision` | `Sources/AgentDecisions/DecisionModels.swift:187` | `s:14AgentDecisions12NoulDecisionV` | KEEP |
| AgentDecisions | Operator | `NoulDecision.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions12NoulDecisionV` | KEEP |
| AgentDecisions | Initializer | `NoulDecision.init(from:)` | `-` | `s:14AgentDecisions12NoulDecisionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `NoulDecision.init(probability:)` | `Sources/AgentDecisions/DecisionModels.swift:190` | `s:14AgentDecisions12NoulDecisionV11probabilityACSd_tcfc` | KEEP |
| AgentDecisions | Instance Property | `NoulDecision.probability` | `Sources/AgentDecisions/DecisionModels.swift:189` | `s:14AgentDecisions12NoulDecisionV11probabilitySdvp` | KEEP |
| AgentDecisions | Structure | `NoulQuestion` | `Sources/AgentDecisions/DecisionModels.swift:41` | `s:14AgentDecisions12NoulQuestionV` | KEEP |
| AgentDecisions | Operator | `NoulQuestion.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions12NoulQuestionV` | KEEP |
| AgentDecisions | Instance Property | `NoulQuestion.falseCriteria` | `Sources/AgentDecisions/DecisionModels.swift:47` | `s:14AgentDecisions12NoulQuestionV13falseCriteria0A6Models9JSONValueOSgvp` | KEEP |
| AgentDecisions | Initializer | `NoulQuestion.init(from:)` | `-` | `s:14AgentDecisions12NoulQuestionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `NoulQuestion.init(instructions:trueCriteria:falseCriteria:)` | `Sources/AgentDecisions/DecisionModels.swift:49` | `s:14AgentDecisions12NoulQuestionV12instructions12trueCriteria05falseG0AC0A6Models9JSONValueOSg_A2Jtcfc` | KEEP |
| AgentDecisions | Instance Property | `NoulQuestion.instructions` | `Sources/AgentDecisions/DecisionModels.swift:43` | `s:14AgentDecisions12NoulQuestionV12instructions0A6Models9JSONValueOSgvp` | KEEP |
| AgentDecisions | Instance Property | `NoulQuestion.trueCriteria` | `Sources/AgentDecisions/DecisionModels.swift:45` | `s:14AgentDecisions12NoulQuestionV12trueCriteria0A6Models9JSONValueOSgvp` | KEEP |
| AgentDecisions | Structure | `ScoreDecision` | `Sources/AgentDecisions/DecisionModels.swift:223` | `s:14AgentDecisions13ScoreDecisionV` | KEEP |
| AgentDecisions | Operator | `ScoreDecision.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions13ScoreDecisionV` | KEEP |
| AgentDecisions | Instance Property | `ScoreDecision.confidence` | `Sources/AgentDecisions/DecisionModels.swift:227` | `s:14AgentDecisions13ScoreDecisionV10confidenceSdvp` | KEEP |
| AgentDecisions | Initializer | `ScoreDecision.init(from:)` | `-` | `s:14AgentDecisions13ScoreDecisionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `ScoreDecision.init(score:confidence:legend:probabilities:)` | `Sources/AgentDecisions/DecisionModels.swift:233` | `s:14AgentDecisions13ScoreDecisionV5score10confidence6legend13probabilitiesACSd_SdSay0A6Models9JSONValueOGSaySdGtcfc` | KEEP |
| AgentDecisions | Instance Property | `ScoreDecision.legend` | `Sources/AgentDecisions/DecisionModels.swift:229` | `s:14AgentDecisions13ScoreDecisionV6legendSay0A6Models9JSONValueOGvp` | KEEP |
| AgentDecisions | Instance Property | `ScoreDecision.probabilities` | `Sources/AgentDecisions/DecisionModels.swift:231` | `s:14AgentDecisions13ScoreDecisionV13probabilitiesSaySdGvp` | KEEP |
| AgentDecisions | Instance Property | `ScoreDecision.score` | `Sources/AgentDecisions/DecisionModels.swift:225` | `s:14AgentDecisions13ScoreDecisionV5scoreSdvp` | KEEP |
| AgentDecisions | Structure | `ScoreQuestion` | `Sources/AgentDecisions/DecisionModels.swift:112` | `s:14AgentDecisions13ScoreQuestionV` | KEEP |
| AgentDecisions | Operator | `ScoreQuestion.!=(_:_:)` | `-` | `s:SQsRi_zRi0_zrlE2neoiySbx_xtFZ::SYNTHESIZED::s:14AgentDecisions13ScoreQuestionV` | KEEP |
| AgentDecisions | Instance Property | `ScoreQuestion.criteria` | `Sources/AgentDecisions/DecisionModels.swift:116` | `s:14AgentDecisions13ScoreQuestionV8criteriaSay0A6Models9JSONValueOGvp` | KEEP |
| AgentDecisions | Initializer | `ScoreQuestion.init(from:)` | `Sources/AgentDecisions/DecisionModels.swift:128` | `s:14AgentDecisions13ScoreQuestionV4fromACs7Decoder_p_tKcfc` | KEEP |
| AgentDecisions | Initializer | `ScoreQuestion.init(instructions:criteria:)` | `Sources/AgentDecisions/DecisionModels.swift:118` | `s:14AgentDecisions13ScoreQuestionV12instructions8criteriaAC0A6Models9JSONValueOSg_SayAHGtKcfc` | KEEP |
| AgentDecisions | Instance Property | `ScoreQuestion.instructions` | `Sources/AgentDecisions/DecisionModels.swift:114` | `s:14AgentDecisions13ScoreQuestionV12instructions0A6Models9JSONValueOSgvp` | KEEP |
| AgentJevProvider | Structure | `JevDecisionProvider` | `Sources/AgentJevProvider/JevDecisionProvider.swift:10` | `s:16AgentJevProvider0b8DecisionC0V` | KEEP |
| AgentJevProvider | Instance Property | `JevDecisionProvider.customMirror` | `Sources/AgentJevProvider/JevDecisionProvider.swift:22` | `s:16AgentJevProvider0b8DecisionC0V12customMirrors0F0Vvp` | KEEP |
| AgentJevProvider | Instance Property | `JevDecisionProvider.debugDescription` | `Sources/AgentJevProvider/JevDecisionProvider.swift:21` | `s:16AgentJevProvider0b8DecisionC0V16debugDescriptionSSvp` | KEEP |
| AgentJevProvider | Instance Method | `JevDecisionProvider.decide(_:)` | `Sources/AgentJevProvider/JevDecisionProvider.swift:85` | `s:16AgentJevProvider0b8DecisionC0V6decidey0A9Decisions0D8ResponseVAE0D7RequestVYaKF` | KEEP |
| AgentJevProvider | Instance Property | `JevDecisionProvider.description` | `Sources/AgentJevProvider/JevDecisionProvider.swift:20` | `s:16AgentJevProvider0b8DecisionC0V11descriptionSSvp` | KEEP |
| AgentJevProvider | Instance Property | `JevDecisionProvider.descriptor` | `Sources/AgentJevProvider/JevDecisionProvider.swift:12` | `s:16AgentJevProvider0b8DecisionC0V10descriptor0A9Decisions0dC10DescriptorVvp` | KEEP |
| AgentJevProvider | Initializer | `JevDecisionProvider.init(apiKey:endpoint:model:requestTimeout:)` | `Sources/AgentJevProvider/JevDecisionProvider.swift:31` | `s:16AgentJevProvider0b8DecisionC0V6apiKey8endpoint5model14requestTimeoutACSS_10Foundation3URLVSgSSs8DurationVtKcfc` | KEEP |
