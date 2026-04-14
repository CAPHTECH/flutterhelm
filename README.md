# FlutterHelm

FlutterHelm is an **agent-safe orchestration layer / MCP server for Flutter development**.

English docs: [Overview](docs/en/index.md) | [User Guide](docs/en/user-guide.md) | [Troubleshooting](docs/en/troubleshooting.md)  
Japanese docs: [概要](docs/ja/index.md) | [ユーザーガイド](docs/11-user-guide.md) | [トラブルシューティング](docs/12-troubleshooting.md)

It composes the official Dart and Flutter MCP server, the `flutter` CLI, `vm_service`, profiling flows, native handoff, and optional runtime interaction drivers behind a consistent session/resource/safety contract.

FlutterHelm does not try to replace those tools.
It adds **session management, safety controls, artifact/resource handling, compatibility checks, and workflow-level orchestration** on top of official interfaces.

## Public Repository Notes

- Repository: `CAPHTECH/flutterhelm`
- License: [MIT](LICENSE)
- Public contract version: `0.2.0-stable`
- Stable transport: `stdio`
- Repo-local Codex / Claude plugin: [plugins/flutterhelm](plugins/flutterhelm)
- Support levels:
  - `stable`: core FlutterHelm workflows
  - `beta`: `runtime_interaction`, custom `stdio_json` providers, `native_build`
  - `preview`: HTTP transport

## Start Here

