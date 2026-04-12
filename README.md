# FlutterHelm

FlutterHelm は、**Flutter 開発向けの agent-safe な orchestration layer / MCP server** です。

狙いは、Flutter 開発で散在している以下の面を、AI エージェントにとって扱いやすい一貫した面へ整理することです。

- 公式 **Dart and Flutter MCP server**
- `flutter` CLI
- DevTools / Dart Tooling Daemon (DTD)
- 任意の runtime interaction driver
- iOS / Android の native debugger 連携面

FlutterHelm は、これらを置き換えるものではありません。  
**既存の正規インターフェースを束ね、セッション管理・安全制御・artifact/resource 管理を追加する**ための設計です。

## ステータス

- 状態: **Local alpha implementation**
- 実装: **Phase 3 profiling core is available in this repository**
- 実装前提: MCP client は最低でも **Tools** と **Resources** を扱えること
- 推奨: **Roots** を扱えること
- 初期 transport: **stdio-first**
- 主要スコープ: Flutter ローカル開発、実行中アプリの観測、テスト、profiling、限定的な runtime interaction

現在コードで実装されているのは Phase 3 のローカル反復面です。

- `workspace_discover`
- `analyze_project`
- `resolve_symbol`
- `format_files`
- `pub_search`
- `dependency_add`
- `dependency_remove`
- `workspace_show`
- `workspace_set_root`
- `session_open`
- `session_list`
- `device_list`
- `run_app`
- `attach_app`
- `stop_app`
- `get_logs`
- `get_runtime_errors`
- `get_widget_tree`
- `get_app_state_summary`
- `run_unit_tests`
- `run_widget_tests`
- `run_integration_tests`
- `get_test_results`
- `collect_coverage`
- `start_cpu_profile`
- `stop_cpu_profile`
- `capture_timeline`
- `capture_memory_snapshot`
- `toggle_performance_overlay`
- `serverInfo` / capability negotiation

dependency mutation は replay token approval を通して実行され、unit/widget/integration test は report/coverage resource を返します。
profiling は `vm_service` backend で動作し、`cpu://`, `timeline://`, `memory://`, `session://<id>/health` を返します。profiling mutation は owned session のみ許可され、local iOS simulator では debug session での検証を既定にしつつ `profile` mode を推奨します。
未実装なのは native bridge / runtime interaction です。
session metadata は `stateDir/sessions.json` に永続化され、artifact は `stateDir/artifacts/` に保存されます。live process handle 自体は process lifetime のみです。

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
- `platform_bridge`

current implementation では `profiling` workflow も既定で有効です。

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

## ローカル実行

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- dart analyze
mise exec -- dart test
mise exec -- dart run bin/flutterhelm.dart serve
```

config/state の既定配置は `~/.config/flutterhelm/` です。

- `config.yaml`
- `state.json`
- `sessions.json`
- `audit.jsonl`
- `artifacts/`

必要なら `--config` と `--state-dir` で上書きできます。

repo-local の deterministic fixture は `fixtures/sample_app/` にあります。

## 命名の意図

`Helm` は「舵輪」「操舵」を意味します。  
FlutterHelm は、Flutter 開発フローをエージェントが**暴走せずに操舵する**ことを目指す名前です。

## Harness

この repo には、design contract を実行可能な形で検証する self-contained な harness があります。

```bash
mise exec -- pnpm -C harness install
mise exec -- pnpm -C harness bootstrap
mise exec -- pnpm -C harness validate
mise exec -- pnpm -C harness smoke
mise exec -- pnpm -C harness contracts
mise exec -- pnpm -C harness runtime
mise exec -- pnpm -C harness profiling
mise exec -- pnpm -C harness qa
```

`bootstrap` は `harness/.venv-docs` に MkDocs を導入するため、global な `mkdocs` install は不要です。  
`smoke` / `contracts` / `runtime` を回す前に `mise trust && mise install && mise exec -- dart pub get` を済ませてください。  
report は `harness/reports/`、QA trace は `harness/traces/` に残ります。
`contracts` は package approval replay / coverage readback まで、`runtime` は macOS + Xcode simulator 前提で overflow 診断と integration test まで見ます。`profiling` は同じく local simulator 上で VM service-backed profiling capture と session health を見ます。
