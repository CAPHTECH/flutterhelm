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

## Start Here

- 日常的な使い方と最短セットアップ: [User Guide](docs/11-user-guide.md)
- 失敗モードと対処: [Troubleshooting](docs/12-troubleshooting.md)
- stable / beta / preview の境界と移行: [Migration Notes](docs/10-migration-notes.md)

## ステータス

- 状態: **Local stable-ready implementation with Phase 6 hardening complete**
- 実装: **Phase 5 optional runtime interaction + Sprint 8-15 hardening / ecosystem / stable-release discipline are available in this repository**
- public contract version: `0.2.0-stable`
- 実装前提: MCP client は最低でも **Tools** と **Resources** を扱えること
- 推奨: **Roots** を扱えること
- 初期 transport: **stdio-first**
- 主要スコープ: Flutter ローカル開発、実行中アプリの観測、テスト、profiling、native handoff

現在コードで実装されているのは Phase 5 のローカル反復面に、Sprint 8-15 の hardening / ecosystem / stable release discipline を足した面です。

- `workspace_discover`
- `analyze_project`
- `resolve_symbol`
- `format_files`
- `pub_search`
- `dependency_add`
- `dependency_remove`
- `workspace_show`
- `compatibility_check`
- `adapter_list`
- `workspace_set_root`
- `session_open`
- `session_list`
- `artifact_pin`
- `artifact_unpin`
- `artifact_pin_list`
- `device_list`
- `run_app`
- `attach_app`
- `stop_app`
- `capture_screenshot`
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
- `ios_debug_context`
- `android_debug_context`
- `native_handoff_summary`
- `tap_widget`
- `enter_text`
- `scroll_until_visible`
- `hot_reload`
- `hot_restart`
- `serverInfo` / capability negotiation

dependency mutation は replay token approval を通して実行され、unit/widget/integration test は report/coverage resource を返します。
profiling は `vm_service` backend で動作し、`cpu://`, `timeline://`, `memory://`, `session://<id>/health` を返します。profiling mutation は owned session のみ許可され、local iOS simulator では debug session での検証を既定にしつつ `profile` mode を推奨します。
platform bridge は handoff-only で動作し、`native-handoff://<session-id>/ios|android` bundle を返します。これは native debugger を置き換えるものではなく、Xcode / Android Studio に持ち込むための文脈束です。
runtime interaction は external adapter backend で実装されていますが、workflow は opt-in のままです。`tap_widget`, `enter_text`, `scroll_until_visible`, `hot_reload`, `hot_restart` は `runtime_interaction` を有効化した時だけ露出します。`capture_screenshot` は `runtime_readonly` に残し、driver 未接続時は iOS simulator なら `simctl` fallback を使います。
session metadata は `stateDir/sessions.json` に永続化され、artifact は `stateDir/artifacts/` に保存されます。live process handle 自体は process lifetime のみです。
Sprint 8 では fail-fast concurrency handling、file-backed artifact pinning、config profile overlay、compatibility preflight を追加しています。競合する mutation は `SESSION_BUSY` / `WORKSPACE_BUSY` で即座に拒否され、pin 済み artifact は startup retention sweep の対象から外れます。
Sprint 9 では adapter registry を導入し、`config://adapters/current` と `adapter_list` で active provider/family health を見られるようにしました。transport は引き続き `stdio-first` ですが、localhost 限定の `--transport http` preview も追加しています。HTTP preview は request-response only で、SSE/resume は未対応、Roots transport は unsupported のため fallback semantics に従います。
Sprint 13-15 では support level taxonomy、artifact capacity retention、operability resources、stable lane を追加しました。`stdio` は stable、runtime interaction と custom `stdio_json` provider は beta、HTTP transport は preview のままです。legacy adapter config は stable cut で削除済みです。

## なぜ別レイヤが必要か

公式の Dart and Flutter MCP server はすでに強力ですが、設計上は次の性格があります。

- 公式サーバー自体は **experimental** で、今後も変化しうる
- Flutter の標準実行面は依然として `flutter` CLI
- profiling / debugging の主要面は DevTools
- native code の深掘りは Xcode / Android Studio などの native debugger
- MCP では、巨大な runtime 出力は **Resources** として分離した方が文脈効率がよい

