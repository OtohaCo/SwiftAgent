# RC4 受控纠错测试与测量记录

本记录针对 SwiftAgent `1.0.0-rc.4` 的 Session/Run、Evidence、mutation admission 和 Journal。来源是 Tingting 的 `SAI-077-cloud-music-conversation-timeout.md` 在 Host 提交 `c8c1973e27f82d0d962ed8e45ba1905215d64755` 中的验收记录：错误引用被 SDK 拒绝后，Host 当前有受限的二次搜索补救。此处只测 SDK，不调用 Host、MusicKit、播放器或付费 Provider；不改变 Host 依赖和补救。

## 基线与运行方式

RC4 tag 对象 `ff7ab55033857a0b0fe7c03dc6fb41c558c141d8` 解引用到提交 `3f01599ef3d0923659226025a7d34d4144ed1800`。开始时 main 也位于该提交，tree 为 `9aa6e6828e01aa4d7b1b6ac3689fa89ac6a26989`，工作区干净。本轮在 `codex/bounded-replanning-tests` 上添加测试；没有移动 tag。使用 Swift 6.4、公开包外 `Examples/ExternalClient` 和仓库原有测试套件。基线没有差异，因此无须另设 RC4 对照 worktree。

常规测试随 `bash Scripts/ci-macos.sh` 和 Linux `bash Scripts/ci-linux.sh` 运行。局部命令：

```sh
swift test --package-path Examples/ExternalClient --filter BoundedReplanningBaselineTests --disable-sandbox --no-parallel
swift test --filter AgentRecoverableToolErrorTests --disable-sandbox --no-parallel
```

**目标验收独立严格运行，预期当前 RC4 返回非零：**

```sh
swift run --package-path Examples/ExternalClient BoundedReplanningProbe
```

非零退出是真实目标断言失败；编译、环境或 fixture 协议错误须修复，不能当作功能缺口。正常测试不跳过红灯，也不在 CI 使用 `continue-on-error`。脚本模型仅在请求确有对应的搜索结果、错误关联及有效反馈时继续；它不模拟真实 LLM 的自主纠错成功率。

## Fixture 与可观察边界

一次用户输入建立一个 Session 和一个 Run。脚本 Provider 从实际请求中识别 `search-first` 的 A/B 工具结果，再提交无 Evidence 的 X；只有收到关联 `invalid-X` 的错误工具结果才会选择 A（T1）或再发起只读 `search-again`（T2）。搜索工具签发 A/B 的真实 Evidence。mutation 要求同 Run Evidence、资源及 revision Receipt，在 executor 内检查 Journal 已记录 durable intent，向独立临时文件写一行，再返回可信 Receipt。没有测试代码直接调用 executor，也没有人工补搜索、人工插入工具错误、Host retry 或第二个 Run。

Provider 保存完整请求；Run events 保存模型提案、工具失败和终态。记录 Session/Run/operation ID、请求数、搜索次数、错误调用次数、executorEntered、文件写入行数、pending 状态、settled 状态、Receipt/output、反馈和逻辑结束与 physical drain 的 monotonic 纳秒。`toolStarted` 仅代表调度层通知；executorEntered 是工具入口单独计数。无 Receipt 不能证明没有外部效果，故同时核对临时文件和 executor 入口。当前公开 Journal API 可查询 pending 和身份状态，无法从包外直接枚举每条内部 journal event；被拒绝提案的内部 intent event 精确序列为 **NOT OBSERVED**，可观察的对应 mutation identity 为 nil，pending 为空。Host 调用与直接 fixture executor 调用均为零（fixture 没有 Host 或直接调用路径）。

## 常规现状与安全回归