- Fastest install path: use the `npx` wrapper shown below and skip repository checkout
- English overview: [docs/en/index.md](docs/en/index.md)
- English user guide: [docs/en/user-guide.md](docs/en/user-guide.md)
- English troubleshooting: [docs/en/troubleshooting.md](docs/en/troubleshooting.md)
- English migration notes: [docs/en/migration-notes.md](docs/en/migration-notes.md)
- 日本語 overview: [docs/ja/index.md](docs/ja/index.md)
- 日本語ユーザーガイド: [docs/11-user-guide.md](docs/11-user-guide.md)
- 日本語トラブルシューティング: [docs/12-troubleshooting.md](docs/12-troubleshooting.md)
- 日本語移行ノート: [docs/10-migration-notes.md](docs/10-migration-notes.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting: [SECURITY.md](SECURITY.md)

## What You Can Do With FlutterHelm

- discover and select Flutter workspaces
- run, attach, and stop Flutter apps
- inspect logs, runtime errors, widget trees, app state, and screenshots
- run unit, widget, and integration tests with report and coverage resources
- capture CPU, timeline, and memory profiling artifacts
- generate iOS and Android native handoff bundles
- pin, retain, and inspect artifacts
- check compatibility, adapter health, and observability status
- use the official Flutter MCP delegate path first, with automatic fallback when needed

Opt-in `beta` workflows add:

- runtime interaction: `tap_widget`, `enter_text`, `scroll_until_visible`, `hot_reload`, `hot_restart`
- custom `stdio_json` adapters
- native build orchestration: `native_project_inspect`, `native_build_launch`, `native_attach_flutter_runtime`, `native_stop`

## Why a Separate Layer Exists

The official Dart and Flutter MCP server is already powerful, but Flutter development still spans multiple layers:

- the official MCP server is still evolving
- the `flutter` CLI remains the standard execution path
- profiling and low-level runtime inspection still depend on DevTools / DTD / `vm_service`
- native debugging still belongs to Xcode / Android Studio
- large outputs work better as Resources than as inline tool results

FlutterHelm exists to make those layers usable through a stable, agent-friendly contract.

## Core Design Principles

1. **Compose, do not replace**
   Respect the official Flutter MCP server, `flutter` CLI, DevTools, and native debuggers.

2. **Session-first**
   Treat `run`, `attach`, `profile`, and `test` as reusable session state instead of one-shot commands.

3. **Resource-first**
   Publish heavy outputs like widget trees, runtime errors, timelines, memory snapshots, and test reports as Resources.

4. **Safe-by-default**
   Default to read-only access and gate risky mutation through approvals or ownership policy.

5. **Workflow-grouped**
   Expose capabilities in workflow groups so the default surface stays small and predictable.

## External Requirements

Always required:

- Dart SDK
- Flutter SDK / `flutter` CLI
- an MCP client that supports Tools and Resources

iOS workflows additionally require:

- Xcode
- `xcrun simctl`

Beta `runtime_interaction` additionally requires:

- Node.js / `npx`
- `@mobilenext/mobile-mcp`

Beta `native_build` additionally requires:

- a `nativeBuild` `stdio_json` provider, such as an XcodeBuildMCP-like backend

## Recommended Initial Workflows

```yaml
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - tests
```

`profiling` and `platform_bridge` are enabled by default in the current implementation.
`runtime_interaction` is implemented but remains opt-in.

## Minimal MCP Setup

```json
{
  "mcpServers": {
    "flutterhelm": {
      "command": "npx",
      "args": ["-y", "github:CAPHTECH/flutterhelm", "serve"]
    }
  }
}
```

This works without cloning the repository, as long as `npx` and `dart` or `flutter` are available on PATH.

If you already cloned the repository and want the local source path instead:

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

This repository also ships repo-local Codex and Claude plugin manifests. Their default `.mcp.json` starts only stable FlutterHelm. Beta companion MCPs remain opt-in through plugin skill references.

## Local Development

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- dart analyze
mise exec -- dart test
mise exec -- dart run bin/flutterhelm.dart serve
mise exec -- pnpm -C harness stable
mise exec -- pnpm -C harness beta
```

Default config and state live under `~/.config/flutterhelm/`:

- `config.yaml`
- `state.json`
- `sessions.json`
- `audit.jsonl`
- `artifacts/`

Override them with `--config`, `--state-dir`, `--profile`, or `FLUTTERHELM_PROFILE`.

### HTTP Preview

```bash
mise exec -- dart run bin/flutterhelm.dart serve \
  --transport http \
  --http-host 127.0.0.1 \
  --http-port 0 \
  --http-path /mcp
```

HTTP transport is still `preview`:

- localhost-only
- request-response only
- no SSE / resumability
- Roots transport unsupported
- write tools still follow explicit root selection and `--allow-root-fallback`

### Profiles and Adapters

Profile overlays can switch workflows, adapters, fallbacks, and retention settings:

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

Legacy adapter fields were removed at the stable cut.
Use `adapters.active` and `adapters.providers` only.

## Current Implementation Status

Current implementation includes:

- workspace discovery, root selection, profiles, compatibility, and adapter visibility
- app run/attach/stop flows
- runtime read-only inspection
- unit/widget/integration tests with coverage resources
- VM service-backed profiling
- platform bridge handoff bundles
- hardening features such as fail-fast busy rejection, artifact pinning, retention, and observability resources
- official Flutter MCP delegate-first behavior with deterministic fallback

Implemented tool surface includes:

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

## Documentation Map

- English:
  - [Overview](docs/en/index.md)
  - [User Guide](docs/en/user-guide.md)
  - [Troubleshooting](docs/en/troubleshooting.md)
  - [Migration Notes](docs/en/migration-notes.md)
- Japanese user docs:
  - [Overview](docs/ja/index.md)
  - [User Guide](docs/11-user-guide.md)
  - [Troubleshooting](docs/12-troubleshooting.md)
  - [Migration Notes](docs/10-migration-notes.md)
- Japanese design docs:
  - [Design Basis](docs/00-design-basis.md)
  - [Product Brief](docs/01-product-brief.md)
  - [PRD](docs/02-prd.md)
  - [Architecture](docs/03-architecture.md)
  - [MCP Contract](docs/04-mcp-contract.md)
  - [Session and Resources](docs/05-session-and-resources.md)
  - [Security and Safety](docs/06-security-and-safety.md)
  - [Roadmap](docs/07-roadmap.md)
  - [Open Questions](docs/08-open-questions.md)
  - [Implementation Plan](docs/09-implementation-plan.md)
  - [ADR-001: Positioning](docs/adrs/ADR-001-positioning.md)
  - [ADR-002: Transport and Roots](docs/adrs/ADR-002-transport-roots.md)
  - [ADR-003: Resource-first artifacts](docs/adrs/ADR-003-resource-first-artifacts.md)
  - [ADR-004: Optional UI driver](docs/adrs/ADR-004-optional-ui-driver.md)
  - [References](docs/references.md)

## Harness

This repository includes a self-contained harness that validates the executable contract.

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
mise exec -- pnpm -C harness native-build
mise exec -- pnpm -C harness hardening
mise exec -- pnpm -C harness ecosystem
mise exec -- pnpm -C harness delegate
mise exec -- pnpm -C harness stable
mise exec -- pnpm -C harness beta
mise exec -- pnpm -C harness qa
```

`bootstrap` installs MkDocs into `harness/.venv-docs`, so a global `mkdocs` install is not required.
Reports are written to `harness/reports/`, and QA traces are written to `harness/traces/`.

## Japanese Note

README is now English-led for the public repository, but the design set remains Japanese-first.
日本語で読みたい場合は [docs/ja/index.md](docs/ja/index.md) から始めてください。
