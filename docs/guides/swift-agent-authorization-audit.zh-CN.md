# 可审计授权接入（RC6 候选，尚未发布）

last-verified: 2026-09-30

Host 决定是否授权；SwiftAgent 绑定、执行并记录这个决定。
Receipt 证明既有执行路径确认了什么，不是批准文件。
本能力不在 `1.0.0-rc.5` 中。[完整英文契约](swift-agent-authorization-audit.md)。

## 开启与保存目录

在创建 Agent 的 Host 层配置 `requiredAudit`。工具参数、模型文本、Skill 和
Run 配置不能关闭它。默认 `legacy` 保持原有执行方式，不承诺完整授权审计。
所有模型工具调用都受企业 authorizer 约束，包括只读、动态定义工具，以及
声明 `authorization: .notRequired` 的工具。工具自身要求的领域检查仍叠加执行。

```swift
let journal = try AgentIncrementalJournal.create(
    at: hostSelectedDirectory,
    operationDomain: "shared-backend-effects",
    supportsAuthorizationAudit: true
)
let agent = try Agent(model: model, provider: provider, tools: tools,
    configuration: .init(authorization: .init(
        mode: .requiredAudit, authorizer: hostAuthorizer, identity: hostIdentity
    )))
let session = try agent.makeSession(journal: journal)
let run = try await session.run("执行已明确描述的动作", operationID: "stable-business-operation")
_ = try await run.wait()
try await run.waitForDrain()
try await journal.close()
let reopened = try AgentIncrementalJournal.open(at: hostSelectedDirectory)
```

完整、包外编译的接入函数见
[HostIntegration.swift](../../../Examples/ExternalClient/Sources/EnterpriseAuthorizationFixture/HostIntegration.swift)。
目录由 Host 选择，SDK 没有默认生产用户路径或缓存回退。权威原始记录和执行账本
共用同一个 Journal：`CURRENT` 选择已提交 root；类型化载荷位于管理的
`segments/*.seg`、维护后的 `state/*.pack` 或大帧的 `blobs/*/*.blob`。
`audit-records`、`audit-groups`、`audit-members`、`audit-exports` 和
`witnesses` 是 SDK 管理的索引。不要直接修改这些文件。

显式创建使用 schema 5，也支持 RC5 的准入前拒绝事实。普通创建仍是 schema 3；
只开启准入前拒绝能力仍是 schema 4。schema 3/4 不原地升级，不能用于
`requiredAudit`。真实 RC5 reader 在打开 schema 5 时拒绝，包括空 store。
共享去重事实的 Session 应继续使用同 store、operation domain 和 scheduler；
更换 project 标签、导出目的地或 scope 不会迁移既有 mutation 身份。

缺少 authorizer、身份上下文或可用审计 store 时，在候选输入提交和 Provider
请求之前失败。不会降级、换成内存日志或创建空账本续跑。

## Host 的决定

实现 `AgentAuthorizer.decide(_:)`。Request 来自 runtime 冻结的 prepared call，
没有公开构造器。Host 根据真实身份和策略，用当前 request 构造
`AuthorizationDecision(request:...)`，返回 allow、deny 或 requiresUserAction。
主体至少有 issuer、稳定 subjectID 和 human/automatedPolicy/service 类型。
自动规则放行不能记成用户点击确认。人工交互集中在企业 authorizer，工具
`authorize` 保留必要领域检查。

Host 负责身份真实性、在线策略核验和外部审批服务。SDK 检查 requestID、动作
摘要、store/Session/Run/能力范围、本地策略代际、有效期和执行顺序。
`authorizationID` 是关联 ID，不是可重放凭据。决定的 Codable 数据只有归档用途；
反序列化旧批准会丢失当前请求的进程内许可，不能恢复执行权。
requiresUserAction 表示本次没有许可；长时审批由 Host 管理，重新派发产生新提案，
重新核验当前条件。Host 重新派发时可在 factory 配置
`relatedProposalID`，恢复同 Session/store，并关联原提案；跨 Session/store 的引用
在输入/Provider 之前拒绝。新摘要也绑定该关联。修改参数或收缩范围产生新提案和决定，
不会覆盖旧记录；关联 ID 不恢复旧许可。

工具可实现 `authorizationBinding(for:)`，声明定义/实现版本、资源 revision、
后端/账号/凭据代际，以及不可变附件 ID、版本、内容摘要。SDK 复用现有 JSON
规范化，并绑定实际工具定义、参数、资源、Receipt expectation 与作用域。
批准后声明变化会拒绝旧许可。仅绑定可变路径不足以绑定动作。
真实 executor 仍须使用不可变输入、版本化读取或条件写入；摘要不能隔离恶意 Host。

## 分开查看五种结果

```swift
var cursor: AuditCursor?
repeat {
    let page = try await reopened.auditRecords(
        matching: .init(runID: run.id), limit: 50, cursor: cursor
    )
    for record in page.records {
        switch record.fact {
        case .authorization(let a): print(record.sequence, a.layer, a.status)
        case .disposition(let d): print(record.sequence, d.state)
        case .result(let r): print(record.sequence, r.kind, r.sourceRunID)
        case .proposal(let p): print(record.sequence, p.stage, p.reconstructable)
        }
    }
    cursor = page.nextCursor
} while cursor != nil
```

