# MCP Contract

## 1. Contract の目的

FlutterHelm の contract は、単なる tool 一覧ではありません。  
目的は次の 3 つです。

1. AI client にとって discoverable であること
2. heavy output を resource へ逃がせること
3. risk の高い操作を分類し、人間確認を入れやすいこと

## 2. Supported MCP Features

### Server features

- Tools
- Resources
- Logging utilities
- Progress / status notifications
- Versioned capabilities

### Client features expected

- Tools invocation
- Resources read
- Roots support が望ましい
- Roots 非対応 client 向け fallback は opt-in

### Current local alpha surface

この repository の current implementation は Phase 5 に Sprint 8 hardening core を足した状態です。

- `workspace`, `session`, `launcher`, `runtime_readonly`, `tests` workflow を local で実装
- package search / dependency mutation approval replay / integration tests / coverage readback を含む
- profiling workflow を local で実装し、backend は `vm_service`、policy は owned-session only
- platform bridge workflow を local で実装し、mode は `handoff_only`、IDE automation は行わない
- runtime interaction workflow を local で実装し、UI backend は external adapter、hot op backend は `flutter run --machine`
- hardening core を local で実装し、busy policy は `fail_fast`、artifact pinning と config profile overlay と compatibility preflight を含む
- transport は `stdio-first`

## 3. Workflow Groups

| Workflow | 目的 | 初期有効 |
|---|---|---|
| `workspace` | root, analysis, package search, formatting | Yes |
| `session` | session lifecycle | Yes |
| `launcher` | device list, run, attach, stop, build | Yes |
| `runtime_readonly` | errors, widget tree, logs, summaries | Yes |
| `tests` | unit/widget/integration tests, coverage | Yes |
| `runtime_interaction` | tap, text, scroll, hot ops | No |
| `profiling` | CPU, memory, timeline, overlay | Yes |
| `platform_bridge` | iOS / Android native context | Yes |

## 4. Tool Catalog

## 4.1 workspace

| Tool | Risk | 説明 |
|---|---|---|
| `workspace_discover` | read_only | Flutter workspace 候補を列挙 |
| `workspace_set_root` | bounded_mutation | active root を設定 |
| `workspace_show` | read_only | 現在の root / flavor / defaults を表示 |
| `compatibility_check` | read_only | 現在の実行環境 compatibility matrix を返す |
| `analyze_project` | read_only | static analysis を実行 |
| `resolve_symbol` | read_only | symbol 情報解決 |
| `format_files` | project_mutation | 対象 file を format |
| `pub_search` | read_only_network | package 候補を検索 |
| `dependency_add` | project_mutation | dependency を追加 |
| `dependency_remove` | project_mutation | dependency を削除 |

## 4.2 session

| Tool | Risk | 説明 |
|---|---|---|
| `session_open` | bounded_mutation | workspace / target / mode の文脈を開く |
| `session_show` | read_only | session 詳細 |
| `session_list` | read_only | active sessions 一覧 |
| `artifact_pin` | bounded_mutation | file-backed artifact を pin する |
| `artifact_unpin` | bounded_mutation | pin を外す |
| `artifact_pin_list` | read_only | pin 状態を一覧する |
| `session_close` | bounded_mutation | session を閉じる |

## 4.3 launcher

| Tool | Risk | 説明 |
|---|---|---|
| `device_list` | read_only | 接続デバイス一覧 |
| `run_app` | runtime_control | app 起動 |
| `attach_app` | runtime_control | 実行中 app に attach |
| `stop_app` | runtime_control | session 管理下プロセス停止 |
| `build_app` | build_control | platform/mode 指定 build |

## 4.4 runtime_readonly

| Tool | Risk | 説明 |
|---|---|---|
| `get_runtime_errors` | read_only | 現在の runtime errors |
| `get_widget_tree` | read_only | widget tree snapshot |
| `get_logs` | read_only | session logs 取得 |
| `get_app_state_summary` | read_only | high-level 状態要約 |
| `capture_screenshot` | bounded_mutation | screenshot を resource 化 |

