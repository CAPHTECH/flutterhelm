# Troubleshooting

Japanese version: [docs/12-troubleshooting.md](../12-troubleshooting.md)

This page summarizes the failure modes you are most likely to hit in normal operation.  
In most cases, start from `session://.../health` and `config://...` resources before interpreting the raw error text.

## 1. Where to Look First

| What you want to confirm | Resource to inspect first |
| --- | --- |
| current root / profile / transport | `config://workspace/current` |
| environment readiness | `config://compatibility/current` |
| active provider / adapter health | `config://adapters/current` |
| session capability constraints | `session://<session-id>/health` |
| artifact capacity / sweep state | `config://artifacts/status` |
| counters / operational state | `config://observability/current` |

## 2. Common Problems

| Symptom | Common cause | First action |
| --- | --- | --- |
| `approval_required` | a risky mutation needs confirmation | read `approvalRequestId`, then replay the same tool with the same normalized arguments and `approvalToken` |
| `WORKSPACE_BUSY` | another mutation is already active on the same workspace | inspect `activeTool`, then serialize the conflicting mutations |
| `SESSION_BUSY` | another mutation / profiling / interaction call is active on the same session | restrict live mutations on that `sessionId` to one at a time |
| `WORKSPACE_ROOT_REQUIRED` | no active root is set | confirm `workspace_show`, then run `workspace_set_root` first |
| `ROOTS_MISMATCH` | the target path is outside client Roots | fix client Roots or decide explicitly whether `--allow-root-fallback` is appropriate |
| `SESSION_STALE` | only persisted metadata remains after a server restart | check `session_list`, then create a new live session with `run_app` or `attach_app` |
| `SESSION_NOT_RUNNING` | the session is already stopped or failed | inspect `session://<id>/health`, then relaunch if needed |
| `RUNTIME_DRIVER_UNAVAILABLE` / `RUNTIME_DRIVER_NOT_CONNECTED` | runtime interaction is disabled, the provider is disabled, or the driver cannot connect | inspect `enabledWorkflows`, `adapter_list`, `config://adapters/current`, and `session://<session-id>/health` |
| `SEMANTIC_LOCATOR_NOT_FOUND` / `SEMANTIC_LOCATOR_AMBIGUOUS` / `SEMANTIC_LOCATOR_UNSUPPORTED` | the locator is too weak or the provider does not support the requested fields | tighten `label`, `valueKey`, `type`, or `index`, then verify `supportedLocatorFields` |
| profiling tools fail | the session is not owned, is stale, has no VM service, or is in the wrong mode | inspect `ownership`, `stale`, `vmServiceAvailable`, and `currentMode` in `session://<id>/health` |
| `ADAPTER_PROVIDER_UNHEALTHY` / `ADAPTER_INVOKE_FAILED` | a custom `stdio_json` provider crashed, timed out, or failed handshake | read `adapter_list` and `config://adapters/current` for lifecycle state and reason |
| HTTP preview returns `405` / `400` / `404` | preview limitations, missing headers, or expired session | confirm the preview rules, then prefer `stdio` if possible |
| a profile cannot be selected | the requested profile name does not exist | check `workspace_show.availableProfiles` and fix the profile name |
| adapter config fails at startup | legacy adapter fields are still present after the stable cut | migrate to `adapters.active` / `adapters.providers` using [Migration Notes](migration-notes.md) |

## 3. When `approval_required` Appears

The approval flow is:

1. the first risky call returns `approval_required`
2. read `approvalRequestId`
3. replay the **same** tool with the **same** normalized input and `approvalToken=approvalRequestId`

The token is one-time use.  
If the tool, workspace, or normalized arguments change, the replay will be rejected.

## 4. Busy Errors

FlutterHelm does not queue mutations. It fails fast instead.  
That is intentional: it avoids hidden background mutations that run later than the caller expects.

Operationally:

- serialize mutations that target the same workspace
- serialize profiling / hot ops / runtime interaction on the same session
- read-only operations are usually safe to run in parallel

## 5. Roots and Fallback

The preferred path is roots-aware clients plus explicit root selection.  
HTTP preview does not support Roots transport, so it is more conservative.

Check in this order:

1. `workspace_show`
2. `config://workspace/current`
3. client Roots configuration
4. whether `--allow-root-fallback` is actually justified

Fallback is not an “allow everything” mode.  
It is explicit opt-in, and write tools still require an active root.

## 6. Stale Sessions

Session metadata is persisted, but live process handles are not.  
After a server restart, previously live sessions come back as `stale=true`.

Practical rule:

- use stale sessions for postmortem reading of logs and summaries
- create a new live session for mutation, profiling, hot ops, or live widget inspection

## 7. Runtime Interaction Problems

Check three things first:

1. `runtime_interaction` is enabled
2. the runtime driver provider is active
3. your locator fields are supported by that provider

Inspect:

- `workspace_show`
- `adapter_list`
- `config://adapters/current`
- `session://<session-id>/health`

Important health fields:

- `runtimeDriverEnabled`
- `driverConnected`
- `runtimeInteractionReady`
- `screenshotReady`

If `runtimeDriver` is explicitly selected, it becomes enabled automatically.  
Only use `options.enabled: false` when you intentionally want it disabled.

`capture_screenshot` may still use a fallback backend. Check `backend` and `fallbackUsed` in the tool result.

## 8. Profiling Problems

Profiling failures should be diagnosed through `session://<session-id>/health`.

Important fields:

- `ownership`
- `stale`
- `vmServiceAvailable`
- `dtdAvailable`
- `currentMode`
- `recommendedMode`
- `backend`

Attached sessions and stale sessions cannot be profiled.  
The shortest fix is usually to create a fresh owned running session with a live VM service.

## 9. HTTP Preview Limitations

HTTP transport is still **preview** and is not part of the stable lane.

Current constraints:

- localhost-only
- request-response only
- `GET` returns `405 Method Not Allowed`
- `MCP-Session-Id` is required
- idle expiry applies
- Roots transport is unsupported

If preview behavior is blocking you, the first fallback is to return to `stdio`.

## 10. Custom Provider Instability

Custom `stdio_json` providers are `beta`.

Provider lifecycle states are:

- `starting`
- `healthy`
- `degraded`
- `backoff`

Inspect:

- `adapter_list`
- `config://adapters/current`
- `compatibility_check`

When in doubt, switch back to the built-in provider path first. If the problem disappears, you have isolated the issue to the custom provider instead of the FlutterHelm server.

## 11. Artifact Retention

FlutterHelm uses age-based sweep plus capacity-based retention.  
Pinned artifacts are never removed automatically.

Inspect:

- `artifact_pin_list`
- `config://artifacts/pins`
- `config://artifacts/status`

If a run matters, pin the evidence early.

## 12. If You Are Still Blocked

Use this order:

1. `workspace_show`
2. `compatibility_check`
3. `adapter_list`
4. `session_list`
5. `session://<session-id>/health`
6. return to the stable path in the [User Guide](user-guide.md)
7. if the issue looks config-related, read [Migration Notes](migration-notes.md)
