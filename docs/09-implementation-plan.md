# Implementation Plan

この計画は「どう実装を始めるか」を具体化するものです。  
目的は、設計をそのままコードへ落とせる粒度まで分解することです。

## 1. Repository layout proposal

```text
flutterhelm/
├─ README.md
├─ mkdocs.yml
├─ pubspec.yaml
├─ bin/
│  └─ flutterhelm.dart
├─ lib/
│  ├─ server/
│  │  ├─ server.dart
│  │  ├─ capabilities.dart
│  │  └─ registry.dart
│  ├─ config/
│  │  ├─ config.dart
│  │  └─ profiles.dart
│  ├─ policies/
│  │  ├─ risk.dart
│  │  ├─ approvals.dart
│  │  ├─ roots.dart
│  │  └─ redaction.dart
│  ├─ sessions/
│  │  ├─ session.dart
│  │  ├─ session_store.dart
│  │  └─ health.dart
│  ├─ artifacts/
│  │  ├─ artifact.dart
│  │  ├─ resource_mapper.dart
│  │  └─ retention.dart
│  ├─ hardening/
│  │  ├─ operation_coordinator.dart
│  │  └─ tools.dart
│  ├─ adapters/
│  │  ├─ delegate/
│  │  │  └─ dart_flutter_mcp_delegate.dart
│  │  ├─ flutter_cli/
│  │  │  └─ flutter_cli_adapter.dart
│  │  ├─ dtd/
│  │  │  └─ dtd_adapter.dart
│  │  ├─ runtime_driver/
│  │  │  ├─ runtime_driver.dart
│  │  │  └─ null_driver.dart
│  │  └─ platform_bridge/
│  │     ├─ ios_bridge.dart
│  │     └─ android_bridge.dart
│  ├─ workflows/
│  │  ├─ workspace/
│  │  ├─ session/
│  │  ├─ launcher/
│  │  ├─ runtime_readonly/
│  │  ├─ tests/
│  │  ├─ profiling/
│  │  └─ platform_bridge/
│  ├─ util/
│  │  ├─ json.dart
│  │  ├─ paths.dart
│  │  └─ process.dart
│  └─ version.dart
├─ test/
│  ├─ contract/
│  ├─ policy/
│  ├─ sessions/
│  ├─ adapters/
│  └─ e2e/
└─ docs/
```

## 2. Module responsibilities

### `server/`

- MCP transport binding
- tool/resource registration
- request validation
- capability negotiation

### `policies/`

- risk classification
- approval token handling
- roots enforcement
- redaction

### `sessions/`

- session create/update
- state transitions
- session store
- ownership checks
- health evaluation

### `artifacts/`

- artifact manifest
- resource URI generation
- retention rules
- resource reads

### `adapters/`

- concrete integrations
- external process / protocol bindings
- normalization into internal DTOs

### `workflows/`

- business use-cases
- tool-level orchestration
- adapter selection
- policy invocation
- artifact publishing

## 3. Internal interfaces

## 3.1 Adapter interface example

```dart
abstract interface class FlutterRunner {
  Future<RunResult> run(RunRequest request);
  Future<AttachResult> attach(AttachRequest request);
  Future<void> stop(StopRequest request);
  Future<BuildResult> build(BuildRequest request);
  Future<List<DeviceInfo>> listDevices();
}
```

## 3.2 Delegate interface example

```dart
abstract interface class DartFlutterDelegate {
  Future<AnalyzeResult> analyze(AnalyzeRequest request);
  Future<SymbolResult> resolveSymbol(SymbolRequest request);
  Future<RuntimeErrorsResult> runtimeErrors(RuntimeErrorsRequest request);
  Future<WidgetTreeResult> widgetTree(WidgetTreeRequest request);
  Future<PackageSearchResult> searchPackages(PackageSearchRequest request);
  Future<DependencyMutationResult> addDependency(DependencyAddRequest request);
  Future<TestRunResult> runTests(TestRunRequest request);
}
```

## 3.3 Artifact publisher example

```dart
abstract interface class ArtifactPublisher {
  Future<ResourceDescriptor> publishJson({
    required Uri uri,
    required Map<String, Object?> payload,
    required String title,
  });

  Future<ResourceDescriptor> publishText({
    required Uri uri,
    required String payload,
    required String title,
  });
}
```

## 4. Configuration model

### Example

