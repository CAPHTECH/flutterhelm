# プロダクト概要

## 1. プロダクト名

**FlutterHelm**

## 2. プロダクト定義

FlutterHelm は、**Flutter 開発のための agent-safe orchestration layer / MCP server** です。

これは以下を一つの整った運用面に束ねます。

- 公式 Dart and Flutter MCP server
- `flutter` CLI
- DevTools / DTD
- optional runtime driver
- iOS / Android の native bridge

FlutterHelm 自体の価値は、個々の操作を再実装することではありません。価値の中心は次の 4 つです。

1. **Session 管理**
2. **Workflow grouping**
3. **Resource / artifact の統一**
4. **Safety policy と confirmation gate**

## 3. 解く課題

Flutter 開発で AI を本気で使おうとすると、操作面が分断されています。

- 静的コード解析は analyzer / official MCP server
- 実行は `flutter run`
- テストは `flutter test`
- profiling は DevTools
- native code は Xcode / Android Studio
- UI の runtime interaction は環境や driver に依存

この分断は、人間には耐えられても、AI エージェントには扱いにくいです。  
結果として次の問題が起きます。

### 3.1 セッションが継続しない

同じアプリの `run → inspect → fix → reload → inspect` が、ツールごとに別世界として扱われる。

### 3.2 出力が重すぎる

widget tree、timeline、test report などが毎回巨大テキストになり、LLM の文脈効率を損なう。

### 3.3 mutation の安全境界が曖昧

依存追加、`pubspec.yaml` 更新、hot restart、release build などが同じ軽さで実行されると、人間側の制御が損なわれる。

### 3.4 native 側の不具合に踏み込めない

Flutter だけ見ても解けない問題に入った瞬間、Xcode / Android Studio との橋がない。

## 4. プロダクト仮説

> Flutter 開発向け AI の生産性ボトルネックは、モデル能力の不足よりも、  
> **ツール surface の分断、session の断絶、artifact の未構造化**にある。  
> FlutterHelm はこの 3 点を整理することで、AI の反復速度と安全性を同時に改善できる。

## 5. 誰のためのプロダクトか

### Primary persona A: ソロ / 小規模チームの Flutter アプリ開発者

- 目的: 機能追加、UI バグ修正、テスト、profiling を短い反復で回したい
- 痛み: ツールを跨いだ調査の往復が多い
- 欲しいもの: 「動いているもの」を前提にした AI 補助

### Primary persona B: 技術顧問 / 問題解析担当

- 目的: 他人の Flutter プロジェクトを素早く把握し、問題を再現し、修正方針を出したい
- 痛み: 環境差分と再現経路の把握に時間がかかる
- 欲しいもの: Session, artifact, logs, diagnostics が整理された面

### Secondary persona C: plugin / platform integration maintainer

- 目的: Flutter と native の境界不具合を短時間で切り分けたい
- 痛み: Dart 側で見える現象と native 側原因の橋が弱い
- 欲しいもの: native bridge と profiling context

## 6. Jobs To Be Done

- 「いま動いているアプリの state を見ながら、layout error を直したい」
- 「適切な package を探し、依存を加え、動くコードの初期形まで出したい」
- 「テスト結果と coverage を session 単位で追跡したい」
- 「jank / memory leak を runtime artifact として比較したい」
- 「Dart 側では説明できない不具合を native debugger へ橋渡ししたい」

## 7. 何をしないか

FlutterHelm は次を初期スコープに入れません。

- Flutter SDK 自体の replacement
- 公式 Dart and Flutter MCP server の再実装
- IDE の代替
- 完全な browser automation / device farm orchestration
- CI/CD 配布、store publish、release submission の自動化
- 任意の shell execution を無制限に許可する汎用 agent runner

## 8. プロダクト原則

### 8.1 Compose, don’t replace

既存 official surface の上に立つ。  
そうしないと、Flutter ecosystem の進化に追随できなくなる。

### 8.2 Runtime-first for agentic loops

本当の価値は「静的コード理解」だけではなく、**running app を含む反復ループ**にある。

### 8.3 Resources over raw text

重い診断情報は URI へ逃がし、ツール結果は短く保つ。

### 8.4 Human approval for risky actions

依存変更、state 破壊、release build、publishing 系は人間が最後の鍵を持つ。

### 8.5 Minimal default surface

最初から全部を expose しない。  
workflow group ごとに enable する。

## 9. 製品としての差別化

FlutterHelm の差別化は、次の「中間レイヤ」であることです。

| 面 | 単独ツール | FlutterHelm の立ち位置 |
|---|---|---|
| コード解析 | official MCP server | その能力を delegate し、session に接続する |
| 実行 | `flutter` CLI | session / artifacts / policies を与える |
| 観測 | DevTools / DTD | Resource URI に正規化する |
| native debugging | Xcode / Android Studio | そこへ行く文脈橋を提供する |
| UI interaction | optional drivers | core から疎結合に扱う |

## 10. 一番重要なメッセージ

FlutterHelm は「Flutter 用の全部入りツール」ではありません。  
**既存の正規ツール群を、AI が壊しにくく、再利用しやすく、文脈効率よく扱うための舵輪**です。