## 4.5 tests

| Tool | Risk | 説明 |
|---|---|---|
| `run_unit_tests` | test_execution | unit test 実行 |
| `run_widget_tests` | test_execution | widget test 実行 |
| `run_integration_tests` | test_execution | integration test 実行 |
| `get_test_results` | read_only | 既存 test run の結果参照 |
| `collect_coverage` | read_only | 既存 coverage artifact 読み出し |

## 4.6 profiling

| Tool | Risk | 説明 |
|---|---|---|
| `start_cpu_profile` | runtime_control | CPU profile capture 開始 |
| `stop_cpu_profile` | runtime_control | CPU profile capture 終了 |
| `capture_memory_snapshot` | runtime_control | memory snapshot |
| `capture_timeline` | runtime_control | timeline capture |
| `toggle_performance_overlay` | runtime_control | performance overlay 切替 |

current implementation では profiling backend は `vm_service` です。  
attached / stale / release session に対する profiling tool は structured error と `session://<id>/health` を返します。

## 4.7 runtime_interaction

| Tool | Risk | 説明 |
|---|---|---|
| `tap_widget` | runtime_control | semantic locator で tap |
| `enter_text` | runtime_control | text input |
| `scroll_until_visible` | runtime_control | widget が見えるまで scroll |
| `hot_reload` | runtime_control | hot reload |
| `hot_restart` | state_destructive | hot restart |

current implementation では runtime interaction は opt-in workflow です。  
UI actions は external adapter backend、`capture_screenshot` は `runtime_readonly` workflow、hot reload / restart は owned session 上の `flutter run --machine` backend を使います。

## 4.8 platform_bridge

| Tool | Risk | 説明 |
|---|---|---|
| `ios_debug_context` | read_only | Xcode 側に持ち込む文脈束生成 |
| `android_debug_context` | read_only | Android Studio 側に持ち込む文脈束生成 |
| `native_handoff_summary` | read_only | 共通 native handoff 要約 |

current implementation では platform bridge は `handoff_only` です。
`native-handoff://...` bundle を生成しますが、Xcode / Android Studio / adb の自動操作は行いません。

## 4.9 hardening capability metadata

current implementation は capability metadata に次を含みます。

- `experimental.hardening.busyPolicy = fail_fast`
- `experimental.hardening.pinnedArtifacts = true`
- `experimental.hardening.configProfiles = true`
- `experimental.hardening.compatibilityResource = config://compatibility/current`

競合する mutation は queue せず、`SESSION_BUSY` または `WORKSPACE_BUSY` で即時失敗します。

## 5. Sample Tool Schemas

## 5.1 `run_app`

```json
{
  "name": "run_app",
  "inputSchema": {
    "type": "object",
    "properties": {
      "workspaceRoot": { "type": "string" },
      "sessionId": { "type": "string" },
      "target": { "type": "string", "default": "lib/main.dart" },
      "platform": {
        "type": "string",
        "enum": ["ios", "android", "macos", "linux", "windows", "web"]
      },
      "deviceId": { "type": "string" },
      "flavor": { "type": "string" },
      "mode": {
        "type": "string",
        "enum": ["debug", "profile", "release"],
        "default": "debug"
      },
      "dartDefines": {
        "type": "array",
        "items": { "type": "string" }
      }
    },
    "required": ["platform"]
  }
}
```

### Response

```json
{
  "sessionId": "sess_01H...",
  "state": "running",
  "platform": "ios",
  "mode": "debug",
  "deviceId": "00008110-...",
  "pid": 18342,
  "vmService": {
    "available": true,
    "maskedUri": "ws://127.0.0.1:.../ws"
  },
  "dtd": {
    "available": false
  },
  "resources": [
    {
      "uri": "session://sess_01H/summary",
      "mimeType": "application/json",
      "title": "Session summary"
    },
    {
      "uri": "log://sess_01H/stdout",
      "mimeType": "text/plain",
      "title": "Startup logs"
    }
  ]
}
```

