# Security / Safety

## 1. 前提

FlutterHelm はローカル開発者環境に深く関与します。  
これは便利さと引き換えに、次の危険を持ちます。

- 意図しない filesystem mutation
- package dependency の改変
- state 破壊的な runtime 操作
- release build や publish に近い操作の誤実行
- logs / resources に含まれる秘密情報の漏えい
- native bridge の誤解による深追い失敗

したがって FlutterHelm では、**capability の広さより境界の明快さ**を優先します。

## 2. 安全設計の原則

### 2.1 Least privilege

初期有効 workflow は read-heavy に寄せる。  
高リスク workflow は opt-in。

### 2.2 Human-held key

危険度の高い操作は、人間確認トークンなしに進めない。

### 2.3 Root bounded

filesystem 操作は root 外へ出さない。  
fallback mode でも canonical path validation を必須にする。

### 2.4 Owned-process control

停止や restart は、FlutterHelm が管理している process / session を優先対象にする。

### 2.5 Resource redaction

logs, env, tool output に含まれる secret を mask する。

## 3. Risk Classes

| Risk Class | 例 | 既定動作 |
|---|---|---|
| `read_only` | analyze, logs, widget tree | 自動許可 |
| `read_only_network` | pub search | 自動許可 |
| `bounded_mutation` | set root, screenshot, session close | 自動許可または軽確認 |
| `runtime_control` | run, stop, hot reload, profile capture | owned session のみ自動 |
| `project_mutation` | format, dependency add/remove | 確認必須 |
| `state_destructive` | hot restart | 確認必須 |
| `build_control` | release build, clean build | mode に応じて確認 |
| `publish_like` | store upload, publish | 初期スコープ外 |

## 4. Confirmation Policy

### 必ず確認する操作

- `dependency_add`
- `dependency_remove`
- `hot_restart`
- `build_app` with `mode=release`
- `clean` 相当の destructive build reset
- `workspace_set_root` in fallback mode
- 将来の publish / archive / distribute 系

### Owned session なら自動実行可の候補

- `stop_app`
- `hot_reload`
- `capture_timeline`
- `capture_memory_snapshot`

ただし session が `attached` の場合は自動許可しない。`hot_restart` は owned session であっても approval replay を要求する。

## 5. Filesystem Boundary

### Roots-aware mode

- root 外の file path は拒否
- symlink resolve 後に root 内判定
- write は active root のみ

### Root fallback mode

- server 起動時に `--allow-root-fallback` が必要
- user が明示 root を選ぶまで write tool を無効
- 現在 root は `config://workspace/current` で可視化

### HTTP preview mode

- current implementation の `--transport http` は localhost-only preview
- `GET`/SSE/resume は未対応で request-response only
- `MCP-Session-Id` header で session を維持する
- Roots transport は unsupported なので roots-aware client roots は扱わない
- write tool は stdio と同じく fallback semantics に従い、`--allow-root-fallback` と explicit root selection が必要

## 6. Process Safety

### Stop / restart rules

- `stop_app` は owned session 優先
- attached session への kill は拒否
- `hot_restart` は state 破壊を明示
- stale session では restart を拒否し、再 run/attach を促す
- 同一 session に対する mutation / profiling / interaction は fail-fast lock で直列化せず、競合時は `SESSION_BUSY` を返す
- 同一 workspace に対する test / format / dependency mutation / run は fail-fast lock を使い、競合時は `WORKSPACE_BUSY` を返す

### PID trust model

- PID だけでは信用しない
- launch metadata + session token + workspace root を紐づけて照合

## 7. Secret Handling

### Redaction 対象

- `--dart-define` に含まれる token 類
- env vars
- authorization headers
- service account JSON path / inline content
- API keys / bearer tokens / cookies

### 方針

- logs 保存前に redact
- raw secret は resource にも残さない
- maskedUri を返す
- approval event に secret 値を含めない

## 8. Network Policy

FlutterHelm は原則 local-first ですが、次は network を使う可能性があります。

- `pub_search`
- dependency add/remove に伴う package 解決
- 将来的な remote device / artifact sync

初期設計では、

- network を使う操作には明示ラベルを付ける
- package mutation は confirmation 必須
- remote outbound actions は deny-by-default

## 8.1 External adapter policy

Sprint 9 の adapter registry では custom provider kind として `stdio_json` を受理します。

- provider は config で明示登録されたものだけを起動する
- auto-discovery や marketplace install は current implementation の範囲外
- host は family / operation を先に検証し、unsupported invoke をそのまま通さない
- provider の health と active selection は `adapter_list` と `config://adapters/current` で可視化する
- external provider は local process として扱い、trusted local tooling と同じ注意で導入する
- legacy adapter fields は beta-ready 互換として受理するが、deprecation は `adapter_list`, `config://adapters/current`, `compatibility_check` に出す

