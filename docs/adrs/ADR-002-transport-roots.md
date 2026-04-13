# ADR-002: stdio-first, roots-aware を基本とし、root fallback は明示 opt-in とする

- Status: Accepted
- Date: 2026-04-11

## Context

MCP 仕様では `stdio` と Streamable HTTP が定義され、clients SHOULD support stdio whenever possible とされている。  
また Flutter 公式の Dart and Flutter MCP server も stdio 前提で案内され、feature 完全性のためには Tools / Resources とともに Roots 対応が望ましいとされている。  
一方で現実には、roots 対応が不完全な client も存在する。

## Decision

FlutterHelm は初期 transport を `stdio-first` とする。  
Filesystem boundary は `roots-aware` を原則とし、roots が壊れている client 向けにのみ `root fallback mode` を提供する。  
fallback は server 起動時の明示 opt-in とする。

## Consequences

### Positive

- local development companion として現実的
- security boundary が明快
- official MCP tooling と整合的

### Negative

- roots 未対応 client では UX が悪化しうる
- remote / multi-tenant HTTP 連携は後回しになる

### Mitigations

- `workspace_set_root` を用意する
- fallback mode 中は write tools を制限する
- HTTP transport は後段 roadmap で扱う

## Sprint 9 update

Sprint 9 で localhost-only の Streamable HTTP preview を追加したが、この ADR の基本判断は変えていない。

- primary transport は引き続き `stdio`
- HTTP preview は `preview` 扱いで request-response only
- `GET`/SSE/resume は未対応
- HTTP preview では Roots transport を扱わず、`supportsRoots=false` 固定
- HTTP preview 上の write tool は fallback semantics に従い、`--allow-root-fallback` と explicit root selection を要求する

したがって、`stdio-first, roots-aware` が基本であり、HTTP preview は local experimentation のための補助 transport に留める。

## Sprint 15 update

Sprint 15 で stable release cut を入れたが、transport decision は変えていない。

- current contract version は `0.2.0-stable`
- HTTP preview は引き続き localhost-only preview
- roots-aware parity は stdio transport 側に残す
- migration notes と support-level taxonomy は release discipline 側で扱う
