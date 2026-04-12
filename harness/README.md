# FlutterHelm Harness

FlutterHelm のハーネスは、実装前の設計契約を実行可能な形で検証するための self-contained workspace です。

## 目的

- `mkdocs build --strict` を global install なしで回す
- README / docs / roadmap / implementation plan の整合を保つ
- 設計質問に対する deterministic な trace artifact を残す

## セットアップ

```bash
mise trust
mise install
mise exec -- dart pub get
npm --prefix harness install
npm --prefix harness run bootstrap
```

`bootstrap` は `harness/.venv-docs` を作成し、MkDocs を local に導入します。
Phase 0 implementation checks は repo root の `mise.toml` と Dart package を使うため、先に toolchain を有効化します。

## よく使うコマンド

```bash
npm --prefix harness run validate
npm --prefix harness run smoke
npm --prefix harness run contracts
npm --prefix harness run qa
npm --prefix harness run run -- --tag regression
npm --prefix harness run report
```

## Artifact

- machine-readable report: `harness/reports/latest.json`
- markdown report: `harness/reports/latest.md`
- QA trace: `harness/traces/*.json`

## Case taxonomy

- `smoke`: docs site build と README/nav 整合
- `smoke`: docs site build と Phase 0 initialize/ping smoke
- `regression`: workflow/tool/risk/resource/session/approval の core contract
- `regression`: 上記に加えて Phase 0 tool exposure, root/session flow, audit log
- `edge`: 実務でよく聞かれる設計質問
- `adversarial`: 誤った前提に対する防御的回答

## CI

- `pull_request` では `smoke` のみを必須 gate とする
- `workflow_dispatch` では `smoke/regression/edge/adversarial` を選択実行できる
- artifact は `harness/reports/` と `harness/traces/` を upload する
