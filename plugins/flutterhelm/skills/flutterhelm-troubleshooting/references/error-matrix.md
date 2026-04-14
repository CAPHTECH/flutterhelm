# Error Matrix

## Policy and coordination

| Signal | Meaning | Next step |
| --- | --- | --- |
| `approval_required` | A risky action needs replay-token approval | Repeat the same tool call with `approvalToken=approvalRequestId` |
| `SESSION_BUSY` | Another session-exclusive mutation is active | Inspect the active tool/session and retry after it finishes |
| `WORKSPACE_BUSY` | Another workspace-exclusive mutation is active | Wait or switch to read-only inspection |

## Root and transport

| Signal | Meaning | Next step |
| --- | --- | --- |
| `WORKSPACE_ROOT_REQUIRED` | No active root exists | Run `workspace_discover` or `workspace_set_root` |
| `ROOTS_MISMATCH` | Target path is outside allowed roots | Use a client-provided root or explicit fallback flow |
| HTTP `405/400/404` | Preview transport limitation or expired session | Prefer `stdio`; if using preview, re-initialize the HTTP session |

## Adapter and beta failures

| Signal | Meaning | Next step |
| --- | --- | --- |
| `ADAPTER_PROVIDER_UNHEALTHY` | Active provider failed health checks | Read `config://adapters/current` and fix the provider command/setup |
| `RUNTIME_DRIVER_UNAVAILABLE` | runtime interaction is disabled or unconfigured | Enable the workflow and confirm the runtimeDriver provider |
| `NATIVE_BUILD_PROVIDER_UNAVAILABLE` | native_build has no healthy provider | Configure a `nativeBuild` provider or stop using the beta flow |

## Session diagnostics

Read `session://<id>/health` before guessing:

- `ready`
- `runtimeInteractionReady`
- `screenshotReady`
- `profilingReady`
- `driverConnected`
- `ownership`
- `stale`