## 5.2 `get_widget_tree`

```json
{
  "name": "get_widget_tree",
  "inputSchema": {
    "type": "object",
    "properties": {
      "sessionId": { "type": "string" },
      "depth": { "type": "integer", "minimum": 1, "maximum": 12, "default": 3 },
      "includeProperties": { "type": "boolean", "default": false }
    },
    "required": ["sessionId"]
  }
}
```

### Response

```json
{
  "sessionId": "sess_01H...",
  "resource": {
    "uri": "widget-tree://sess_01H/current?depth=3",
    "mimeType": "application/json",
    "title": "Widget tree snapshot"
  },
  "summary": {
    "rootWidget": "MaterialApp",
    "nodeCountApprox": 214,
    "captureTime": "2026-04-11T12:34:56Z"
  }
}
```

## 5.3 `dependency_add`

```json
{
  "name": "dependency_add",
  "inputSchema": {
    "type": "object",
    "properties": {
      "workspaceRoot": { "type": "string" },
      "package": { "type": "string" },
      "versionConstraint": { "type": "string" },
      "devDependency": { "type": "boolean", "default": false },
      "approvalToken": { "type": "string" }
    },
    "required": ["package"]
  }
}
```

### Response (approval required)

```json
{
  "status": "approval_required",
  "risk": "project_mutation",
  "reason": "This action will modify pubspec.yaml and may fetch packages from the network.",
  "approvalRequestId": "apr_01H..."
}
```

## 5.4 `run_integration_tests`

```json
{
  "name": "run_integration_tests",
  "inputSchema": {
    "type": "object",
    "properties": {
      "workspaceRoot": { "type": "string" },
      "platform": {
        "type": "string",
        "enum": ["ios", "android", "macos", "linux", "windows", "web"]
      },
      "deviceId": { "type": "string" },
      "target": { "type": "string" },
      "flavor": { "type": "string" },
      "coverage": { "type": "boolean", "default": false }
    },
    "required": ["platform", "target"]
  }
}
```

## 5.5 `artifact_pin`

```json
{
  "name": "artifact_pin",
  "inputSchema": {
    "type": "object",
    "properties": {
      "uri": { "type": "string" },
      "label": { "type": "string" }
    },
    "required": ["uri"]
  }
}
```

### Response

```json
{
  "uri": "screenshot://sess_01H/capture_01H.png",
  "kind": "screenshot",
  "status": "present",
  "present": true,
  "label": "keep-for-debug",
  "pinnedAt": "2026-04-13T00:00:00Z",
  "updatedAt": "2026-04-13T00:00:00Z",
  "sessionId": "sess_01H..."
}
```

## 5.6 `compatibility_check`

```json
{
  "name": "compatibility_check",
  "inputSchema": {
    "type": "object",
    "properties": {
      "profile": { "type": "string" }
    }
  }
}
```

### Response

```json
{
  "profile": "interactive",
  "availableProfiles": ["interactive"],
  "workspaceRoot": "/work/app",
  "environment": {
    "os": "macos",
    "dartVersion": "3.11.0"
  },
  "checks": {
    "flutterCli": {
      "supported": true,
      "status": "ok",
      "requirements": ["flutter must be available on PATH."]
    }
  },
  "workflows": {
    "runtime_interaction": {
      "configured": true,
      "supported": true,
      "status": "ok"
    }
  }
}
```

## 5.5 `ios_debug_context`

```json
{
  "name": "ios_debug_context",
  "inputSchema": {
    "type": "object",
    "properties": {
      "sessionId": { "type": "string" },
      "tailLines": { "type": "integer", "minimum": 20, "maximum": 1000, "default": 200 }
    },
    "required": ["sessionId"]
  }
}
```

## 5.6 `tap_widget`

