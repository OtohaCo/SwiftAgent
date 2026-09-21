# SwiftAgent

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

SwiftAgent 是一个不绑定模型厂商的 Swift Agent 运行时，提供类型化工具、actor 隔离的会话、流式事件、基于 Evidence 的执行、mutation 回执、持久化 Journal、崩溃恢复和 Provider 适配器。

这份 README 用于选择阅读路径。详细接入指南目前使用英文；中文和日文 README 提供相同的导航与范围说明。

## 从这里开始

| 你要做什么 | 先读 | 接着读 |
| --- | --- | --- |
| 在 App 中接入 SwiftAgent | [App 接入入口](INTEGRATION.md) | [接入步骤与常用模式](docs/ai/consumer-recipes.md) |
| 让 Codex、Claude 或其他编码 AI 完成接入 | [AI 接入指南](docs/ai/start-here.md) | [验收清单](docs/ai/acceptance-checklist.md) |
| 修改 SDK 本身 | [贡献指南](CONTRIBUTING.md) | [测试指南](docs/testing.md)和[安全模型](docs/security-model.md) |

**App 接入和 SDK 开发是两类任务。** 使用 SDK 的 App 应通过 public API 接入，而不是为了让 UI 工作而修改引擎或复制内部 executor。对编码 AI，建议依次确认依赖版本、阅读 `INTEGRATION.md`、选择接入模式，最后执行验收清单。清单包含全新上下文的实际接入练习，不只是检查生成的代码看起来是否合理。

## 按任务查找文档

| 任务 | 指南 |
| --- | --- |
| iOS/macOS UI、MainActor 分离、Run 所有权、停止和导航 | [Apple UI 接入](docs/guides/swift-agent-apple-ui.md) |
| 运行 Linux HTTP 服务：租户隔离、Run 所有权、SSE 与部署 | [服务器接入](docs/guides/swift-agent-server.md) |
| 开发 Android 客户端，或评估 Swift/JNI 本机嵌入 | [Android 接入](docs/guides/swift-agent-android.md) |
| 不在 UI 中解析 SSE，直接显示文字和工具进度 | [UI 流式显示](docs/guides/swift-agent-ui-streaming.md) |
| 添加只读工具、mutation、重启恢复或结构化回答 | [接入步骤与常用模式](docs/ai/consumer-recipes.md) |
| 选择对话 Provider 并确认能力边界 | [Provider 矩阵](docs/providers.md) |
| 发现模型、为 Run 选择配置或使用 Jev 路由 | [动态模型选择](docs/guides/swift-agent-dynamic-model-selection.md) |
| 通过 TypeSafe Jev 获取 Noul、Choice、Score 建议 | [Decision Providers](docs/guides/swift-agent-decisions.md) |
| 运行示例、配置 key、区分 fixture 与真实调用 | [示例与真实服务验收](docs/guides/swift-agent-examples-and-live.md) |
| 规划 App 自己的语音、图像、视频或音乐服务 | [Host 服务工具](docs/guides/swift-agent-host-service-tools.md)——仅文档，不是媒体 SDK |

各 Provider 的具体契约：
[Anthropic Messages](docs/guides/swift-agent-anthropic-provider.md) ·
[OpenAI Responses](docs/guides/swift-agent-openai-provider.md) ·
[DeepSeek Responses](docs/guides/swift-agent-deepseek-provider.md) ·
[Local Responses / LM Studio](docs/guides/swift-agent-local-responses-provider.md) ·
[Apple 端侧/PCC](docs/guides/swift-agent-apple-provider.md)。

## 版本范围与安装

last-verified: 2026-09-21

RC2 源码候选为 `99dd1171d8ef1f3091a350575f30e7e13791b1b5`；发布文档和 package tag 由 RC2 release gate 最终确定。应始终阅读与 App 实际安装的依赖版本一致的文档。

### 已发布的 rc.2

预发布版本发布后，使用明确版本固定依赖：

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaCo/SwiftAgent.git",
        exact: "1.0.0-rc.2"
    )
]
```

参见[RC2 发布范围](docs/releases/1.0.0-rc.2.md)。Apple PCC 在 RC2 中仍是实验性能力，尚未完成 SwiftAgent Core 完整工具循环的 live qualification。

### 已发布的 rc.1

使用已发布候选版的 API 时，固定该版本：

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaCo/SwiftAgent.git",
        exact: "1.0.0-rc.1"
    )
]
```

