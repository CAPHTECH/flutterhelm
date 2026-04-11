# FlutterHelm

FlutterHelm は、**Flutter 開発向けの agent-safe な orchestration layer / MCP server** の設計案です。

狙いは、Flutter 開発で散在している以下の面を、AI エージェントにとって扱いやすい一貫した面へ整理することです。

- 公式 **Dart and Flutter MCP server**
- `flutter` CLI
- DevTools / Dart Tooling Daemon (DTD)
- 任意の runtime interaction driver
- iOS / Android の native debugger 連携面

FlutterHelm は、これらを置き換えるものではありません。  
**既存の正規インターフェースを束ね、セッション管理・安全制御・artifact/resource 管理を追加する**ための設計です。

## ステータス

- 状態: **Design proposal**
- 実装前提: MCP client は最低でも **Tools** と **Resources** を扱えること
- 推奨: **Roots** を扱えること
- 初期 transport: **stdio-first**
- 主要スコープ: Flutter ローカル開発、実行中アプリの観測、テスト、profiling、限定的な runtime interaction

## なぜ別レイヤが必要か

公式の Dart and Flutter MCP server はすでに強力ですが、設計上は次の性格があります。

- 公式サーバー自体は **experimental** で、今後も変化しうる
- Flutter の標準実行面は依然として `flutter` CLI
- profiling / debugging の主要面は DevTools
- native code の深掘りは Xcode / Android Studio などの native debugger
- MCP では、巨大な runtime 出力は **Resources** として分離した方が文脈効率がよい

したがって FlutterHelm の役割は、**「個々のツールを増やすこと」より「責務を整理し、安定した contract を与えること」**にあります。

## ドキュメント構成

- [設計根拠](docs/00-design-basis.md)
- [プロダクト概要](docs/01-product-brief.md)
- [PRD](docs/02-prd.md)
- [アーキテクチャ](docs/03-architecture.md)
- [MCP contract](docs/04-mcp-contract.md)
- [Session / Resource モデル](docs/05-session-and-resources.md)
- [Security / Safety](docs/06-security-and-safety.md)
- [Roadmap](docs/07-roadmap.md)
- [Open Questions](docs/08-open-questions.md)
- [Implementation Plan](docs/09-implementation-plan.md)
- ADR
  - [ADR-001: Positioning](docs/adrs/ADR-001-positioning.md)
  - [ADR-002: Transport and Roots](docs/adrs/ADR-002-transport-roots.md)
  - [ADR-003: Resource-first artifacts](docs/adrs/ADR-003-resource-first-artifacts.md)
  - [ADR-004: Optional UI driver](docs/adrs/ADR-004-optional-ui-driver.md)
- [References](docs/references.md)

## コア設計原則

1. **Replace ではなく compose**
   - 公式 Dart and Flutter MCP server、`flutter` CLI、DevTools、native debugger を尊重する。

2. **Session-first**
   - `run`, `attach`, `profile`, `test` の結果を単発コマンドではなく、再利用可能な session として扱う。

3. **Resource-first**
   - widget tree、runtime errors、timeline、memory snapshot、test report などの重い出力は tool result へ直接押し込まず、URI 化した Resource として渡す。

4. **Safe-by-default**
   - read-only を基本にし、依存追加・state 破壊・release build などは人間確認を前提にする。

5. **Workflow-grouped**
   - surface area を workflow 単位で分割し、初期状態では必要最小限のみ有効化する。

## 推奨する初期 enablement

```yaml
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - tests
```

以下は opt-in とする想定です。

- `runtime_interaction`
- `profiling`
- `platform_bridge`

## 想定する最小セットアップ

```json
{
  "mcpServers": {
    "flutterhelm": {
      "command": "flutterhelm",
      "args": ["serve"]
    }
  }
}
```

## 命名の意図

`Helm` は「舵輪」「操舵」を意味します。  
FlutterHelm は、Flutter 開発フローをエージェントが**暴走せずに操舵する**ことを目指す名前です。