```yaml
version: 1
workspace:
  roots:
    - /work/app
defaults:
  target: lib/main.dart
  mode: debug
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - tests
  - profiling
fallbacks:
  allowRootFallback: false
retention:
  heavyArtifactsDays: 7
  metadataDays: 30
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
safety:
  confirmBefore:
    - dependency_add
    - dependency_remove
    - hot_restart
    - build_app:release
adapters:
  active:
    delegate: builtin.delegate.workspace
    flutterCli: builtin.flutter.cli
    profiling: builtin.profiling.vm_service
    runtimeDriver: builtin.runtime_driver.external_process
    platformBridge: builtin.platform_bridge.handoff
  providers:
    builtin.delegate.workspace:
      kind: builtin
      families: [delegate]
    builtin.flutter.cli:
      kind: builtin
      families: [flutterCli]
    builtin.profiling.vm_service:
      kind: builtin
      families: [profiling]
    builtin.runtime_driver.external_process:
      kind: builtin
      families: [runtimeDriver]
      command: npx
      args: ["-y", "@mobilenext/mobile-mcp@latest", "--stdio"]
      startupTimeoutMs: 5000
    builtin.platform_bridge.handoff:
      kind: builtin
      families: [platformBridge]
```

legacy adapter fields (`adapters.delegate`, `adapters.flutterCli`, `adapters.runtimeDriver`, `adapters.dtd`) は current implementation では shim で読み込み、上の registry shape に正規化します。

### Phase 0 / Phase 1 runtime paths

Phase 0 の実装では mutable state を repo 外へ逃がします。

- default config path: `~/.config/flutterhelm/config.yaml`
- default state path: `~/.config/flutterhelm/state.json`
- default audit log path: `~/.config/flutterhelm/audit.jsonl`
- override: `--config`, `--state-dir`, `FLUTTERHELM_CONFIG_PATH`, `FLUTTERHELM_STATE_DIR`

Phase 1 ではさらに以下を state dir 配下へ保存します。

- `sessions.json`
- `artifacts/sessions/<session-id>/...`
- `artifacts/test-runs/<run-id>/...`

live process handle と raw VM service URI は process lifetime のみで保持し、再起動後の session は `stale=true` として復元します。

Phase 3 ではさらに以下を追加します。

- `artifacts/sessions/<session-id>/cpu-profile-<capture-id>.json`
- `artifacts/sessions/<session-id>/timeline-<capture-id>.json`
- `artifacts/sessions/<session-id>/memory-<snapshot-id>.json`
- `artifacts/sessions/<session-id>/heap-snapshot-<snapshot-id>.json`

profiling backend は current implementation では `vm_service` 固定です。DTD は diagnostic metadata として保持しますが、profiling 実行の必須条件ではありません。

Phase 4 ではさらに以下を追加します。

- `artifacts/sessions/<session-id>/native-handoff-ios.json`
- `artifacts/sessions/<session-id>/native-handoff-android.json`

platform bridge backend は current implementation では `handoff_only` 固定です。bundle は JSON manifest として保存し、IDE automation は行いません。

Phase 5 ではさらに以下を追加します。

- `artifacts/sessions/<session-id>/screenshot-<capture-id>.png`
- `artifacts/sessions/<session-id>/screenshot-<capture-id>.jpg`

runtime interaction backend は current implementation では external adapter 固定です。`capture_screenshot` は `runtime_readonly` workflow に残し、resource read は binary `blob` payload を返します。

Phase 6 の Sprint 8 ではさらに以下を追加します。

- `artifacts/pins.json`
- `config://compatibility/current`
- profile overlay / fail-fast lock / age-based retention sweep

Phase 6 の Sprint 9 ではさらに以下を追加します。

- `config://adapters/current`
- `adapter_list`
- adapter registry with `adapters.active` / `adapters.providers`
- custom provider kind `stdio_json`
- transport-agnostic core + per-client session context
- `--transport http`
- `--http-host`
- `--http-port`
- `--http-path`

current implementation の HTTP preview は localhost-only / request-response only です。Roots transport は unsupported なので fallback semantics を前提にします。

current implementation では retention は server startup 時の age-based sweep で、pinned artifact は対象から外します。capacity-based LRU は次の sprint に送ります。

Phase 6 の Sprint 10 ではさらに以下を追加します。

- HTTP session idle expiry / cleanup
- preview transport failure normalization
- HTTP lifecycle tests

Phase 6 の Sprint 11 ではさらに以下を追加します。

- adapter provider lifecycle / lazy restart policy
- deprecation surface in adapter resources
- provider health backoff visibility

