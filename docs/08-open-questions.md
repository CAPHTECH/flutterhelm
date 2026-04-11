# Open Questions

FlutterHelm の設計で、現時点で意図的に未確定としている論点を整理します。

## 1. official delegate にどこまで依存するか

### 論点

- analyze / resolve / runtime errors / widget tree / package search / dependency mutation を、どこまで official Dart and Flutter MCP delegate へ委譲するか
- どこから FlutterHelm 独自実装を持つべきか

### 現時点の考え

- 独自価値が薄いものは delegate 優先
- session / resource / policy / approval / audit は FlutterHelm が持つ

### 未解決部分

- official surface が変化したときの shim 戦略
- delegate version pinning policy

## 2. DTD / DevTools への接続責務

### 論点

- DTD URI 発見を CLI から拾うのか
- official delegate から受け取るのか
- user / client から明示注入させるのか

### 現時点の考え

- 自動検出を第一候補
- 明示指定を fallback とする

### 未解決部分

- 複数 runtime が同時にあるときの紐づけ
- stale DTD の扱い

## 3. runtime interaction の責務境界

### 論点

- `tap_widget` や `enter_text` を core workflow に入れるべきか
- screenshot を read-only と見なすか runtime mutation に近いと見るか

### 現時点の考え

- runtime interaction は optional
- screenshot は bounded mutation とする

### 未解決部分

- semantic locator の標準形式
- driver 間互換性

## 4. build のスコープ

### 論点

- `build_app` を debug / profile / release すべて統一するか
- archive / ipa / aab まで入れるか

### 現時点の考え

- 初期は app build に留める
- store-facing artifact は別 workflow か out-of-scope

### 未解決部分

- signing / keystore まわりの責務
- CI と local の差異

## 5. web support の深さ

### 論点

- web を platform enum に含めるのは妥当だが、実際の runtime interaction や profiling はどこまで揃うか

### 現時点の考え

- contract 上は含める
- capability matrix で差分を明示する

### 未解決部分

- browser automation integration
- web-specific diagnostics

## 6. compare workflow を first-class にするか

### 論点

- memory snapshots や timelines の比較を tool として持つか
- それとも resource consumer 側の責務に留めるか

### 現時点の考え

- 初期は resource 提供に留める
- 比較は後段ツールとして追加可能

### 未解決部分

- diff output の標準 schema
- cross-session comparison safety

## 7. code modification の深さ

### 論点

- `format_files` はよいとして、fix application や generated code insertion を FlutterHelm 自体が持つべきか

### 現時点の考え

- 初期は変更そのものではなく orchestration と approval に集中する

### 未解決部分

- patch apply API を持つか
- MCP client 側 editor integration へ委譲するか

## 8. Secret redaction の精度

### 論点

- 完全な redaction は難しい
- Dart define, env, logs, stack trace に秘密が混ざる

### 現時点の考え

- heuristic + allowlist/denylist + masked URI
- high-risk raw output は resource にも残さない

### 未解決部分

- false positive で debugging 価値が下がる問題
- workspace-specific secret rules

## 9. Name / trademark clearance

### 論点

- FlutterHelm という名称の一般利用調査は別途必要
- 法的 clearance と OSS 名の運用は別問題

### 現時点の考え

- 実装前に GitHub / pub.dev / npm / domain / trademark を改めて確認する

## 10. 最も大きい問い

FlutterHelm の最大の未確定点は、  
**「どこまでが orchestrator で、どこからが specialized runtime tool か」**  
という境界です。

この境界を曖昧にすると、FlutterHelm は便利に見えても肥大化し、保守不能になりやすいです。  
したがって今後も、**delegate / adapter / policy / session の責務分離**を崩さないことが重要です。
