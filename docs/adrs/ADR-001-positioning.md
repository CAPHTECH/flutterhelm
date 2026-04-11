# ADR-001: FlutterHelm を official Dart and Flutter MCP server の代替ではなく orchestration layer として位置づける

- Status: Accepted
- Date: 2026-04-11

## Context

Flutter 公式 docs では、Dart and Flutter MCP server がすでに存在し、コード解析、symbol 解決、running app の introspection / interaction、`pub.dev` 検索、dependency 管理、テスト実行などを扱える。  
同時に、この server は experimental であり、今後も変化しうる。  
Flutter の標準実行面は依然として `flutter` CLI であり、profiling と debugging は DevTools、native deep debugging は Xcode / Android Studio が正規面となる。

## Decision

FlutterHelm は official server を再実装しない。  
代わりに、次を統合する orchestration layer とする。

- official Dart and Flutter MCP server
- `flutter` CLI
- DevTools / DTD
- optional runtime drivers
- native bridge adapters

## Consequences

### Positive

- official ecosystem に追随しやすい
- 重複実装を減らせる
- value proposition が session / resource / safety に集中する

### Negative

- delegate の変更影響を受ける
- 一部 capability は external adapter 品質に依存する

### Mitigations

- adapter boundary を明確にする
- version pinning と compatibility matrix を用意する
- contract は FlutterHelm 側で正規化する