```json
{
  "name": "tap_widget",
  "inputSchema": {
    "type": "object",
    "properties": {
      "sessionId": { "type": "string" },
      "locator": {
        "type": "object",
        "properties": {
          "text": { "type": "string" },
          "textContains": { "type": "string" },
          "label": { "type": "string" },
          "labelContains": { "type": "string" },
          "valueKey": { "type": "string" },
          "type": { "type": "string" },
          "index": { "type": "integer", "minimum": 0 },
          "visibleOnly": { "type": "boolean", "default": true }
        }
      },
      "timeoutMs": { "type": "integer", "minimum": 0, "default": 3000 }
    },
    "required": ["sessionId", "locator"]
  }
}
```

### Response

```json
{
  "sessionId": "sess_01H...",
  "status": "completed",
  "match": {
    "x": 201,
    "y": 585,
    "visible": true,
    "text": "Deep action",
    "label": "Deep action",
    "type": "Button"
  }
}
```

## 5.7 `run_integration_tests`

```json
{
  "sessionId": "sess_01H...",
  "platform": "ios",
  "status": "ready",
  "summary": {
    "sessionState": "running",
    "ownership": "owned",
    "availablePlatforms": ["ios"],
    "evidenceCount": 6,
    "hypothesisCount": 2
  },
  "resource": {
    "uri": "native-handoff://sess_01H/ios",
    "mimeType": "application/json",
    "title": "iOS native handoff bundle"
  }
}
```

### Response

```json
{
  "runId": "test_01H...",
  "status": "completed",
  "summary": {
    "passed": 24,
    "failed": 1,
    "skipped": 0,
    "durationMs": 128443
  },
  "resources": [
    {
      "uri": "test-report://test_01H/summary",
      "mimeType": "application/json",
      "title": "Integration test summary"
    },
    {
      "uri": "log://test_01H/stdout",
      "mimeType": "text/plain",
      "title": "Integration test logs"
    }
  ]
}
```

## 6. Resource Types

| URI Scheme | 内容 |
|---|---|
| `session://` | session metadata |
| `config://` | workspace / defaults / config snapshots |
| `log://` | stdout / stderr / structured logs |
| `runtime-errors://` | current runtime errors |
| `widget-tree://` | widget hierarchy snapshot |
| `cpu://` | CPU profile captures |
| `timeline://` | performance timeline |
| `memory://` | memory snapshots / diffs |
| `test-report://` | test result summary / details |
| `coverage://` | coverage outputs |
| `build://` | build manifest, outputs metadata |
| `screenshot://` | PNG / JPEG screenshot artifacts |
| `native-handoff://` | native debugger handoff package |

## 7. Error Model

Tool failure は以下の形に正規化します。

```json
{
  "error": {
    "code": "SESSION_STALE",
    "category": "runtime",
    "message": "The target session is no longer attached to a live Flutter process.",
    "retryable": true,
    "detailsResource": {
      "uri": "log://sess_01H/stderr",
      "mimeType": "text/plain"
    }
  }
}
```

### Error categories

- `validation`
- `roots`
- `workspace`
- `delegate`
- `runtime`
- `profiling`
- `platform_bridge`

### Capability notes

current implementation の `capabilities.experimental.platformBridge` は以下を返します。

- `mode: handoff_only`
- `ideAutomation: false`
- `supportedPlatforms: ["ios", "android"]`
- `defaultEnabled: true`

current implementation の `capabilities.experimental.runtimeInteraction` は以下を返します。

- `defaultEnabled: false`
- `uiBackend: external_adapter`
- `hotOpBackend: flutter_daemon`
- `screenshotWorkflow: runtime_readonly`
- `hotOpsOwnershipPolicy: owned_only`

## 8. Versioning

- semantic versioning for server releases
- contract version surfaced in `serverInfo`
- breaking tool/schema changes require minor/major protocol note
- deprecated tools remain for at least one minor release when feasible

## 9. Contract の判断基準

良い contract とは、tool の数が多いことではありません。  
FlutterHelm にとっての良い contract は、

- session continuity がある
- resources が first-class
- risky action の境界が明快
- delegate 差分を client に漏らしすぎない

という条件を満たすことです。