rc.1 的固定提交为 `d2347f11c6a78f421708e897dae42a51a98d37ea`。RC2 是独立的预发布版本，新增 API 和范围以 RC2 发布说明为准。

### 复现 RC2 源码候选

要复现本文核对过的源码基线，而不是跟随不断变化的分支：

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaCo/SwiftAgent.git",
        revision: "99dd1171d8ef1f3091a350575f30e7e13791b1b5"
    )
]
```

这是明确的源码候选固定方式，不表示推荐发布未经审计的 revision，也不表示它就是 release tag。只添加目标实际需要的 products。参见[版本策略](docs/guides/swift-agent-versioning.md)。

通过 Git submodule 提供本地 package 时，SDK commit 由父仓库 gitlink 固定；App 的 `Package.resolved` 不负责固定这个本地 package。先提交并推送 SDK 修改，再验证使用它的 App，最后更新 gitlink。不要静默跟随远端分支，也不要为了让猜测出来的 API 编译通过而升级依赖。

## 环境要求

| 范围 | 要求 |
| --- | --- |
| 验证使用的编译器 / 语言模式 | Swift 6.4 / Swift 6 |
| Core products | macOS 13+、iOS 16+、Linux |
| AgentDecisions / AgentJevProvider | macOS 13+、iOS 16+、Linux |
| 可选 Apple Foundation Models adapter | macOS/iOS 26+；PCC 等具体 API 另有可用性要求 |
| 其他可移植 products | AgentModels、AgentTools、AgentProviders、AgentCatalog、AgentUsage、WorkspaceAgent 支持 Linux |

准确的可用性要求见 [Package.swift](Package.swift) 和 Apple Provider 指南。`swift-tools-version: 6.0` 是 manifest 语言的最低版本，不是验证所用的编译器版本。Core 不依赖 SwiftUI 或 Apple 模型 SDK。

## 服务器与 Android 的支持范围

[服务器指南](docs/guides/swift-agent-server.md)说明 App 自己的 HTTP 服务如何承载 SwiftAgent。Linux package 验证不等于生产服务器部署验收；认证、会话隔离、客户端流式协议和多实例协调仍由 Host 负责。

[Android 指南](docs/guides/swift-agent-android.md)区分 Android 调用上述服务，以及通过 Swift/JNI 将 SwiftAgent 嵌入本机两条路线。前者不需要在 APK 中包含 Swift runtime；后者仍须完成目标模块、桥接、打包和设备验证。Swift 官方支持 Android，不表示 SwiftAgent 已完成这些检查。这两篇指南不新增服务器 executable 或 Android bridge，详细内容使用英文。

## 运行现有示例

在 **SwiftAgent 仓库根目录**执行：

```sh
swift test --package-path Examples/ExternalClient
swift run --package-path Examples/JevDecision JevDecision
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider openai --mode fixture --case all
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider local --service local --mode fixture --case all
swift test --package-path Examples/AppleChatApp
bash Examples/AppleChatApp/run-macos.sh
```

[ExternalClient](Examples/ExternalClient) 验证通过 public API 使用 SDK。[JevDecision](Examples/JevDecision) 是 fixture-first 的 typed Decision 示例。[ProviderQualification](Examples/ProviderQualification) 为 OpenAI、DeepSeek、Anthropic、Local Responses 和 Jev 提供受预算约束的离线 preflight 与显式 live case。[AppleChatApp](Examples/AppleChatApp) 复用同一安全配置层，支持 fixture 或显式 live 对话 Provider，同时保持 App 自己管理的 SwiftUI 生命周期、工具进度和取消/drain 所有权。

live 配置可以来自进程环境，或 `--env-file` 指向的本机 literal assignment 文件；loader 不执行 shell，进程环境优先。联网前先执行无网络 preflight：

```sh
swift run --package-path Examples/ProviderQualification ProviderQualification \
  --provider anthropic --mode live --case preflight \
  --env-file /absolute/path/to/.env.live