Phase 6 の Sprint 12 ではさらに以下を追加します。

- `0.1.0-phase6-beta` contract version
- migration notes / release discipline
- `beta` harness aggregate command

## 5. First sprint plan

### Sprint 1

- repo bootstrap
- stdio MCP server skeleton
- tool registry
- `workspace_show`
- `workspace_set_root`
- `session_open`
- config loading

### Sprint 2

- CLI adapter
- `device_list`
- `run_app`
- `attach_app`
- `stop_app`
- stdout/stderr capture
- session persistence

### Sprint 3

- delegate adapter
- `analyze_project`
- `get_runtime_errors`
- `get_widget_tree`
- resource store

### Sprint 4

- `run_unit_tests`
- `run_widget_tests`
- audit log
- approval model
- root fallback mode

### Sprint 5

- `start_cpu_profile`
- `stop_cpu_profile`
- `capture_timeline`
- `capture_memory_snapshot`
- `toggle_performance_overlay`
- `session://<id>/health`
- owned-session profiling guard

### Sprint 6

- `ios_debug_context`
- `android_debug_context`
- `native_handoff_summary`
- `native-handoff://<session-id>/ios|android`
- iOS local network permission hypothesis
- handoff-only platform bridge capability metadata

### Sprint 7

- `tap_widget`
- `enter_text`
- `scroll_until_visible`
- `capture_screenshot`
- `hot_reload`
- `hot_restart`
- `session://<id>/health` runtime driver fields
- semantic locator contract
- opt-in runtime interaction workflow

### Sprint 8

- session/workspace fail-fast lock
- `artifact_pin`
- `artifact_unpin`
- `artifact_pin_list`
- `config://artifacts/pins`
- `compatibility_check`
- `config://compatibility/current`
- config profile overlay
- startup retention sweep skipping pinned artifacts

### Sprint 9

- transport-agnostic core with stdio/http session context
- `adapter_list`
- `config://adapters/current`
- `adapters.active`
- `adapters.providers`
- custom provider kind `stdio_json`
- legacy adapter config shim
- `--transport http`
- `--http-host`
- `--http-port`
- `--http-path`
- localhost-only Streamable HTTP preview
- fallback-only root flow for HTTP preview

### Sprint 10

- HTTP session idle expiry / cleanup
- preview transport failure normalization
- HTTP lifecycle contract tests

### Sprint 11

- adapter provider lifecycle / lazy restart policy
- deprecation surface in adapter resources
- provider health backoff visibility

### Sprint 12

- `0.1.0-phase6-beta` contract version
- migration notes / release discipline
- `beta` harness aggregate command

## 6. Test strategy

## 6.1 Unit tests

対象:

- risk classification
- path validation
- session state transitions
- URI generation
- retention policy

## 6.2 Contract tests

対象:

- tool schemas
- error shapes
- resource descriptors
- approval flow

## 6.3 Adapter tests

対象:

- CLI parsing
- delegate normalization
- DTD connection handling
- failure fallback

## 6.4 End-to-end tests

対象:

- sample Flutter app on local simulator/emulator
- run → inspect → stop
- test → report → coverage
- profile capture lifecycle
- attached/stale session profiling rejection
- native handoff bundle generation and postmortem reuse
- semantic runtime interaction on iOS simulator

## 7. Sample E2E acceptance scenario

### Scenario: Layout error diagnosis loop

1. `fixtures/sample_app` を `FLUTTERHELM_SCENARIO=overflow` で起動する
2. `get_runtime_errors` で overflow を検出する
3. `get_widget_tree` resource を取得する
4. `attach_app` で readonly attach session を作る
5. attached session に対する `stop_app` が拒否されることを確認する
6. owned session に対して `stop_app` を実行する

## 8. Observability plan

- JSON logs for all tool invocations
- approval events
- adapter timings
- session lifecycle changes
- resource publication metrics
- error category counters

## 9. Migration / compatibility approach

- server exposes version and contract version
- breaking changes require migration notes and a visible deprecation surface
- optional capabilities are discoverable
- workflows unavailable on current platform are hidden or reported as disabled

## 10. 実装上の重要な節度

最初の実装で避けるべきことは次です。

- shell command gateway を一般公開すること
- UI automation を core 設計と密結合すること
- logging / artifacts を後回しにすること
- approval policy を各 tool に散らすこと

FlutterHelm の実装は、派手な機能よりも  
**session, resource, policy, adapter boundary** を最初に固める方が成功率が高いです。
