---
name: flutterhelm-stable-flow
description: Guide stable FlutterHelm setup and execution for repo-local stdio workflows. Use when Codex needs to start or operate stable FlutterHelm flows such as workspace selection, run and inspect, tests, profiling, compatibility checks, or native handoff without enabling beta runtime_interaction or native_build paths.
---

# FlutterHelm Stable Flow

Use this skill to run the default, stable FlutterHelm loop in a repo that already contains FlutterHelm.

## Workflow

1. Start from the default plugin MCP config and treat `stdio` as the primary path.
2. Confirm readiness with `workspace_show`, `compatibility_check`, and `adapter_list`.
3. Set or discover the workspace root before opening or running a session.
4. Use the stable loop:
   - `run_app`
   - `get_logs`
   - `get_runtime_errors`
   - `get_widget_tree`
   - `get_app_state_summary`
   - `capture_screenshot`
5. Move to `run_unit_tests`, `run_widget_tests`, `run_integration_tests`, or profiling tools only after the session/root state is healthy.
6. Use `ios_debug_context`, `android_debug_context`, or `native_handoff_summary` when Flutter-side diagnosis is not enough.

## Default expectations

- Prefer the built-in delegate and let FlutterHelm handle official Flutter MCP fallback automatically.
- Keep `runtime_interaction` and `native_build` disabled unless the user explicitly asks for beta behavior.
- Prefer `session://<id>/health`, `config://compatibility/current`, and `config://adapters/current` over guessing why a workflow is unavailable.

## References

- Read `references/stable-commands.md` for the default MCP config, setup commands, and the stable tool sequence.
- Read `../../../../docs/11-user-guide.md` when you need the repo's full user-facing walkthrough.
