# User Guide

Japanese version: [docs/11-user-guide.md](../11-user-guide.md)

This page is the practical entrypoint for **using FlutterHelm day to day**.  
Read it before diving into the full contract or the design documents.

## 1. What FlutterHelm is

FlutterHelm is an orchestration layer / MCP server for Flutter development.  
It composes the `flutter` CLI, the official Flutter MCP delegate path, `vm_service`, profiling, native handoff, and optional runtime drivers behind one session/resource/safety contract.

The starting assumptions are:

- the default transport is `stdio`
- the recommended starting path is also `stdio`
- heavy outputs are read as Resources instead of being inlined into tool results
- risky mutations use approval or ownership rules

## 2. Support Levels

| Surface | Support level | Notes |
| --- | --- | --- |
| `stdio` transport | `stable` | Recommended default |
| core workflows (`workspace`, `session`, `launcher`, `runtime_readonly`, `tests`, `profiling`, `platform_bridge`) | `stable` | Uses the built-in adapter path |
| `runtime_interaction` | `beta` | Opt-in workflow |
| custom `stdio_json` providers | `beta` | Enabled through the adapter registry |
| HTTP transport | `preview` | Localhost-only, request-response only |

See [Migration Notes](migration-notes.md) and the [MCP Contract](../04-mcp-contract.md) for the detailed boundary.

Stable diagnostics prefer the official Flutter MCP delegate through the built-in `delegate` family. If that path is unavailable, times out, or returns malformed data, FlutterHelm automatically falls back to the current CLI / `vm_service` implementation.

## 3. Fastest Setup

### 3.1 Local preparation

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- dart analyze
mise exec -- dart test
```

### 3.2 Start the server

```bash
mise exec -- dart run bin/flutterhelm.dart serve
```

### 3.3 Minimal MCP client config

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

## 4. First Connection Check

Use this order first:

1. `workspace_show`
2. `workspace_discover`
3. `workspace_set_root`
4. `session_open` or `run_app`

From `workspace_show`, check at least:

- `activeProfile`
- `availableProfiles`
- `transportMode`
- `rootsTransportSupport`
- `compatibilityResource`
- `adaptersResource`

If `workspace_set_root` succeeds, session, run, and test flows become much more predictable.  
If your MCP client cannot provide useful Roots information, opt into `--allow-root-fallback` explicitly.

## 5. Run an App and Inspect It

The normal entrypoint is `run_app`.

```json
{
  "platform": "ios",
  "target": "lib/main.dart",
  "mode": "debug"
}
```

After launch, use the returned `sessionId` with:

- `get_logs`
- `get_runtime_errors`
- `get_widget_tree`
- `get_app_state_summary`
- `capture_screenshot`

Heavy outputs are exposed as Resources:

- `log://<session-id>/stdout`
- `log://<session-id>/stderr`
- `runtime-errors://<session-id>/current`
- `widget-tree://<session-id>/current?depth=3`
- `app-state://<session-id>/summary`
- `screenshot://<session-id>/<capture-id>.png`

See [Session and Resources](../05-session-and-resources.md) for the session model.

## 6. Tests and Coverage

Use:

- `run_unit_tests`
- `run_widget_tests`
- `run_integration_tests`
- `get_test_results`
- `collect_coverage`

If you want coverage, request it on the test run with `coverage=true`.  
The main resources are:

- `test-report://<run-id>/summary`
- `test-report://<run-id>/details`
- `coverage://<run-id>/summary`
- `coverage://<run-id>/lcov`

Start with unit/widget tests first. Add integration tests when your simulator/device setup is already healthy.

## 7. Profiling

Profiling is `stable`, but it still requires an **owned session with a live VM service**.

Use:

- `start_cpu_profile`
- `stop_cpu_profile`
- `capture_timeline`
- `capture_memory_snapshot`
- `toggle_performance_overlay`

Artifacts are published as:

- `cpu://<session-id>/<capture-id>`
- `timeline://<session-id>/<capture-id>`
- `memory://<session-id>/<snapshot-id>`
- `session://<session-id>/health`

`session://<session-id>/health` should be your first stop when profiling or runtime interaction is unavailable.

## 8. Native Handoff

FlutterHelm does not replace Xcode or Android Studio.  
It bundles the right context so you can hand the issue off cleanly.

Use:

- `ios_debug_context`
- `android_debug_context`
- `native_handoff_summary`

The main outputs are:

- `native-handoff://<session-id>/ios`
- `native-handoff://<session-id>/android`

These bundles include open paths, evidence resources, hypotheses, and next steps.

## 9. Enable Beta Features

### 9.1 `runtime_interaction`

`runtime_interaction` is disabled by default.  
When enabled, it exposes:

- `tap_widget`
- `enter_text`
- `scroll_until_visible`
- `hot_reload`
- `hot_restart`

Example:

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

If you explicitly select `runtimeDriver`, the selected provider is auto-enabled.  
Only set `options.enabled: false` when you want to disable it on purpose.

Check these fields in `session://<session-id>/health`:

- `runtimeInteractionReady`
- `screenshotReady`
- `driverConnected`
- `supportedLocatorFields`

`capture_screenshot` also reports `backend`, `driverConnected`, `fallbackUsed`, and `fallbackReason?`.

### 9.2 Custom `stdio_json` providers

Custom providers remain `beta`.  
Use `adapters.active` / `adapters.providers` rather than legacy adapter fields.

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

Check active provider status through:

- `adapter_list`
- `config://adapters/current`
- `compatibility_check`

### 9.3 `native_build`

`native_build` is also `beta`.  
It lets you launch a native build flow and then correlate a Flutter runtime attach into the same session.

Use:

- `native_project_inspect`
- `native_build_launch`
- `native_attach_flutter_runtime`
- `native_stop`

This is iOS-first and does not replace Xcode or LLDB. It is a bridge layer for build / launch / attach orchestration.
