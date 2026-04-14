# FlutterHelm Documentation

Japanese docs: [Overview](../ja/index.md) | [User Guide](../11-user-guide.md) | [Troubleshooting](../12-troubleshooting.md)

This documentation set combines **user-facing onboarding** and **design documentation** for FlutterHelm.

## In one sentence

FlutterHelm provides a stable, agent-safe contract for Flutter development by composing:

- the official Dart and Flutter MCP server
- the `flutter` CLI
- DevTools / DTD and `vm_service`
- optional runtime interaction drivers
- native handoff and native build orchestration

## Start Here

1. [User Guide](user-guide.md)
2. [Troubleshooting](troubleshooting.md)
3. [Migration Notes](migration-notes.md)

Read those three pages first if your goal is to install FlutterHelm, run it locally, and understand the boundaries between `stable`, `beta`, and `preview`.

## Documentation Language Policy

- User-facing onboarding and operational docs are available in both English and Japanese.
- Design docs and ADRs are still Japanese-first.
- When you need deeper architecture detail, use the Japanese design set linked below.

## Design Set

### Product and intent

1. [Design Basis](../00-design-basis.md)
2. [Product Brief](../01-product-brief.md)
3. [PRD](../02-prd.md)

### Architecture and public contract

1. [Architecture](../03-architecture.md)
2. [MCP Contract](../04-mcp-contract.md)
3. [Session and Resources](../05-session-and-resources.md)

### Safety and roadmap

1. [Security and Safety](../06-security-and-safety.md)
2. [Roadmap](../07-roadmap.md)
3. [Open Questions](../08-open-questions.md)

### ADRs

- [ADR-001: Positioning](../adrs/ADR-001-positioning.md)
- [ADR-002: Transport and Roots](../adrs/ADR-002-transport-roots.md)
- [ADR-003: Resource-first artifacts](../adrs/ADR-003-resource-first-artifacts.md)
- [ADR-004: Optional UI driver](../adrs/ADR-004-optional-ui-driver.md)
