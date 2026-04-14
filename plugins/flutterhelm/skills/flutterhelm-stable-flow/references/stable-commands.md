# Stable Commands

## Default plugin MCP config

The plugin default `.mcp.json` starts only FlutterHelm:

```json
{
  "mcpServers": {
    "flutterhelm": {
      "command": "mise",
      "args": ["exec", "--", "dart", "run", "bin/flutterhelm.dart", "serve"]
    }
  }
}
```

## Local setup

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- dart analyze
mise exec -- dart test
mise exec -- dart run bin/flutterhelm.dart serve
```

## Stable tool sequence

1. `workspace_show`
2. `compatibility_check`
3. `workspace_discover`
4. `workspace_set_root`
5. `run_app` or `session_open`
6. `get_logs`, `get_runtime_errors`, `get_widget_tree`, `get_app_state_summary`
7. `run_unit_tests` / `run_widget_tests` / `run_integration_tests`
8. `start_cpu_profile` / `stop_cpu_profile` or `capture_timeline` / `capture_memory_snapshot`
9. `ios_debug_context` / `android_debug_context` / `native_handoff_summary`

## Stable expectations

- `stdio` is the stable transport.
- built-in delegate uses official Flutter MCP first and falls back automatically.
- `runtime_interaction` and `native_build` remain opt-in beta workflows.
