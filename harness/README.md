# FlutterHelm Harness

FlutterHelm のハーネスは、design contract と local implementation contract を実行可能な形で検証するための self-contained workspace です。

## 目的

- `mkdocs build --strict` を global install なしで回す
- README / docs / roadmap / implementation plan の整合を保つ
- repo-local sample app を使った local flow を検証する
- 設計質問に対する deterministic な trace artifact を残す

## セットアップ

```bash
mise trust
mise install
mise exec -- dart pub get
mise exec -- pnpm -C harness install
mise exec -- pnpm -C harness bootstrap
```

`bootstrap` は `harness/.venv-docs` を作成し、MkDocs を local に導入します。
Phase 1 implementation checks は repo root の `mise.toml` と Dart/Flutter package を使うため、先に toolchain を有効化します。

## よく使うコマンド

```bash
mise exec -- pnpm -C harness validate
mise exec -- pnpm -C harness smoke
mise exec -- pnpm -C harness contracts
mise exec -- pnpm -C harness runtime
mise exec -- pnpm -C harness qa
mise exec -- pnpm -C harness run -- --tag regression
mise exec -- pnpm -C harness run -- --tag runtime
mise exec -- pnpm -C harness report
```

## Artifact

- machine-readable report: `harness/reports/latest.json`
- markdown report: `harness/reports/latest.md`
- QA trace: `harness/traces/*.json`

## Case taxonomy

- `smoke`: docs site build と README/nav 整合
- `smoke`: docs site build と initialize/ping smoke
- `regression`: workflow/tool/risk/resource/session/approval の core contract
- `regression`: 上記に加えて Phase 1 tool exposure, sample app flow, root/session flow, audit log
- `runtime`: iOS simulator で `run_app -> runtime errors -> widget tree -> attach/stop guard` を確認
- `edge`: 実務でよく聞かれる設計質問
- `adversarial`: 誤った前提に対する防御的回答

`runtime` は macOS + Xcode simulator 前提のローカル専用チェックです。
