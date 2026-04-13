# Troubleshooting

このページは、FlutterHelm の **日常運用で遭遇しやすい失敗モード** をまとめたものです。  
まずは error message そのものより、`session://.../health` と `config://...` の read-only resource を確認するのが基本です。

## 1. 先に見る場所

問題の種類ごとに、先に見る場所を固定しておくと速いです。

| 確認したいこと | 先に見るもの |
|---|---|
| root / profile / transport の現在値 | `config://workspace/current` |
| 実行環境が足りているか | `config://compatibility/current` |
| adapter の active provider / health | `config://adapters/current` |
| session の稼働条件 / capability failure | `session://<session-id>/health` |
| artifact 容量 / sweep 状態 | `config://artifacts/status` |
| counters / 運用状態 | `config://observability/current` |

## 2. よくある問題と対処

| 症状 | よくある原因 | まずやること |
|---|---|---|
| `approval_required` | risky mutation に confirmation が必要 | response の `approvalRequestId` を確認し、同じ tool と同じ引数で `approvalToken` を付けて再実行する |
| `WORKSPACE_BUSY` | 同じ workspace に対する mutation が並行実行中 | `activeTool` を見て競合を解消し、mutation を直列化する |
| `SESSION_BUSY` | 同じ session に対する mutation / profiling / interaction が並行実行中 | 同じ `sessionId` への操作を一度に 1 つに絞る |
| `WORKSPACE_ROOT_REQUIRED` | active root が未設定 | `workspace_show` を確認し、`workspace_set_root` を先に実行する |
| `ROOTS_MISMATCH` | client roots 外を触ろうとしている | roots-aware client なら roots を見直し、そうでなければ `--allow-root-fallback` の是非を判断する |
| `SESSION_STALE` | server 再起動後に古い session metadata だけ残っている | `session_list` で stale を確認し、必要なら `run_app` か `attach_app` で新しい live session を作る |
| `SESSION_NOT_RUNNING` | 停止済み / failed session に対して live-only tool を使っている | `session://<id>/health` を見て状態を確認し、必要なら再起動する |
| `RUNTIME_DRIVER_UNAVAILABLE` / `RUNTIME_DRIVER_NOT_CONNECTED` | `runtime_interaction` が無効、driver が disabled、provider が未設定、または接続不良 | `enabledWorkflows`、`adapter_list`、`config://adapters/current`、`session://<session-id>/health` を確認する |
| `SEMANTIC_LOCATOR_NOT_FOUND` / `SEMANTIC_LOCATOR_AMBIGUOUS` / `SEMANTIC_LOCATOR_UNSUPPORTED` | locator が弱い、または provider がその field をサポートしていない | `label`, `valueKey`, `type`, `index` を見直し、provider の `supportedLocatorFields` を確認する |
| profiling tool が失敗する | owned session ではない、stale、VM service がない、mode が不適切 | `session://<id>/health` を開き、`ownership`, `stale`, `vmServiceAvailable`, `currentMode` を確認する |
| `ADAPTER_PROVIDER_UNHEALTHY` / `ADAPTER_INVOKE_FAILED` | custom `stdio_json` provider が落ちた、timeout、handshake failure | `adapter_list` と `config://adapters/current` の `healthy` / lifecycle state / reason を確認する |
| HTTP preview で `405` / `400` / `404` | preview 制約、header 欠落、session expiry | preview 前提を確認し、基本は `stdio` に戻す |
| profile が見つからない | `--profile` または `FLUTTERHELM_PROFILE` が未定義 | `workspace_show.availableProfiles` を見て profile 名を修正する |
| server 起動時に adapter config error | legacy adapter fields を stable cut 後も使っている | [Migration Notes](10-migration-notes.md) を見て `adapters.active` / `adapters.providers` へ移行する |

## 3. `approval_required` が返る時

approval flow は次です。

1. 最初の risky call が `approval_required` を返す
2. response から `approvalRequestId` を取る
3. 同じ tool と同じ正規化引数で `approvalToken=approvalRequestId` を付けて再実行する

approval token は one-time です。  
tool 名、workspace、引数が変わると通りません。

