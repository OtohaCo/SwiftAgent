# SwiftAgent

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

SwiftAgent は、特定のモデルベンダーに依存しない Swift 向け Agent ランタイムです。型付きツール、actor で分離された会話、ストリーミングイベント、Evidence に基づく実行、mutation の Receipt、永続 Journal、クラッシュ復旧、Provider アダプターを提供します。

この README は、目的に合ったドキュメントを探すための入口です。詳細な統合ガイドは現在英語です。中国語版と日本語版の README も、同じナビゲーションと対象範囲を示します。

## ここから始める

| 目的 | 最初に読むもの | 次に読むもの |
| --- | --- | --- |
| App に SwiftAgent を組み込む | [App 統合の入口](INTEGRATION.md) | [統合レシピ](docs/ai/consumer-recipes.md) |
| Codex、Claude などのコーディング AI に統合を実装させる | [AI 向け統合ガイド](docs/ai/start-here.md) | [受け入れチェックリスト](docs/ai/acceptance-checklist.md) |
| SDK 自体を変更する | [コントリビューションガイド](CONTRIBUTING.md) | [テストガイド](docs/testing.md)と[セキュリティモデル](docs/security-model.md) |

**App への統合と SDK の開発は別の作業です。** SDK を利用する App は public API を使い、UI を動かすためにエンジンを変更したり、内部 executor をコピーしたりしないでください。コーディング AI は、依存する revision の確認、`INTEGRATION.md`、該当レシピ、受け入れチェックの順に進めます。チェックリストには、生成コードの見た目の確認だけでなく、新しいコンテキストで実際に統合する演習も含まれます。

## 目的別ガイド

| 作業 | ガイド |
| --- | --- |
| iOS/macOS UI、MainActor の分離、Run の所有権、停止、画面遷移 | [Apple UI 統合](docs/guides/swift-agent-apple-ui.md) |
| Linux HTTP サービスを構築する：テナント分離、Run の所有権、SSE、デプロイ | [サーバー統合](docs/guides/swift-agent-server.md) |
| Android クライアントを開発する、または Swift/JNI によるネイティブ組み込みを検討する | [Android 統合](docs/guides/swift-agent-android.md) |
| UI で SSE を解析せず、テキストとツールの進捗を表示する | [UI ストリーミング](docs/guides/swift-agent-ui-streaming.md) |
| 読み取り専用ツール、mutation、再起動後の復旧、構造化回答を追加する | [統合レシピ](docs/ai/consumer-recipes.md) |
| 会話 Provider を選び、対応範囲を確認する | [Provider マトリクス](docs/providers.md) |
| TypeSafe Jev の Noul、Choice、Score による助言を利用する | [Decision Providers](docs/guides/swift-agent-decisions.md) |
| サンプルを実行し、キーを設定し、fixture と実サービス呼び出しを区別する | [サンプルと実サービス検証](docs/guides/swift-agent-examples-and-live.md) |
| App が所有する音声・画像・動画・音楽サービスを設計する | [Host サービスツール](docs/guides/swift-agent-host-service-tools.md) — ドキュメントのみであり、メディア SDK ではありません |

Provider ごとの契約：
[Anthropic Messages](docs/guides/swift-agent-anthropic-provider.md) ·
[OpenAI Responses](docs/guides/swift-agent-openai-provider.md) ·
[DeepSeek Responses](docs/guides/swift-agent-deepseek-provider.md) ·
[Apple オンデバイス/PCC](docs/guides/swift-agent-apple-provider.md)。

## 対象バージョンとインストール

last-verified: 2026-09-19

この README と翻訳版がソースを確認した基準は、RC.2 開発系列の `7cc8aa6e333062ee3a20a24daed13de463008fff` です。このドキュメントはリリース告知でも、新たなテスト結果でもありません。App に導入した依存関係と同じ revision のドキュメントを参照してください。

### 公開済みの rc.1