```

Provider 变量、请求预算、单 case、Jev 和 AppleChatApp live 命令见[示例与真实服务验收](docs/guides/swift-agent-examples-and-live.md)。从父仓库执行时，在 package 路径前加 `SwiftAgent/`。

密钥不得进入源码、提示词、日志或分发的 App 二进制文件。必须区分显式 live 模式和 fixture 运行。Fixture 检查、SDK CI、Host 集成与真实服务验收是不同层次的证据；缺少 key 不算 live 测试通过。调用限制与验收要求见示例指南。

## App 异步接入与流式显示

`Agent` 持有 Sendable 配置。`AgentSession` 是 actor，拥有 canonical 会话历史，并且一次只能有一个 active Run。`AgentRun` 提供 `events`、`cancel()`、`steer(_:)`、`wait()` 和 `waitForDrain()`。

建议将 MainActor ViewModel 与 App 自己的会话 Controller 分开。在第一个 `await` 之前占有启动状态，保留 Run 及负责收尾的 owner，并以会话/Run 身份隔离迟到回调。异步不意味着专用后台线程，也不意味着 iOS 无限后台执行。这些 Host 职责在 Apple UI 指南中有具体说明。

**每个 `AgentRun.events` 只消费一次。** Provider 处理 HTTP/SSE 并输出归一化模型事件，AgentCore 输出供 App 使用的 Run 生命周期事件。多个视图应使用 Host 的状态快照，不要争抢同一个单消费者 stream。Delta 是暂定内容；显示增量后不要再追加一遍完整回答，也不要把一个模型 response 完成当作整个 Run 完成。`ModelProviderRoute` 会有意缓冲候选响应并验证，因此即使底层网络使用 SSE，也不声明实时 streaming 能力。

取消观察不等于取消 Run。`run.cancel()` 请求取消执行；`wait()` 返回逻辑终态；`waitForDrain()` 等待 SDK 的资源释放生命周期。取消不是回滚，也不保证远端服务已经取消。失败收尾和 Provider drain 的边界见对应指南。

## 信任边界

会话不等于 Evidence。模型提案或 Decision 置信度不等于授权。Provider 不接收 Host 工具 executor；执行归 AgentCore 和 AgentTools，领域策略留在 Host。

Mutation 工具要求在创建 Session 时提供持久化 `AgentJournal`，在 executor 运行前写入 durable intent，并通过可信 Receipt 验证和 durable settlement 后才能宣称成功。访问相同资源的 Session 应共享 scheduler。同一个逻辑 mutation 的重试，应保留相同的非空 `operationID`、匹配的工具与语义参数，并使用共享 Journal。新身份表示新操作，不是安全重试。

不要伪造生产 Receipt，也不要为清理 UI 而自动 abort 结果不确定的 mutation。只有可信确认未发生外部副作用后才可 abort；否则应对账。恢复流程不会自动重放不确定的 executor。实现写操作前，先阅读安全模型和 mutation 接入步骤。

`DecisionProvider` 是独立的非对话契约。Jev 输出仍是不可信建议，不能创建 Evidence、授予权限、执行工具、生成可信 Receipt 或结算 Journal。

## Products 与依赖

| Product | 内部依赖 | 职责 |
| --- | --- | --- |
| AgentModels | 无 | 模型值与 Provider 契约 |
| AgentTools | AgentModels | 类型化工具、验证与执行策略 |
| AgentCore | AgentModels, AgentTools | 唯一的 Agent loop、Session 与 Run |
| AgentCatalog | AgentModels | 开放模型/部署元数据、三态能力、发现协议与有界缓存 |
| AgentProviders | AgentModels, AgentCatalog | Anthropic、OpenAI Responses、DeepSeek Responses、Local Responses 与 Provider 契约 |
| AgentAppleProvider | AgentModels | Apple 端侧/PCC 规划与平台 SDK 隔离 |
| AgentDecisions | AgentModels | 类型化、厂商无关的 Decision 请求与响应 |
| AgentJevProvider | AgentModels, AgentDecisions | TypeSafe Jev adapter；没有执行权 |
| AgentUsage | AgentModels | 可选的 response、Run 与 Session 统计窗口用量汇总 |
| WorkspaceAgent | AgentModels, AgentTools, AgentCore, AgentProviders | 沙盒文件 Reference Host；不是 Core 的依赖 |

WorkspaceAgent 还通过 [swift-crypto](https://github.com/apple/swift-crypto) 计算 SHA-256，不会将该依赖引入 Core。媒体服务 Client、任务存储与资产属于使用 SDK 的 App 或可选扩展，不属于 AgentCore。多媒体指南没有新增服务实现。

## 契约与验证记录索引

| 主题 | 详细资料 |
| --- | --- |
| 模型数据与 wire 转换 | [ModelRequest](Sources/AgentModels/ModelRequest.swift)、[ModelMessage](Sources/AgentModels/ModelMessage.swift)、[ModelMetadata](Sources/AgentModels/ModelMetadata.swift)、[模型事件契约](docs/guides/swift-agent-model-events.md) |
| Runtime 与进度 | [Agent loop](docs/guides/swift-agent-loop.md)、[Session/Run](docs/guides/swift-agent-sessions.md)、[Agent 事件](docs/guides/swift-agent-events.md) |
| Usage 统计 | [Response、Run 与 Session 统计窗口用量](docs/guides/swift-agent-usage.md) |
| 工具与副作用 | [类型化工具](docs/guides/swift-agent-tools.md)、[Evidence](docs/guides/swift-agent-evidence.md)、[Receipts](docs/guides/swift-agent-receipts.md)、[调度](docs/guides/swift-agent-scheduler.md) |
| 持久化与生命周期 | [Journal](docs/guides/swift-agent-journal.md)、[mutation 恢复](docs/guides/swift-agent-mutation-recovery.md)、[上下文策略](docs/guides/swift-agent-context.md)、[并发](docs/guides/swift-agent-concurrency.md) |
| 动态模型选择 | [目录、Run 绑定、历史兼容和 Host 路由](docs/guides/swift-agent-dynamic-model-selection.md) |
| 错误与兼容性 | [类型化错误](docs/guides/swift-agent-errors.md)、[版本策略](docs/guides/swift-agent-versioning.md) |
| 另一个使用 public API 的 App | [Workspace File Agent](docs/guides/swift-agent-workspace-host.md) |
| 验证记录 | [测试命令](docs/testing.md)、[命名回归](docs/testing-regressions.md)、[发布记录](docs/releases)、[契约矩阵](docs/guides/swift-agent-conformance-matrix.md) |

模型的 Codable 数据不是厂商 wire format，也不是已冻结的 Journal 格式。Usage 是累计快照；未报告不等于零，缓存/推理子集不能再次加到总量中。匹配类型化错误，不要解析 `localizedDescription` 字符串。候选版本的验收证据记录在发布清单和父项目 Kanban 中；历史结论不是另一个 commit 的新验证证据。

## 开发与测试 SDK

修改库之前先读 `CONTRIBUTING.md`。在 SDK 根目录，使用仓库脚本与实际支持的环境：

```sh
bash Scripts/ci-macos.sh
bash Scripts/ci-concurrency-seal.sh
bash Scripts/ci-apple-provider.sh
```

Ubuntu 24.04：

```sh
bash Scripts/install-linux-swift.sh
bash Scripts/ci-linux.sh
```

[DependencyGuardTests](Tests/ArchitectureTests/DependencyGuardTests.swift) 检查 package 边界。[.github/workflows/ci.yml](.github/workflows/ci.yml) 定义 SDK CI，不代表消费方 App 的 UI 或真实服务已经验收。普通 CI 不依赖凭据。构建、实际执行、跳过项和限制应分别记录。本次 README 更新不宣称执行过上述命令。

## 翻译维护

英文 README 是翻译源。导航或范围变化时，同时更新 `README.md`、`README.zh-CN.md` 和 `README.ja.md`。不同语言保持相同的 public API 标识符、依赖 revision 和可执行命令。翻译范围是本 README，链接到的详细指南仍为英文。如果文字与已安装 revision 的 public API 或契约冲突，应核对源码并修正文档，而不是虚构 API。

许可证：[MIT](LICENSE)。
