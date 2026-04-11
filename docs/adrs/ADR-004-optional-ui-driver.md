# ADR-004: runtime UI interaction は optional adapter として core から分離する

- Status: Accepted
- Date: 2026-04-11

## Context

Flutter の running app interaction は価値が高いが、実装依存性が大きい。  
widget semantics の品質、driver の安定性、platform 差異、web/mobile/desktop の違いが強く効く。  
この面を core workflow に密結合すると、FlutterHelm 全体の安定性が損なわれる。

## Decision

`tap_widget`, `enter_text`, `scroll_until_visible`, `capture_screenshot`, `hot_reload`, `hot_restart` などの runtime interaction は、**optional runtime driver workflow** に分離する。  
driver 未接続でも core workflows は完全に動作することを要件とする。

## Consequences

### Positive

- core product の安定性を守れる
- driver 差し替えが容易
- capability disclosure が明快

### Negative

- 「全部入り」に見えにくい
- 一部ユースケースでは別セットアップが必要

### Mitigations

- runtime interaction の価値は docs で説明する
- health / capability APIs を用意する
- screenshots のみ bounded capability として先行採用も可能にする
