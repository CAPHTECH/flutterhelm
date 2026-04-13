# Migration Notes

This document is the Phase 6 beta migration notes for FlutterHelm.

## 1. Beta release contract

FlutterHelm current implementation is beta-ready.  
The public contract version is `0.1.0-phase6-beta`.

## 2. What changed

- adapter registration now prefers `adapters.active` / `adapters.providers`
- legacy adapter fields are still accepted as a shim, but they are deprecated
- Streamable HTTP is available only as a localhost-only preview
- HTTP preview remains request-response only and does not claim Roots transport parity

## 3. Upgrade guidance

- move custom adapters to explicit registry entries
- read deprecation status from `adapter_list`, `config://adapters/current`, and `compatibility_check`
- keep `stdio` as the default transport unless you explicitly want the preview HTTP endpoint
- use `--allow-root-fallback` only when the client cannot provide useful Roots information

## 4. Verification

Recommended release-facing validation command:

```bash
mise exec -- pnpm -C harness beta
```

That aggregate runs the release-facing harness slices for smoke, contracts, hardening, ecosystem, runtime, profiling, bridge, and interaction.