## 9. Native Bridge Safety

Flutter 公式 docs にある通り、native code debugging は iOS/macOS なら Xcode、Android なら Android Studio などが前提です。  
したがって FlutterHelm は native bridge を **handoff context generator** として扱います。  
「Xcode を完全制御する」「Android Studio を自動操作する」は初期スコープに入れません。

current implementation では `platform_bridge` workflow は既定で有効ですが、許可されるのは read-only handoff bundle 生成だけです。
native project が見つからない場合も destructive failure にはせず、`status=unavailable` の bundle と次の確認手順を返します。

## 9.1 Runtime Interaction Safety

runtime interaction は current implementation でも **opt-in** です。

- `runtime_interaction` workflow を有効にしない限り `tap_widget`, `enter_text`, `scroll_until_visible`, `hot_reload`, `hot_restart` は露出しない
- UI action backend は external adapter 前提で、driver 未接続時は capability error を返す
- screenshot は `runtime_readonly` に残し、driver が無くても iOS simulator なら fallback capture を許可する
- locator が弱い場合は `SEMANTIC_LOCATOR_NOT_FOUND`, `SEMANTIC_LOCATOR_AMBIGUOUS`, `SEMANTIC_LOCATOR_UNSUPPORTED` を返し、曖昧な自動 fallback はしない
- `hot_reload` / `hot_restart` は driver ではなく owned session の `flutter run --machine` control channel を使う

## 10. iOS-specific Safety Note

iOS 14+ では local network permission を許可しないと hot reload や DevTools が動かないことがあります。  
このため、iOS session の attach 不全を単純な tool failure と扱うのは危険です。FlutterHelm は `ios_debug_context` で、permission-related hypothesis を診断メモに含めるべきです。

この診断は heuristic であり、OS permission state の authoritative source ではありません。
FlutterHelm は `Info.plist`、Bonjour 設定、session health、recent logs を材料に hypothesis を提示し、最終確認は Xcode / iOS Settings に委ねます。

## 11. Audit Log

すべての mutation / runtime control は JSONL 監査ログに残します。

### Example

```json
{
  "timestamp": "2026-04-11T12:40:00Z",
  "actor": "mcp-client",
  "tool": "dependency_add",
  "riskClass": "project_mutation",
  "workspaceRoot": "/work/app",
  "approved": true,
  "result": "success"
}
```

## 11.1 Artifact pinning

diagnostics を後で native handoff や人間レビューに渡すため、file-backed artifact は明示的に pin できます。

- `artifact_pin`
- `artifact_unpin`
- `artifact_pin_list`
- `config://artifacts/pins`

pin は retention sweep を止めるための明示操作であり、`config://` や `session://.../summary|health` のような軽量 resource には使いません。

## 11.2 Release / migration notes

beta-ready release では、互換性のある変更を public resource で先に告知します。

- legacy adapter config の deprecation は resource / tool に出す
- HTTP preview の制約は `README` と `docs/10-migration-notes.md` に明記する
- contract version の変更は `serverInfo` と migration notes をセットで確認する

## 12. Failure Disclosure

エラー設計では次を守ります。

- client には短い reason を返す
- 詳細は resource に逃がす
- secret を含む raw stderr をそのまま返さない
- internal stack trace は debug mode のみ

## 13. Threat Model Summary

| 脅威 | 具体例 | 対策 |
|---|---|---|
| 越境書き込み | root 外ファイル編集 | root validation |
| 誤依存追加 | agent が勝手に package 導入 | approval gate |
| 状態破壊 | hot restart 乱発 | risk class + confirmation |
| 秘密漏えい | logs に token 混入 | redaction |
| attached process 誤停止 | 他ツール起動 app の kill | ownership rule |
| profiling 誤期待 | debug mode で誤った性能判断 | profile mode guidance + session health |
| attached profiling | attach 済み app に対する重い capture | owned-session only policy |
| runtime interaction 誤作動 | 弱い semantics で別 widget を操作 | locator contract + explicit capability errors |
| native debugger 置換誤解 | FlutterHelm だけで iOS/Android deep debug できると誤認 | handoff-only UX + bundle limitations |
| HTTP preview 誤露出 | LAN 越しに preview transport を使えると誤認 | localhost-only bind + origin validation + preview 明示 |
| custom adapter 誤設定 | 未検証 provider が workflow を壊す | explicit config registration + family validation + health visibility |

## 14. 結論

FlutterHelm の安全性は、「危険操作を禁止すること」だけでは成立しません。  
必要なのは、**危険操作を分類し、説明し、確認し、記録すること**です。  
この 4 点が揃って初めて、AI に開発の舵を持たせても制御可能になります。