したがって FlutterHelm の役割は、**「個々のツールを増やすこと」より「責務を整理し、安定した contract を与えること」**にあります。

## ドキュメント構成

- [User Guide](docs/11-user-guide.md)
- [Troubleshooting](docs/12-troubleshooting.md)
- [Migration Notes](docs/10-migration-notes.md)
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

current implementation では `profiling` と `platform_bridge` workflow も既定で有効です。`runtime_interaction` は実装済みですが既定では無効です。

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
mise exec -- pnpm -C harness beta
```

config/state の既定配置は `~/.config/flutterhelm/` です。

- `config.yaml`
- `state.json`
- `sessions.json`
- `audit.jsonl`
- `artifacts/`

必要なら `--config`, `--state-dir`, `--profile` で上書きできます。`FLUTTERHELM_PROFILE` でも profile を選べます。

HTTP preview を使う場合は次を追加します。

```bash
mise exec -- dart run bin/flutterhelm.dart serve \
  --transport http \
  --http-host 127.0.0.1 \
  --http-port 0 \
  --http-path /mcp
```

主な preview 用 flag は `--transport http`, `--http-host`, `--http-port`, `--http-path` です。

HTTP preview は localhost-only の preview です。`MCP-Session-Id` ベースの session は持ちますが、Roots transport は扱わず、write tool は `--allow-root-fallback` と explicit root selection に従います。

`profiles.<name>` overlay を config に定義すると、workflow/adapters/fallbacks/retention などを切り替えられます。

```yaml
version: 1
profiles:
  interactive:
    enabledWorkflows:
      - workspace
      - session
      - launcher
      - runtime_readonly
      - tests
      - profiling
      - platform_bridge
      - runtime_interaction
    adapters:
      active:
        runtimeDriver: local.fake.runtimeDriver
      providers:
        local.fake.runtimeDriver:
          kind: stdio_json
          families:
            - runtimeDriver
          command: dart
          args:
            - run
            - tool/fake_stdio_adapter_provider.dart
          startupTimeoutMs: 5000
```

legacy adapter fields は stable cut で削除したため、current implementation では `adapters.active` / `adapters.providers` のみを受け付けます。
custom provider kind は `stdio_json` です。active provider 状態と support level は `adapter_list` / `config://adapters/current` / `compatibility_check` で確認できます。

hardening / ecosystem 系の read-only resource として、`config://compatibility/current`、`config://artifacts/pins`、`config://artifacts/status`、`config://observability/current`、`config://adapters/current` も公開されます。release / migration notes は `docs/10-migration-notes.md` にまとまっています。

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
mise exec -- pnpm -C harness bridge
mise exec -- pnpm -C harness interaction
mise exec -- pnpm -C harness hardening
mise exec -- pnpm -C harness ecosystem
mise exec -- pnpm -C harness stable
mise exec -- pnpm -C harness beta
mise exec -- pnpm -C harness qa
```

`bootstrap` は `harness/.venv-docs` に MkDocs を導入するため、global な `mkdocs` install は不要です。  
`smoke` / `contracts` / `runtime` を回す前に `mise trust && mise install && mise exec -- dart pub get` を済ませてください。  
report は `harness/reports/`、QA trace は `harness/traces/` に残ります。
`contracts` は package approval replay / coverage readback / platform bridge exposure / Phase 5 capability metadata まで、`runtime` は macOS + Xcode simulator 前提で overflow 診断と integration test まで見ます。`profiling` は同じく local simulator 上で VM service-backed profiling capture と session health を見ます。`bridge` は iOS native handoff bundle と synthetic Android handoff contract を見ます。`interaction` は opt-in runtime driver を有効にして screenshot / semantic tap-text-scroll / hot reload-restart / attached-session guard を見ます。`hardening` は profile overlay, compatibility preflight, artifact pin lifecycle, capacity-aware retention, support-level metadata, busy rejection を見ます。`ecosystem` は adapter registry visibility と localhost-only HTTP preview session flow を見ます。`stable` は stable support lane だけをまとめて回す集約コマンドで、`beta` は上記に ecosystem / interaction を加えた superset です。