公開済みリリース候補の API を使う場合は、そのバージョンを固定します。

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaPlayer/SwiftAgent.git",
        exact: "1.0.0-rc.1"
    )
]
```

rc.1 の固定先は `d2347f11c6a78f421708e897dae42a51a98d37ea` です。
**rc.1 の依存関係と、RC.2 系列で説明されているすべての API を混在させないでください。** OpenAI/DeepSeek Responses、Decision/Jev などの次期 RC 向け追加機能には、対応する未リリースの revision が必要です。その revision の Package とガイドを確認してください。

### 次期 RC を明示的に評価する

更新され続けるブランチを追うのではなく、確認済みソースの基準を再現する場合：

```swift
dependencies: [
    .package(
        url: "https://github.com/OtohaPlayer/SwiftAgent.git",
        revision: "7cc8aa6e333062ee3a20a24daed13de463008fff"
    )
]
```

これは開発用 revision の明示的な固定です。未監査の revision を製品として出荷することを勧めるものでも、最新 commit であることを示すものでもありません。ターゲットが実際に使う products だけを追加してください。RC.2 開発ブランチは `plan/swift-agent-rc2` です。`main` に同じ変更があると仮定しないでください。[バージョン方針](docs/guides/swift-agent-versioning.md)も参照してください。

Git submodule でローカル package を提供する場合、SDK commit は親リポジトリの gitlink で固定します。App の `Package.resolved` はそのローカル package の固定には使われません。SDK の変更を先に commit・push し、利用側 App を検証してから gitlink を更新します。暗黙にリモートブランチを追従したり、推測した API をコンパイルするために依存関係を更新したりしないでください。

## 動作要件

| 対象 | 要件 |
| --- | --- |
| 検証済みコンパイラー / 言語モード | Swift 6.4 / Swift 6 |
| Core products | macOS 13+、iOS 16+、Linux |
| AgentDecisions / AgentJevProvider | macOS 13+、iOS 16+、Linux |
| オプションの Apple Foundation Models adapter | macOS/iOS 26+。PCC を含む個別 API には追加の可用性条件があります |
| その他の移植可能な products | AgentModels、AgentTools、AgentProviders、WorkspaceAgent は Linux に対応 |

正確な可用性は [Package.swift](Package.swift) と Apple Provider ガイドで確認してください。`swift-tools-version: 6.0` は manifest 言語の下限であり、検証に使うコンパイラーのバージョンではありません。Core は SwiftUI や Apple のモデル SDK に依存しません。

## サーバーと Android の対応範囲

[サーバーガイド](docs/guides/swift-agent-server.md)では、App が所有する HTTP サービスで SwiftAgent を実行する方法を説明します。Linux パッケージの検証は、本番サーバーへのデプロイ検証とは別です。認証、会話の分離、クライアント向けストリーミング、複数インスタンスの調整は Host が担当します。

[Android ガイド](docs/guides/swift-agent-android.md)では、Android からそのサービスを呼ぶ方式と、Swift/JNI で SwiftAgent をアプリ内に組み込む方式を区別します。前者では APK に Swift runtime を含める必要はありません。後者には、対象モジュール、ブリッジ、パッケージング、デバイス上での検証が必要です。Swift 自体の Android 対応は、SwiftAgent がこれらを検証済みであることを意味しません。この文書追加ではサーバー実行ファイルや Android ブリッジを実装しません。詳細ガイドは英語です。

## 既存サンプルを実行する

**SwiftAgent リポジトリのルート**で実行します。

```sh
swift test --package-path Examples/ExternalClient
swift run --package-path Examples/JevDecision JevDecision
swift test --package-path Examples/AppleChatApp
bash Examples/AppleChatApp/run-macos.sh
```

[ExternalClient](Examples/ExternalClient) は public API を通じた SDK の利用をテストします。[JevDecision](Examples/JevDecision) は、標準では fixture を使う Noul、Choice、Score の実行可能なサンプルで、出力は提案でありツール実行の許可ではありません。[AppleChatApp](Examples/AppleChatApp) は認証情報不要の fixture リファレンスで、App 所有の SwiftUI ライフサイクル、直接ストリーミング、検証後のバッファー公開、ツール進捗、キャンセル/drain の所有権を示します。

Jev を実際に呼び出すには、ローカル環境に `TYPESAFE_API_KEY` を設定した後、POSIX 互換の shell で実行します。

```sh
: "${TYPESAFE_API_KEY:?Set TYPESAFE_API_KEY locally before a live run}"
export TYPESAFE_API_KEY
SWIFT_AGENT_JEV_LIVE=1 \
  swift run --package-path Examples/JevDecision JevDecision
