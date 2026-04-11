# ADR-003: heavy diagnostics は tool result ではなく Resource を第一の搬送面とする

- Status: Accepted
- Date: 2026-04-11

## Context

Flutter 開発では、widget tree、runtime errors、test reports、coverage、CPU profile、memory snapshots、timeline などが長大になりやすい。  
これらを毎回 tool result に直接載せると、LLM のコンテキスト効率が悪化する。  
MCP 仕様では、Resources は URI で識別される context data を server が expose するための面として定義されている。

## Decision

FlutterHelm は heavy diagnostics を resource-first で扱う。  
Tool result は短い summary と resource links を返すことを原則にする。

## Consequences

### Positive

- token efficiency が高まる
- compare / replay / re-read がしやすい
- artifact retention と監査がしやすい

### Negative

- resource store 実装が必要
- client が Resources を読めないと価値が下がる

### Mitigations

- tool result に summary を含める
- capability negotiation で resource support を確認する
- fallback として truncated inline output を許容する
