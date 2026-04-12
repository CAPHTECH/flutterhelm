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
fallbacks:
  allowRootFallback: false
retention:
  heavyArtifactsDays: 7
  metadataDays: 30
safety:
  confirmBefore:
    - dependency_add
    - dependency_remove
    - hot_restart
    - build_app:release
adapters:
  delegate:
    type: dart_flutter_mcp
  flutterCli:
    executable: flutter
  dtd:
    enabled: true
  runtimeDriver:
    enabled: false
```

### Phase 0 runtime paths

Phase 0 の実装では mutable state を repo 外へ逃がします。

- default config path: `~/.config/flutterhelm/config.yaml`
- default state path: `~/.config/flutterhelm/state.json`
- default audit log path: `~/.config/flutterhelm/audit.jsonl`
- override: `--config`, `--state-dir`, `FLUTTERHELM_CONFIG_PATH`, `FLUTTERHELM_STATE_DIR`

なお、Phase 0 で永続化されるのは active root と audit log のみです。  
session は process lifetime の in-memory store に留めます。

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

## 7. Sample E2E acceptance scenario

### Scenario: Layout error diagnosis loop

1. sample app を起動する
2. known overflow screen へ遷移する
3. `get_runtime_errors` で overflow を検出する
4. `get_widget_tree` resource を取得する
5. agent が修正案を提示する
6. 人間承認の上で code patch を適用する
7. `hot_reload`
8. 再度 `get_runtime_errors` を取り、解消を確認する

## 8. Observability plan

- JSON logs for all tool invocations
- approval events
- adapter timings
- session lifecycle changes
- resource publication metrics
- error category counters

## 9. Migration / compatibility approach

- server exposes version and contract version
- breaking changes require migration notes
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
