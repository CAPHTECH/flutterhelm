# Migration Notes

This document is the Phase 6 stable migration notes for FlutterHelm.

## 1. Stable release contract

FlutterHelm current implementation is stable-ready.  
The public contract version is `0.2.0-stable`.

## 2. What changed

- adapter registration now prefers `adapters.active` / `adapters.providers`
- legacy adapter fields are no longer accepted
- Streamable HTTP is available only as a localhost-only preview
- HTTP preview remains request-response only and does not claim Roots transport parity
- support levels are explicit: `stable`, `beta`, `preview`

## 3. Upgrade guidance

- move custom adapters to explicit registry entries
- if legacy adapter fields are still present, migrate them before starting the server
- read support-level and provider status from `adapter_list`, `config://adapters/current`, and `compatibility_check`
- keep `stdio` as the default transport unless you explicitly want the preview HTTP endpoint
- use `--allow-root-fallback` only when the client cannot provide useful Roots information

## 4. Support levels

- `stable`: `stdio`, workspace/session/launcher/runtime_readonly/tests/profiling/platform_bridge, built-in adapter path
- `beta`: `runtime_interaction`, custom `stdio_json` providers
- `preview`: HTTP transport

## 5. Verification

Recommended stable validation command:

```bash
mise exec -- pnpm -C harness stable
```

Recommended superset validation command:

```bash
mise exec -- pnpm -C harness beta
```

`stable` runs the supported stable lane. `beta` adds `ecosystem`, `interaction`, and the planned `native-build` lane on top of that lane.

## 6. Sprint 16 beta wave

Sprint 16 では native build orchestration を beta として追加する計画です。

- `native_build` is beta
- adapter family は `nativeBuild`
- harness lane は `native-build`
- scope は iOS-first の build / launch / Flutter runtime attach
- stable lane には含めない

Recommended native build validation command:

```bash
mise exec -- pnpm -C harness native-build
```