## 4. Busy エラーの考え方

FlutterHelm は mutation を queue せず、**fail-fast** で拒否します。  
これは「あとで勝手に走る mutation」を避けるためです。

運用上は次を守ると安定します。

- 同じ workspace への mutation は直列化する
- 同じ session への profiling / hot ops / interaction は直列化する
- read-only call は基本的に並列でもよい

## 5. Root と fallback で詰まる時

基本は roots-aware client と explicit root selection です。  
HTTP preview では Roots transport を扱わないため、より保守的に扱います。

確認する順は次です。

1. `workspace_show`
2. `config://workspace/current`
3. client 側の roots 設定
4. `--allow-root-fallback` を使うべきか

fallback は「何でも許可する」モードではありません。  
明示 opt-in で、write tool 側でも active root が必要です。

## 6. Session が stale になる時

session metadata は永続化されますが、live process handle は process lifetime だけです。  
そのため server 再起動後、以前の session は `stale=true` で復元されます。

実務上の判断は次です。

- logs や summary を読みたいだけなら stale session を使ってよい
- mutation, profiling, hot reload/restart, live widget tree は新しい live session を作る

## 7. Runtime interaction が動かない時

まず確認するポイントは 3 つです。

1. `runtime_interaction` workflow を有効化しているか
2. runtime driver provider が active か
3. locator field が provider に supported か

確認先:

- `workspace_show`
- `adapter_list`
- `config://adapters/current`
- `session://<session-id>/health`

`session://<session-id>/health` では、少なくとも次を見ます。

- `runtimeDriverEnabled`
- `driverConnected`
- `runtimeInteractionReady`
- `screenshotReady`

`runtimeDriver` を explicit に選んだだけなら自動的に有効化されます。  
無効化したい場合だけ provider 側で `options.enabled: false` を指定します。

driver に依存しない `capture_screenshot` でも、iOS simulator 以外では fallback がない場合があります。  
result の `backend` と `fallbackUsed` を見ると、driver 経由か fallback 経由かを判別できます。
stable path だけで進めるなら、runtime interaction を無理に有効化せず `runtime_readonly` と profiling / native handoff を中心に使ってください。

## 8. Profiling が使えない時

profiling failure は `session://<session-id>/health` に寄せて確認します。  
特に見る field は次です。

- `ownership`
- `stale`
- `vmServiceAvailable`
- `dtdAvailable`
- `currentMode`
- `recommendedMode`
- `backend`

attached session や stale session では profiling は通りません。  
owned + running + live VM service session を作り直すのが最短です。

## 9. HTTP preview で混乱しやすい点

HTTP transport は **preview** であり、stable lane には入りません。  
次の制約を前提に使ってください。

- localhost-only
- request-response only
- `GET` は `405 Method Not Allowed`
- `MCP-Session-Id` が必要
- idle expiry がある
- Roots transport は unsupported

preview で詰まった時の第一選択は、機能追加ではなく `stdio` へ戻すことです。

## 10. custom provider が不安定な時

custom `stdio_json` provider は `beta` です。  
provider lifecycle は `starting`, `healthy`, `degraded`, `backoff` を取ります。

確認する点:

- `adapter_list` の `healthy`
- `config://adapters/current` の `deprecations`, lifecycle state, reason
- `compatibility_check` の degraded reason

provider を疑う時は、まず built-in provider に戻して再現するかを確認してください。  
そこで消えるなら、server 本体ではなく provider 側の問題として切り分けやすくなります。

## 11. artifact が消える / 残りすぎる時

FlutterHelm は age-based sweep に加えて capacity-based retention を行います。  
ただし pin された artifact は自動削除しません。

見る場所:

- `artifact_pin_list`
- `config://artifacts/pins`
- `config://artifacts/status`

証拠を残したい run は、早めに `artifact_pin` してください。

## 12. それでも詰まる時の順番

1. `workspace_show`
2. `compatibility_check`
3. `adapter_list`
4. `session_list`
5. `session://<session-id>/health`
6. 必要なら [User Guide](11-user-guide.md) で stable path に戻る
7. config migration が怪しければ [Migration Notes](10-migration-notes.md) を確認する