```

`TYPESAFE_MODEL` でモデルを指定できます。実行プログラムはプロセス環境変数を読みます。`.env` ファイルを作成するだけでは自動で読み込まれません。親リポジトリから実行する場合は、package パスの先頭に `SwiftAgent/` を付けます。

認証情報をソース、プロンプト、ログ、配布する App バイナリに含めないでください。明示的な live モードと fixture 実行を区別する必要があります。Fixture 検証、SDK CI、Host 統合、実サービス検証は別々の根拠です。キーがない状態は live テストの成功ではありません。制限と受け入れ条件はサンプルガイドを参照してください。

## App の非同期統合とストリーミング

`Agent` は Sendable な設定を保持します。`AgentSession` は canonical な会話履歴を所有する actor で、同時に実行できる active Run は一つです。`AgentRun` は `events`、`cancel()`、`steer(_:)`、`wait()`、`waitForDrain()` を公開します。

MainActor の ViewModel と、App が所有する会話 Controller を分離する設計を推奨します。最初の `await` より前に開始状態を確保し、Run と後処理の owner を保持し、会話/Run の識別子で遅延コールバックを隔離します。非同期であることは、専用バックグラウンドスレッドや iOS での無期限のバックグラウンド実行を保証しません。これらの Host の責任は Apple UI ガイドで説明しています。

**`AgentRun.events` の consumer は一つにします。** Provider が HTTP/SSE を処理して正規化されたモデルイベントを出力し、AgentCore が App 向けの Run ライフサイクルを出力します。複数の View は Host 所有のスナップショットを使い、同じ単一 consumer 用 stream を取り合わないようにしてください。Delta は暫定的な内容です。増分を表示した後に全文をもう一度追加したり、一つのモデル response の完了を Run 全体の完了と見なしたりしないでください。`ModelProviderRoute` は検証対象の候補レスポンスを意図的にバッファーするため、通信が SSE でもリアルタイム streaming を宣言しません。

監視をキャンセルしても Run はキャンセルされません。`run.cancel()` は実行のキャンセルを要求し、`wait()` は論理的な終了を返し、`waitForDrain()` は SDK のリソース解放ライフサイクルを待ちます。キャンセルはロールバックではなく、リモート処理のキャンセルも保証しません。失敗時の後処理と Provider drain の限界は各ガイドに従ってください。

## 信頼境界

会話は Evidence ではありません。モデルの提案や Decision の confidence は認可ではありません。Provider は Host ツールの executor を受け取りません。実行は AgentCore と AgentTools が担い、ドメインのポリシーは Host に置きます。

Mutation ツールには、Session 作成時の永続 `AgentJournal`、実行前の durable intent、信頼できる Receipt の検証、成功を確定する前の durable settlement が必要です。同じリソースに触れる Session は scheduler を共有します。一つの論理 mutation を再試行する場合は、同じ空でない `operationID`、一致するツールと意味上の引数、共有 Journal を維持してください。新しい識別子は新しい操作であり、安全な再試行ではありません。

本番の Receipt を捏造したり、UI を片付けるために結果不明の mutation を自動 abort したりしないでください。Abort できるのは、外部への副作用が発生していないことを信頼できる方法で確認した場合だけです。それ以外は照合・整合性確認を行います。復旧処理は結果不明の executor を自動再実行しません。書き込み処理を実装する前に、セキュリティモデルと mutation レシピを読んでください。

`DecisionProvider` は独立した非会話型の契約です。Jev の出力は信頼されていない助言のままであり、Evidence の作成、認可の付与、ツールの実行、信頼できる Receipt の生成、Journal の確定処理はできません。

## Products と依存関係

| Product | 内部依存 | 役割 |
| --- | --- | --- |
| AgentModels | なし | モデルの値と Provider 契約 |
| AgentTools | AgentModels | 型付きツール、検証、実行ポリシー |
| AgentCore | AgentModels, AgentTools | 唯一の Agent loop、Session、Run |
| AgentProviders | AgentModels | Anthropic、OpenAI Responses、DeepSeek Responses、検証後のルーティング |
| AgentAppleProvider | AgentModels | Apple オンデバイス/PCC のプランニングとプラットフォーム SDK の分離 |
| AgentDecisions | AgentModels | 型付きでベンダーに依存しない Decision リクエストとレスポンス |
| AgentJevProvider | AgentModels, AgentDecisions | TypeSafe Jev adapter。実行権限なし |
| WorkspaceAgent | AgentModels, AgentTools, AgentCore, AgentProviders | サンドボックスファイルの Reference Host。Core の依存先ではない |

WorkspaceAgent は SHA-256 に [swift-crypto](https://github.com/apple/swift-crypto) も使用しますが、その依存を Core には持ち込みません。メディアサービスの Client、ジョブ保存、アセットは利用側 App またはオプションの拡張に置き、AgentCore には置きません。マルチメディアガイドによるサービス実装の追加はありません。

## 契約と検証記録の索引

| 分野 | 詳細資料 |
| --- | --- |
| モデルデータと wire 変換 | [ModelRequest](Sources/AgentModels/ModelRequest.swift)、[ModelMessage](Sources/AgentModels/ModelMessage.swift)、[ModelMetadata](Sources/AgentModels/ModelMetadata.swift)、[モデルイベント契約](docs/guides/swift-agent-model-events.md) |
| Runtime と進捗 | [Agent loop](docs/guides/swift-agent-loop.md)、[Session/Run](docs/guides/swift-agent-sessions.md)、[Agent イベント](docs/guides/swift-agent-events.md) |
| ツールと副作用 | [型付きツール](docs/guides/swift-agent-tools.md)、[Evidence](docs/guides/swift-agent-evidence.md)、[Receipts](docs/guides/swift-agent-receipts.md)、[スケジューリング](docs/guides/swift-agent-scheduler.md) |
| 永続化とライフサイクル | [Journal](docs/guides/swift-agent-journal.md)、[mutation 復旧](docs/guides/swift-agent-mutation-recovery.md)、[コンテキストポリシー](docs/guides/swift-agent-context.md)、[並行処理](docs/guides/swift-agent-concurrency.md) |
| エラーと互換性 | [型付きエラー](docs/guides/swift-agent-errors.md)、[バージョン方針](docs/guides/swift-agent-versioning.md) |
| public API を使う別の App | [Workspace File Agent](docs/guides/swift-agent-workspace-host.md) |
| 検証記録 | [テストコマンド](docs/testing.md)、[名前付き回帰テスト](docs/testing-regressions.md)、[レビュー記録](docs/reviews)、[リリース記録](docs/releases) |

モデルの Codable データは、ベンダーの wire format でも、固定された Journal 形式でもありません。Usage は累積スナップショットです。未報告はゼロではなく、キャッシュ/推論の内数を合計へ再加算してはいけません。`localizedDescription` の文字列ではなく、型付きエラーで分岐してください。レビュー記録は対象の基準と範囲を確認してください。過去の CLEAN 判定は、別の commit に対する新たな検証根拠にはなりません。

## SDK の開発とテスト

ライブラリを変更する前に `CONTRIBUTING.md` を読んでください。SDK ルートから、実際に対応する環境でリポジトリのスクリプトを実行します。

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

[DependencyGuardTests](Tests/ArchitectureTests/DependencyGuardTests.swift) は package 境界を確認します。[.github/workflows/ci.yml](.github/workflows/ci.yml) は SDK CI を定義するもので、利用側 App の UI や実サービスの受け入れ検証ではありません。通常の CI は認証情報を必要としません。ビルド、実際の実行、skip、制限を分けて記録してください。この README 更新で上記のコマンドを実行したとは主張していません。

## 翻訳の保守

英語の README を翻訳元とします。ナビゲーションや対象範囲を変更する際は、`README.md`、`README.zh-CN.md`、`README.ja.md` を同期してください。public API 識別子、依存 revision、実行コマンドは言語間で変更しません。翻訳の対象はこの README であり、リンク先の詳細ガイドは英語のままです。説明が導入済み revision の public API や契約と矛盾する場合は、ソースを確認してドキュメントを修正し、存在しない API を作り出さないでください。

ライセンス：[MIT](LICENSE)。
