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

ただし session が `attached` の場合は自動許可しない。

## 5. Filesystem Boundary

### Roots-aware mode

- root 外の file path は拒否
- symlink resolve 後に root 内判定
- write は active root のみ

### Root fallback mode

- server 起動時に `--allow-root-fallback` が必要
- user が明示 root を選ぶまで write tool を無効
- 現在 root は `config://workspace/current` で可視化

## 6. Process Safety

### Stop / restart rules

- `stop_app` は owned session 優先
- attached session への kill は拒否
- `hot_restart` は state 破壊を明示
- stale session では restart を拒否し、再 run/attach を促す

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

## 9. Native Bridge Safety

Flutter 公式 docs にある通り、native code debugging は iOS/macOS なら Xcode、Android なら Android Studio などが前提です。  
したがって FlutterHelm は native bridge を **handoff context generator** として扱います。  
「Xcode を完全制御する」「Android Studio を自動操作する」は初期スコープに入れません。

## 10. iOS-specific Safety Note

iOS 14+ では local network permission を許可しないと hot reload や DevTools が動かないことがあります。  
このため、iOS session の attach 不全を単純な tool failure と扱うのは危険です。FlutterHelm は `ios_debug_context` で、permission-related hypothesis を診断メモに含めるべきです。

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

## 14. 結論

FlutterHelm の安全性は、「危険操作を禁止すること」だけでは成立しません。  
必要なのは、**危険操作を分類し、説明し、確認し、記録すること**です。  
この 4 点が揃って初めて、AI に開発の舵を持たせても制御可能になります。
