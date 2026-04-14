# User Guide

このページは、FlutterHelm を **実際に使い始める人向け** の入口です。  
内部設計や full contract を読む前に、まず **何が stable で、どう起動して、どの順で使うか** を掴めるようにしています。

## 1. まず把握すること

FlutterHelm は、Flutter 開発向けの orchestration layer / MCP server です。  
`flutter` CLI、`vm_service`、native debugger、optional driver をまとめつつ、session / resource / safety contract を揃えます。

最初の前提は次です。

- 既定 transport は `stdio`
- 推奨の始め方も `stdio`
- heavy output は tool result ではなく Resource で読む
- mutation は approval や ownership policy を伴う

## 2. Support Levels

| Surface | Support level | Notes |
|---|---|---|
| `stdio` transport | `stable` | 推奨の開始地点 |
| core workflows (`workspace`, `session`, `launcher`, `runtime_readonly`, `tests`, `profiling`, `platform_bridge`) | `stable` | built-in adapter path を前提 |
| `runtime_interaction` | `beta` | opt-in workflow |
| custom `stdio_json` providers | `beta` | adapter registry 経由で有効化 |
| HTTP transport | `preview` | localhost-only, request-response only |

support level の詳細は [Migration Notes](10-migration-notes.md) と [MCP Contract](04-mcp-contract.md) を参照してください。

stable lane の diagnostics は built-in delegate を通して official Flutter MCP を優先利用します。delegate が unavailable / timeout / malformed payload になった場合だけ current CLI / vm_service backend に自動 fallback します。

## 3. 最短セットアップ

### 3.1 ローカル準備

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- dart analyze
mise exec -- dart test
```

### 3.2 server を起動する

```bash
mise exec -- dart run bin/flutterhelm.dart serve
```

### 3.3 MCP client 設定の最小例

```json
{
  "mcpServers": {
    "flutterhelm": {
      "command": "mise",
      "args": [
        "exec",
        "--",
        "dart",
        "run",
        "bin/flutterhelm.dart",
        "serve"
      ]
    }
  }
}
```

## 4. 最初の接続確認

最初は次の順で確認するのが安全です。

1. `workspace_show`
2. `workspace_discover`
3. `workspace_set_root`
4. `session_open` または `run_app`

`workspace_show` では少なくとも次を見ます。

- `activeProfile`
- `availableProfiles`
- `transportMode`
- `rootsTransportSupport`
- `compatibilityResource`
- `adaptersResource`

`workspace_set_root` が通れば、その後の session 系と run/test 系が安定します。  
client が Roots を十分に渡せない場合は、`--allow-root-fallback` を明示的に使います。

## 5. アプリを起動して診断する

日常的な起点は `run_app` です。

```json
{
  "platform": "ios",
  "target": "lib/main.dart",
  "mode": "debug"
}
```

起動後は `sessionId` を軸に、次の read-only tool を回します。

- `get_logs`
- `get_runtime_errors`
- `get_widget_tree`
- `get_app_state_summary`
- `capture_screenshot`

重い出力は Resource として読みます。

- `log://<session-id>/stdout`
- `log://<session-id>/stderr`
- `runtime-errors://<session-id>/current`
- `widget-tree://<session-id>/current?depth=3`
- `app-state://<session-id>/summary`
- `screenshot://<session-id>/<capture-id>.png`

session の詳細や制約は [Session and Resources](05-session-and-resources.md) にあります。

## 6. テストと Coverage

stable lane では次を使います。

- `run_unit_tests`
- `run_widget_tests`
- `run_integration_tests`
- `get_test_results`
- `collect_coverage`

coverage が必要な場合は、test run 側で `coverage=true` を付けます。  
結果は主に次の Resource で読みます。

- `test-report://<run-id>/summary`
- `test-report://<run-id>/details`
- `coverage://<run-id>/summary`
- `coverage://<run-id>/lcov`

まずは unit/widget test から始め、integration test は device / simulator 前提が整ってから使うのが安全です。

## 7. Profiling を取る

profiling は `stable` ですが、実際には **owned session + live VM service** が前提です。  
迷ったら `run_app(mode=profile)` ではなく、まず通常の debug session で接続性を確認してから profiling に進めます。

主な tool は次です。

