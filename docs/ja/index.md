# FlutterHelm ドキュメント

English docs: [Overview](../en/index.md) | [User Guide](../en/user-guide.md) | [Troubleshooting](../en/troubleshooting.md)

このドキュメント群は、**FlutterHelm** の user docs と design docs をまとめたものです。

## 一言でいうと

FlutterHelm は、

- 公式 Dart and Flutter MCP server の強み
- `flutter` CLI の標準性
- DevTools / DTD の観測力
- native debugger の必要性
- MCP の Tools / Resources / Roots の設計原則

を前提に、**AI エージェントが Flutter 開発を安全かつ再現可能に操作するための安定した contract** を提供します。

## まず使い始めるなら

1. [User Guide](../11-user-guide.md)
2. [Troubleshooting](../12-troubleshooting.md)
3. [Migration Notes](../10-migration-notes.md)

この順で読むと、`stable` / `beta` / `preview` の境界、最短セットアップ、日常運用の失敗モードを把握できます。

## 設計を追うなら

### 1. 背景と意図を先に掴みたい場合

1. [設計根拠](../00-design-basis.md)
2. [プロダクト概要](../01-product-brief.md)
3. [PRD](../02-prd.md)

### 2. 実装の輪郭を見たい場合

1. [アーキテクチャ](../03-architecture.md)
2. [MCP contract](../04-mcp-contract.md)
3. [Session / Resource モデル](../05-session-and-resources.md)

### 3. リスクと現実的な導入方法を見たい場合

1. [Security / Safety](../06-security-and-safety.md)
2. [Roadmap](../07-roadmap.md)
3. [Open Questions](../08-open-questions.md)

### 4. 設計判断の理由まで追いたい場合

- [ADR-001: Positioning](../adrs/ADR-001-positioning.md)
- [ADR-002: Transport and Roots](../adrs/ADR-002-transport-roots.md)
- [ADR-003: Resource-first artifacts](../adrs/ADR-003-resource-first-artifacts.md)
- [ADR-004: Optional UI driver](../adrs/ADR-004-optional-ui-driver.md)

## ドキュメントの想定読者

- Flutter アプリ開発者
- エージェント支援開発基盤を作りたいチーム
- IDE / CLI / DevTools / MCP の責務分離を設計したい人
- Flutter 開発で AI を活用したいが、既存 official toolchain との整合を崩したくない人

## 設計思想の中核

FlutterHelm は次の思想を採ります。

- **公式のものは尊重する**
- **重い出力は Resource へ逃がす**
- **操作面より先に観測面を固める**
- **session と artifact を一級オブジェクトとして扱う**
- **危険な mutation は confirmation 前提にする**