| 要查看的事实 | 查询结果 |
| --- | --- |
| Host 允许或拒绝 | enterprise 层 allowed/denied；工具检查另有 tool 层事实 |
| runtime 未评估 Host | Evidence 等前置拒绝记 notEvaluated，不冒充 Host deny |
| 获得许可但未执行 | dispatchPrepared 与 runtimeAdmitted 分开；notExecuted 说明已知拒绝原因 |
| 结果未知 | uncertain 关联既有 pending intent；不存在 executorObserved 不能证明无效果 |
| 返回旧结果 | replay 关联原 Run/Receipt；本次重新授权，没有新的外部执行 |

只读 executor 已进入后失败记 interrupted；没有合法 Receipt 的只读结果不会
伪造 Receipt。mutation 成功只来自原有 settlement/reconciliation，不另建成功状态机。

查询还可按 Session、invocation、proposal、authorization、operation 和逻辑业务
operation ID 关联；多条件是 AND。固定高水位、每页最多 100 条、最多检查 400 条，
空页也可能有 nextCursor。旧游标与 store、过滤条件、原始载荷视图不符会抛错。
查询接口不会注册成模型工具，Host 负责查看权限与安全域隔离。

常规查询去掉原始/规范化参数、资源与材料、Receipt 身份和规范化 mutation identity，
仍保留 Host 声明的身份和决定元数据。受权操作者可使用
`includeRestrictedPayload: true`，通过 proposalID 查原始和 prepared 载荷。
拒绝提案有独立的载荷来源，不靠伪造 tool result 保存。

## 企业归档接收端

Host 实现 `AuditExportSink.write(_:)`，选择本地文件、网络或数据库，负责认证和
接收端持久化。按 `(storeID, auditRecordID)` 去重；持久接收本批次连续前缀后，
返回 `AuditExportAcknowledgement(batch:throughSequence:)`。
仅显式调用 `journal.startAuditExporter` 才开始导出，默认不联网。

```swift
let exporter = try await reopened.startAuditExporter(
    configuration: .init(id: "archive-v1", destinationID: "host-receiver",
        contentVersion: "1", redactionVersion: "conservative-v1"),
    sink: hostSink
)
try await exporter.waitForDrain()
let status = await exporter.status()
print(status.acknowledgedThroughSequence, status.backlogRecords, status.lastFailure as Any)
```

至少一次交付允许 ACK 丢失后重发。SDK 校验批次、目的地、内容版本/摘要和范围；
部分 ACK 只推进前缀，重复旧批次或迟到 ACK 不跳过未确认记录。位点共用 Journal
事务。目的地、过滤或脱敏版本改变时，应换配置 ID 从零导出；同 ID 不会沿用不符的位点。
过滤配置的位点确认的是该配置下的全局序号范围，不表示被过滤记录也已上传。

默认导出省略原始参数、输出、Receipt/operation 身份、任意 Host 字符串和 endpoint。
确定性脱敏器只能改导出视图；抛错或输出超限即停止，不修改绑定或正式历史。
Journal 本身没有因此加密，也不能宣称没有敏感信息。JSONL 是归档视图，不是可恢复备份。

本地可靠提交是执行门槛，远端 ACK 不是授权。可设置积压上限拒绝新工作，仍允许
已准入 mutation 结算和清理。stop 不要求清空全部积压；慢或不合作 sink 在实际
退出前仍有 owner，不能提前关闭它依赖的 Journal。取消 drain waiter 只取消等待。

## 恢复、保留和验证边界

提案保存失败不调用对应 authorizer/executor；决定或 intent 的 commitUnknown 后
排空、关闭并重开真实 root 核实，不自动重试动作。executor 可能生效时继续使用
原有 reconciliation；取消/超时不能删除 intent 或证明无效果。已结算后的 UI、观察
或导出错误不触发再次执行。重开旧批准只可查询，不恢复活许可。

本地 scope 的撤销/代际使用进程内协调，有效期使用单调时钟。Host 负责收到远端
策略变化后的通知和在线核验；多次查询不构成跨系统原子权限证明。本地时间和
摘要不是可信时间戳、签名或抗管理员篡改保证。tenant/project 标签不是隔离机制。

原始事实、Receipt、输出和幂等身份默认不自动遗忘；上传成功不能据此删除它们。
存储随真实工作量增长。SDK 限制单条载荷和在途数量，但磁盘故障仍可能造成未知结果。
本轮不覆盖 SSO/IAM、多人审批、可复用批准 token、审批时改参、自动迁移、任意
Journal 后端、远端 ACK 与本地执行的分布式事务，也不覆盖所有 Provider 数据出境。

运行包外、无密钥、无网络的完整示例：

```sh
swift run --package-path Examples/ExternalClient EnterpriseAuthorizationFixture
bash Scripts/ci-audited-authorization.sh
```

故障、独立进程、真实新旧 reader 与性能证据见
[验收矩阵](../releases/rc6-audited-authorization-acceptance.md)。SIGKILL 只验证进程终止恢复，不称为断电验证。
