---
name: flutterhelm-beta-runtime-interaction
description: Enable FlutterHelm runtime_interaction beta with the built-in external runtime driver and optional mobile-mcp companion MCP. Use when Codex needs semantic tap, text entry, scroll, richer screenshots, or UI-state verification on a running Flutter session.
---

# FlutterHelm Beta Runtime Interaction

Use this skill only when the user explicitly wants beta UI interaction behavior.

## Workflow

1. Enable the `runtime_interaction` workflow in FlutterHelm config.
2. Select or confirm the `runtimeDriver` provider.
3. Check `session://<id>/health` for:
   - `runtimeInteractionReady`
   - `screenshotReady`
   - `driverConnected`
   - `supportedLocatorFields`
4. Use `capture_screenshot` first, then `tap_widget`, `enter_text`, and `scroll_until_visible`.
5. Treat screenshot fallback fields as part of the result, not as hidden implementation detail.

## Guardrails

- Do not present runtime interaction as stable.
- Keep companion `mobile-mcp` setup opt-in. The default plugin `.mcp.json` does not start it.
- If health stays degraded, stop and surface the exact readiness field or provider reason.

## References

- Read `references/mobile-mcp-setup.md` for the beta config, optional companion MCP entry, and expected health fields.
- Read `../../../../docs/11-user-guide.md` for the repo's full runtime_interaction guide.