| Case | 意图和证据 | RC4 实测 / 目标边界 |
| --- | --- | --- |
| C1 | `discoveredReferenceCommitsWithOneTrustedReceipt`：A/B 搜索后使用 A；工具入口检查 durable intent；文件、Receipt、Journal identity 三方核对 | **PASS**：3 次 Provider 请求、1 次搜索、1 次 executor/文件写入、1 个 Run Receipt、settled 且无 pending。目标纠错仍需同样完整准入。 |
| C2 | `visibleReadOnlyFailureLetsModelCorrectTheQueryInTheSameRun`：只读工具显式 `modelVisible`，请求核对 `missing-call` 错误 payload、调用配对；另有 `recoverableErrorWithoutPolicyOptInStillFailsTheRun` | **PASS**：模型收到错误后在同 Run 搜索 `available`，3 次请求、2 次工具、无 Receipt；默认 `failClosed` 仅 1 次请求。此机制不能推出 mutation Evidence 拒绝也会模型可见。 |
| C3 | `unobservedReferenceFailsEvidenceBeforeExecutorOrIntent`：A/B 后提交 X；检查 typed failure、events、文件与 Journal identity | **PASS（预期拒绝）**：`EvidenceError.unavailable(resource/X)` 在工具执行链的 Evidence 校验发生，`toolFailed` 和 `runFinished.failed`；2 次 Provider 请求，无错误后的请求，无错误工具结果；executor/文件写入为 0、pending 空、X identity nil。此 PASS 不等于纠错目标已达成。 |
| C4 | `AgentRecoverableToolErrorTests` 的 readOnly modelVisible、failClosed、authorizationFailure；C3；`AgentMutationRecoveryTests` 的执行后失败和恢复 | **PASS**：只读业务错误可见；Evidence 与授权拒绝封闭；执行后结果不确定进入 `needsReconciliation`。scope 撤销由 `AgentCapabilityScopeTests` 验证，不能统一标成 retryable。 |
| S1 | `untrustedToolAndModelClaimsCannotMintEvidence`：搜索 JSON 的不可信 note 与模型文本都声称 X 已获批准 | **PASS**：仍为 Evidence 拒绝，executor/文件写入 0、X identity nil。文本不能签发 Evidence。 |
| S2 | 复用 `authorizationFailureStaysFailClosed`、`lateAuthorizationCannotEnterAfterRevocation`、`outOfScopeResourceAndGuessedToolNeverEnterExecutors`、`capturedToolSetAndRevokedGenerationStayBoundToOneSession` | **PASS**：拒绝、过期绑定和未经批准的工具不可绕过；`authorization: .notRequired` 不代表 scope 有效。预备脚本响应不会自动取得下一次执行。 |
| S3 | `modelStreamFailureAfterSettlementKeepsReceiptAndOutputWithoutReplay`：首次 mutation 后下一次 Provider 流受控抛错 | **PASS**：模型终态失败，1 次文件效果，1 次 validated Receipt event，Journal settled 保存 Receipt/output，无 pending、无再次进入 executor。 |
| S4 | 复用 `testCancellationAfterRealFileEffectKeepsReconciliationAndPhysicalDrain`、`testTimeoutAfterRealFileEffectDoesNotReplayTheExecutor`、`revokeAfterFileEffectKeepsTheIntentAndDrainOwnerAcrossRestart` | **PASS**：文件已写但结算未知进入 needsReconciliation；同 operationID 重开不再写入。无回执不能推断无副作用。 |
| S5 | 复用 `lateAuthorizationCannotEnterAfterRevocation`、`revocationDuringSharedResourceWaitDoesNotGrantExecutionOrReleaseTheOtherScope`、`finalAdmissionBeforeRevokeRemainsInFlightUntilTheExecutorAndDrainExit` 和只读迟到错误测试 | **PASS**：barrier 控制的取消、迟到工作与 physical drain 保持资源边界。此类测试只证明控制接口，不证明模型理解自然语言“先别播”。 |
| S6 | 复用 `modelTurnBudgetStillAppliesAfterRecoverableError`、`AgentLoopBudgetTests` 和 C2 的 3-turn/2-call 限额 | **PASS**：继续只读调用使用原 Run 限额；T1/T2 的可执行目标仍须验证原 deadline、原计数、无第二个 Run。 |
| S7 | 复用 `AgentCompletionCommitTests`、`AgentConversationContextTests`、`AgentContextPipelineTests`、`AgentMutationRecoveryTests.testIntentIsDurableBeforeExecutorAndTrustedSettlementIncludesConversation`；C3 检查 X 不在正式工具结果历史中 | **PASS**：多工具配对、稳定消息身份、Receipt/output、operation identity 与重开恢复遵守现有契约；拒绝提案不伪装成执行结果。 |

## 严格目标探针结果

| Case | 目标断言 | 当前运行轨迹与缺口 |
| --- | --- | --- |
| T1 | X 在执行前安全拒绝；错误工具结果关联 `invalid-X` 进入同 Run 下一请求；脚本用原候选 A 再经完整准入，产生一次可信效果 | **FAIL，目标缺口：没有继续请求**。2 次请求、1 次搜索、1 次 X 提案；`EvidenceError.unavailable(resource/X)` 终止 Run。无反馈、executor 0、文件效果 0、pending 空、X identity nil。 |
| T2 | 收到同一错误反馈后，脚本自行调用只读搜索，再用 A 执行；Host 不搜索 | **FAIL，目标缺口：没有继续请求**。同样停在第 2 次请求之后，故没有模型提出的第 2 次搜索，也没有 mutation。 |

T1 与 T2 独立运行，各自产生一个 Run；严格命令退出码为 **1**。请求中没有错误后的轮次，因此「反馈内容」为 **NOT OBSERVED**，不能推断模型收到错误却拒绝改正。失败点位于 Evidence 拒绝向模型可见反馈与同 Run 继续之间；现有 `readOnly + modelVisible` 通道已经证明可发送关联错误，但其规则不覆盖该 mutation 准入拒绝。目标约束目前没有可公开配置的恢复契约，不能编造错误字段或恢复 API。后续最小生产设计可在确定“尚未进入 executor 且没有 unresolved effect”的边界上提供关联拒绝结果，沿用同 Run 预算、原 Evidence/authorization/scope/Journal 门禁；执行后不确定的路径必须保持待核实。这里仅提出方向，没有实现。

## 测量限制

单次 fixture 的 `logicalNs` 与 `drainNs` 是 monotonic 阶段耗时，不是音乐点播延迟指标。Provider 轮次来自真实请求日志，搜索与 executor 来自工具入口，文件效果由文件内容独立计数。基于 RC4 的真实 LLM 自主纠错成功率、p50/p95、音乐推荐质量、MusicKit 和设备播放状态为 **NOT RUN**。包外观测不到的内部阶段标记为 **NOT OBSERVED**；Host 端受限补救不在本次实验路径。目标探针的红灯不能解释为 Host 现场补救失效。
