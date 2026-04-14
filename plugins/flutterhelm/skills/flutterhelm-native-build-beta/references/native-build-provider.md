# Native Build Provider

## Important default

The plugin default `.mcp.json` does **not** start a native-build companion MCP.  
Keep native build orchestration opt-in.

## FlutterHelm config pattern

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
  - native_build
adapters:
  active:
    nativeBuild: local.xcodebuild
  providers:
    local.xcodebuild:
      kind: stdio_json
      families:
        - nativeBuild
      command: ./tool/run-xcodebuildmcp.sh
      startupTimeoutMs: 10000
```

Use a wrapper command when the upstream native-build MCP needs extra environment variables or nontrivial startup flags.

## Optional direct companion MCP entry

If the user wants direct access to the native-build MCP in the client as well, add a separate MCP entry:

```json
{
  "mcpServers": {
    "xcodebuildmcp": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest", "mcp"]
    }
  }
}
```

This is optional companion wiring, not part of the plugin default.

## Same-session flow

1. `native_project_inspect`
2. `native_build_launch`
3. `native_attach_flutter_runtime`
4. Use stable runtime tools on the same `sessionId`
5. `native_stop`

## Boundaries

- iOS-first beta only
- not a replacement for Xcode, LLDB, or Xcode UI automation
- use `ios_debug_context` or `native_handoff_summary` when you need to hand evidence to native tools
