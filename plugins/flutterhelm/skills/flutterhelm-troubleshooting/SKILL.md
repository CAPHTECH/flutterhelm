---
name: flutterhelm-troubleshooting
description: Diagnose FlutterHelm failures and degraded states. Use when Codex needs to triage approval_required responses, SESSION_BUSY or WORKSPACE_BUSY, root or fallback problems, degraded delegate/provider health, runtime driver errors, native_build setup problems, or HTTP preview confusion.
---

# FlutterHelm Troubleshooting

Use this skill to triage FlutterHelm failures before changing config or code.

## Triage order

1. Read `workspace_show` for `activeRoot`, `transportMode`, and resource pointers.
2. Read `config://compatibility/current` and `config://adapters/current`.
3. If a session exists, read `session://<id>/health`.
4. Inspect the exact structured error code before proposing changes.
5. Only move to beta setup when the failure is clearly outside the stable path.

## Decision rules

- Treat `approval_required` as a policy step, not a backend failure.
- Treat `SESSION_BUSY` and `WORKSPACE_BUSY` as coordination issues first.
- Treat `RUNTIME_DRIVER_UNAVAILABLE`, `ADAPTER_PROVIDER_UNHEALTHY`, and `NATIVE_BUILD_PROVIDER_UNAVAILABLE` as environment or provider issues first.
- Treat HTTP preview errors as transport limitations unless the user explicitly wants preview transport.

## References

- Read `references/error-matrix.md` for common error families and the next remediation step.
- Read `../../../../docs/12-troubleshooting.md` when you need the repo's full troubleshooting guide.
