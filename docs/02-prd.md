# PRD

## 1. Product Requirements Summary

FlutterHelm の目的は、Flutter 開発における AI agent の反復ループを次の形で成立させることです。

```text
understand workspace
→ run / attach
→ inspect runtime
→ modify safely
→ reload / retest
→ compare artifacts
→ escalate to native bridge if needed
```

## 2. Problem Statement

AI はコードを生成できても、Flutter 開発で必要な実行・観測・テスト・profiling・native bridge が分断されていると、実用上の価値は限定されます。  
特に実行中アプリの状態と修正を結びつける場面で、手戻りが大きくなります。

## 3. Goals

### G1. Agent-safe orchestration

複数の既存ツール面を、一定の safety policy の下で統合する。

### G2. Session continuity

`run` と `attach` を session として管理し、そこから logs / errors / widget tree / profiles / test runs を辿れるようにする。

### G3. Resource-oriented diagnostics

重い出力は URI 化し、LLM コンテキスト消費を抑える。

### G4. Practical Flutter coverage

少なくとも以下を一貫面で扱う。

- workspace discovery
- analyze / resolve / format
- package search / dependency mutation
- run / attach / stop
- runtime errors / widget tree / logs
- unit/widget/integration tests
- coverage
- profile captures
- native bridge context

## 4. Non-goals

- store submission
- production deployment orchestration
- arbitrary shell access as a public feature
- full device farm management
- replacing DevTools UI
- replacing Xcode / Android Studio native debugging

## 5. Target Users

### U1. Flutter app developer

短い反復で、UI バグ修正・機能追加・テスト・profiling を行う。

### U2. Consultant / maintainer

別人のプロジェクトを素早く読み解き、再現し、切り分ける。

### U3. Plugin / add-to-app engineer

Flutter と native の境界の不具合を扱う。

## 6. Key User Stories

### Workspace / analysis

- 開発者として、workspace root を特定し、現在の active root を確認したい。
- 開発者として、静的解析エラーを一覧し、symbol 解決結果を見たい。
- 開発者として、適切な package を検索し、依存追加前に候補比較を見たい。

### Launcher / runtime

- 開発者として、接続デバイスを一覧し、任意 platform / flavor / mode でアプリを起動したい。
- 開発者として、既存実行中アプリへ attach し、session として扱いたい。
- 開発者として、runtime errors, widget tree, logs を session から辿りたい。

### Tests / diagnostics

- 開発者として、unit/widget/integration test を走らせ、結果を resource として後で読みたい。
- 開発者として、coverage を session / run 単位で取得したい。
- 開発者として、CPU / memory / timeline を capture し、比較したい。

### Native bridge

- 開発者として、iOS / Android native debugger に渡すべき文脈を自動でまとめたい。

## 7. Functional Requirements

### FR1. Workspace management

- workspace root の discovery
- active root の設定 / 表示
- multi-root 対応
- client roots 非対応時の fallback モード

### FR2. Analysis and code intelligence

- `analyze_project`
- `resolve_symbol`
- `format_files`
- package search
- dependency add/remove
- optional code fix integration

### FR3. Session lifecycle

- `session_open`
- `session_show`
- `session_list`
- `session_close`
- session state transitions
- ownership and concurrency controls

### FR4. Launch and attach

- device enumeration
- `run_app`
- `attach_app`
- `stop_app`
- `build_app`

### FR5. Runtime diagnostics

- current runtime errors
- widget tree snapshot
- structured logs
- app state summary
- screenshots if driver available

### FR6. Test execution

- unit tests
- widget tests
- integration tests
- test report resource
- coverage export

### FR7. Profiling

- CPU capture
- memory snapshot
- timeline capture
- performance overlay controls when supported

### FR8. Native bridge

- iOS debug context
- Android debug context
- handoff instructions to native IDE/tooling

### FR9. Safety and audit

- action risk classification
- human approval gates
- audit logs
- secret redaction

## 8. Non-functional Requirements

### NFR1. Deterministic contract

Tool names and schemas are stable and versioned.

### NFR2. Local-first latency

Read-only tools should feel interactive in a local workflow.

### NFR3. Root-bounded execution

Filesystem mutation never crosses declared roots without explicit fallback enablement.

### NFR4. Artifact scalability

Heavy outputs are stored as resources with retention rules.

### NFR5. Recoverability

Session crash / restart / tool failure should preserve enough metadata to diagnose what happened.

### NFR6. Cross-platform posture

At minimum the contract must model iOS, Android, macOS, Linux, Windows, and web, even if capability completeness differs by platform.

## 9. MVP Scope

### In

- workspace
- analysis
- package search
- session lifecycle
- device list
- run / attach / stop
- logs / runtime errors / widget tree
- unit/widget/integration tests
- coverage
- audit log
- root fallback mode
- resource URI scheme

### Out

- rich UI automation
- advanced DevTools embedding
- remote device cloud
- store publish
- arbitrary command execution

## 10. V1 Scope

MVP に加えて以下を含む。

- profiling workflow
- release build safeguards
- iOS / Android native bridge context
- screenshot resource
- multi-session comparison
- HTTP transport preview

## 11. Success Metrics

### Adoption metrics

- 1 つの Flutter workspace で session を最後まで完走できる率
- `run → inspect → fix → retest` ループの完了率
- session あたりに再利用された resources 数

### Product quality metrics

- 失敗した tool invocation のうち retry で回復できた割合
- confirmation が必要な risky action の誤実行率
- 1 tool result あたりの平均トークン量
- profiling capture の取得成功率

### Developer impact metrics

- runtime layout issue の平均解決時間
- package 選定〜追加〜初期動作までの平均反復回数
- native bug escalation までの平均時間

## 12. Release Criteria

### Alpha

- local workspace で安定起動
- stdio MCP としてクライアント接続可能
- `run_app`, `get_logs`, `get_runtime_errors`, `run_widget_tests` が成立

### Beta

- package mutation と test/coverage が安定
- session / resource retention が機能
- failure taxonomy と audit log が整備

### GA candidate

- profiling と native bridge が十分実用
- risky action gating が明確
- multi-platform matrix の限界がドキュメント化済み

## 13. Risks

| リスク | 内容 | 緩和策 |
|---|---|---|
| Official MCP server の変化 | experimental のため surface が変わる | adapter 層で吸収、delegate dependency を分離 |
| DTD / DevTools 接続不安定 | running app との接続差分 | session health check, fallback diagnostics |
| UI automation の脆さ | widget semantics に依存 | optional adapter 化し core から分離 |
| Client roots 非対応 | filesystem boundary が曖昧 | root fallback mode を明示 opt-in にする |
| Native bridge の誤期待 | FlutterHelm が native debugger を置換すると誤解される | product positioning を明確化 |

## 14. One-line requirement

> FlutterHelm は、Flutter 開発における AI agent の実行・観測・修正ループを、  
> **session / resource / safety policy** を核にして成立させなければならない。
