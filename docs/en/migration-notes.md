# Migration Notes

Japanese version: [docs/10-migration-notes.md](../10-migration-notes.md)

This page summarizes the stable migration rules for FlutterHelm.

## 1. Stable Contract

The current public contract version is `0.2.0-stable`.

## 2. What Changed

- adapter registration now uses `adapters.active` / `adapters.providers`
- legacy adapter fields are no longer accepted
- Streamable HTTP exists only as a localhost-only preview
- HTTP preview remains request-response only and does not claim Roots transport parity
- support levels are explicit: `stable`, `beta`, `preview`

## 3. Upgrade Guidance

- move custom adapters to explicit registry entries
- migrate legacy adapter fields before starting the server
- read provider status through `adapter_list`, `config://adapters/current`, and `compatibility_check`
- keep `stdio` as the default transport unless you explicitly want the preview HTTP endpoint
- use `--allow-root-fallback` only when your client cannot provide meaningful Roots information

## 4. Support Levels

- `stable`: `stdio`, workspace/session/launcher/runtime_readonly/tests/profiling/platform_bridge, built-in adapter path
- `beta`: `runtime_interaction`, custom `stdio_json` providers, `native_build`
- `preview`: HTTP transport

## 5. Verification

Recommended stable validation:

```bash
mise exec -- pnpm -C harness stable
```

Recommended superset validation:

```bash
mise exec -- pnpm -C harness beta
```

`stable` runs the supported stable lane. `beta` adds `ecosystem`, `delegate`, `interaction`, and `native-build`.

## 6. Sprint 16 Native Build Beta Wave

Sprint 16 added native build orchestration as `beta`.

- `native_build` is beta
- the adapter family is `nativeBuild`
- the harness lane is `native-build`
- the scope is iOS-first build / launch / Flutter runtime attach
- it is not part of the stable lane

Recommended validation:

```bash
mise exec -- pnpm -C harness native-build
```

## 7. Sprint 17 Official Delegate Wave

Sprint 17 switched the built-in `delegate` family to an official Flutter MCP first strategy.

- the primary backend is `dart mcp-server --tools all --force-roots-fallback`
- covered tools include `analyze_project`, `resolve_symbol`, `pub_search`, `dependency_add`, `dependency_remove`, `get_runtime_errors`, `get_widget_tree`, `hot_reload`, `hot_restart`
- if the official delegate is unavailable, times out, returns malformed payloads, or fails DTD connection, FlutterHelm falls back to the current backend
- the support level stays the same and the public contract remains `0.2.0-stable`
