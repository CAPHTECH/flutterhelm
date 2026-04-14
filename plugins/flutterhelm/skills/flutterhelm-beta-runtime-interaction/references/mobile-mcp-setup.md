# mobile-mcp Setup

## Important default

The plugin default `.mcp.json` does **not** start `mobile-mcp`.  
Keep the stable path clean unless the user explicitly asks for beta runtime interaction.

## FlutterHelm config

```yaml
version: 1
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
    runtimeDriver: builtin.runtime_driver.external_process
```

Selecting `runtimeDriver` explicitly auto-enables the built-in provider unless it is explicitly disabled in provider options.

## Optional companion MCP entry

If the user also wants direct access to the mobile driver, add a separate MCP entry in the client config:

```json
{
  "mcpServers": {
    "mobile-mcp": {
      "command": "npx",
      "args": ["-y", "@mobilenext/mobile-mcp@latest", "--stdio"]
    }
  }
}
```

This is optional companion wiring, not part of the plugin default.

## Health fields to inspect

- `runtimeInteractionReady`
- `screenshotReady`
- `driverConnected`
- `supportedLocatorFields`

## Expected screenshot behavior

- `backend=external_adapter` means the driver produced the artifact directly.
- `fallbackUsed=true` means FlutterHelm published the screenshot through a fallback path such as `ios_simctl`.
- `fallbackReason` explains why the fallback happened.
