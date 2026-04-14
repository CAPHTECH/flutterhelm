# Contributing

Thanks for considering a contribution to FlutterHelm.

## Before you start

- Read [README.md](README.md) for the current public positioning and support levels.
- Read [docs/11-user-guide.md](docs/11-user-guide.md) for user-facing behavior.
- Read [docs/04-mcp-contract.md](docs/04-mcp-contract.md) if your change affects tool or resource contracts.
- Read [AGENTS.md](AGENTS.md) for repository-specific collaboration rules.

## Development setup

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- dart analyze
mise exec -- dart test
```

For docs and harness work:

```bash
mise exec -- pnpm -C harness install
mise exec -- pnpm -C harness bootstrap
./harness/.venv-docs/bin/mkdocs build --strict
```

## Expected validation

Minimum checks before opening a PR:

```bash
mise exec -- dart analyze
mise exec -- dart test
./harness/.venv-docs/bin/mkdocs build --strict
```

Run additional harness lanes when relevant:

- `mise exec -- pnpm -C harness stable`
- `mise exec -- pnpm -C harness beta`
- `mise exec -- pnpm -C harness delegate`
- `mise exec -- pnpm -C harness native-build`

## Contribution guidelines

- Keep stable, beta, and preview boundaries explicit.
- Do not silently expand beta or preview behavior into the stable lane.
- When changing public contracts, update README, docs, harness expectations, and any related plugin guidance together.
- Prefer small, reviewable changes with a clear validation story.

## Pull requests

PRs should explain:

- what changed
- why it changed
- whether it affects stable, beta, or preview behavior
- which commands you ran to verify it

If your change touches user-facing behavior, include docs updates in the same PR.
