---
name: flutterhelm-native-build-beta
description: Configure and use FlutterHelm native_build beta with a stdio_json nativeBuild provider such as an XcodeBuildMCP-like backend. Use when Codex needs iOS-first native build or launch plus same-session Flutter runtime attachment and correlated native evidence.
---

# FlutterHelm Native Build Beta

Use this skill only when the user explicitly wants beta native build orchestration.

## Workflow

1. Confirm the repo has an iOS project and the host is macOS.
2. Configure a `nativeBuild` provider and enable the `native_build` workflow.
3. Confirm readiness with `compatibility_check` and `adapter_list`.
4. Use the beta flow:
   - `native_project_inspect`
   - `native_build_launch`
   - `native_attach_flutter_runtime`
   - stable runtime diagnostics on the same session
   - `native_stop`
5. Use `ios_debug_context` or `native_handoff_summary` to package evidence when the user needs to move into Xcode.

## Guardrails

- Do not claim that FlutterHelm replaces Xcode, LLDB, or Xcode UI automation.
- Keep companion native-build MCP setup opt-in. The default plugin `.mcp.json` does not start it.
- Stop early if the active `nativeBuild` provider is missing or unhealthy.

## References

- Read `references/native-build-provider.md` for the provider config pattern and same-session launch-plus-attach flow.
- Read `../../../../docs/11-user-guide.md` and `../../../../docs/04-mcp-contract.md` for the repo's native_build beta contract.