- `start_cpu_profile`
- `stop_cpu_profile`
- `capture_timeline`
- `capture_memory_snapshot`
- `toggle_performance_overlay`

profiling artifact は次で読みます。

- `cpu://<session-id>/<capture-id>`
- `timeline://<session-id>/<capture-id>`
- `memory://<session-id>/<snapshot-id>`
- `session://<session-id>/health`

`session://<session-id>/health` は、profiling や runtime interaction が使えない理由を確認する時の最初の参照先です。

## 8. Native 側へ handoff する

FlutterHelm は native debugger を置き換えません。  
必要な文脈を bundle にまとめて、Xcode / Android Studio に handoff するために使います。

使う tool は次です。

- `ios_debug_context`
- `android_debug_context`
- `native_handoff_summary`

主な output は次です。

- `native-handoff://<session-id>/ios`
- `native-handoff://<session-id>/android`

これらの bundle には、open path、evidence resource、hypothesis、next step がまとまります。

## 9. Beta 機能を有効にする

### 9.1 `runtime_interaction`

`runtime_interaction` は既定では無効です。  
有効化すると次が露出します。

- `tap_widget`
- `enter_text`
- `scroll_until_visible`
- `hot_reload`
- `hot_restart`

例:

```yaml
version: 1
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
    runtimeDriver: builtin.runtime_driver.external_process
```

`runtimeDriver` を explicit に選ぶと、selected provider は自動的に有効化されます。  
逆に明示的に無効化したい場合だけ、provider 側で `options.enabled: false` を指定します。

```yaml
adapters:
  providers:
    builtin.runtime_driver.external_process:
      kind: builtin
      families:
        - runtimeDriver
      options:
        enabled: false
```

接続確認は `session://<session-id>/health` で行います。  
特に見る field は次です。

- `runtimeInteractionReady`
- `screenshotReady`
- `driverConnected`
- `supportedLocatorFields`

`capture_screenshot` の result には `backend`, `driverConnected`, `fallbackUsed`, `fallbackReason?` が含まれます。  
driver 接続中でも `fallbackUsed=true` なら、最終的な screenshot は fallback backend で取得されています。

### 9.2 custom `stdio_json` provider

custom provider も `beta` です。  
stable cut では legacy adapter fields は削除済みなので、`adapters.active` / `adapters.providers` を使います。

```yaml
version: 1
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

active provider と support level は次で確認します。

- `adapter_list`
- `config://adapters/current`
- `compatibility_check`

### 9.3 `native_build` (beta)

native build orchestration は beta として利用できます。  
まだ stable lane には入りませんが、Sprint 16 で iOS-first の build / launch / Flutter runtime attach を扱う `native_build` workflow と `nativeBuild` adapter family が追加されています。

予定されている入口は次です。

- `native_project_inspect`
- `native_build_launch`
- `native_attach_flutter_runtime`
- `native_stop`

導線としては、`ios_debug_context` / `native_handoff_summary` で native 側へ渡す文脈を整えつつ、必要なら `native_build_launch` / `native_attach_flutter_runtime` で同じ session に native launch と Flutter runtime attach を相関させます。検証は `native-build` harness lane を使います。

## 10. HTTP preview はどう扱うか

HTTP transport は **preview** です。  
最初の導入経路には使わず、`stdio` が合わない事情がある時だけ検討してください。

現時点の制約は次です。

- localhost-only
- request-response only
- `GET` / SSE / resume なし
- Roots transport は unsupported
- write tool は fallback semantics に従う

詳細は [Migration Notes](10-migration-notes.md) と [ADR-002: Transport and Roots](adrs/ADR-002-transport-roots.md) を参照してください。

## 11. 日常運用で見る resource

困った時は、次の read-only resource を先に見ると状況を掴みやすいです。

- `config://workspace/current`
- `config://compatibility/current`
- `config://adapters/current`
- `config://artifacts/status`
- `config://observability/current`
- `config://artifacts/pins`

## 12. 次に読むページ

- 使い方の失敗モードを知りたい: [Troubleshooting](12-troubleshooting.md)
- tool schema と support boundary を確認したい: [MCP Contract](04-mcp-contract.md)
- session / resource の意味を詳しく見たい: [Session and Resources](05-session-and-resources.md)
- stable/beta/preview の境界を確認したい: [Migration Notes](10-migration-notes.md)
