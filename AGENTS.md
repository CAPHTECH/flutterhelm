# Repository Guidelines

## Project Structure & Module Organization
This repository currently contains **design documentation**, not a shipped Dart/Flutter package. The main entry points are `README.md` and `docs/index.md`. Core specs live under `docs/00-*.md` through `docs/09-*.md`, while architecture decisions are recorded in `docs/adrs/ADR-###-slug.md`. Site navigation is defined in `mkdocs.yml`. If implementation begins, follow the proposed code and test layout in `docs/09-implementation-plan.md`.

## Build, Test, and Development Commands
- `mkdocs serve` starts a local docs server for review.
- `mkdocs build --strict` builds the site and fails on nav or Markdown issues.
- `rg 'term' docs/` is the fastest way to check terminology and cross-document consistency.

Run docs commands from the repository root. If `mkdocs` is not installed, install it in your local Python environment before editing docs.

## Writing Style & Naming Conventions
Use ATX headings (`#`, `##`) and short, direct paragraphs. Match the existing style: Japanese prose with technical terms, tool names, and APIs kept in English where appropriate. Prefer fenced code blocks with language tags such as `yaml`, `json`, or `dart`.

Keep document filenames stable and descriptive:
- Spec pages: `docs/NN-topic.md`
- ADRs: `docs/adrs/ADR-###-slug.md`

When changing a contract, update all affected references in README, MkDocs nav, and related ADRs together.

## Testing Guidelines
There is no automated test suite in the current checkout. The minimum validation for every documentation change is:
- `mkdocs build --strict`
- Manual review of changed links, headings, and code fences

If Dart code is added later, place tests under `test/` and use `*_test.dart` names that mirror the module under test.

## Commit & Pull Request Guidelines
This workspace does not include local Git history, so no repository-specific commit pattern can be derived here. Use short imperative subjects with a scope when helpful, for example: `docs: clarify session lifecycle` or `adr: record resource-first artifact rationale`.

PRs should explain what changed, why it changed, and which docs or ADRs were updated. Include screenshots only when the rendered MkDocs output or navigation changed materially. Link the relevant issue or decision record whenever a design assumption moves.
