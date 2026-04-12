# Roadmap

この roadmap は「いつまでに」ではなく、**どの順序でリスクを潰すか**に焦点を当てます。

## フェーズ設計の基本方針

FlutterHelm は最初から全部を載せるべきではありません。  
依存面が多く、official MCP / CLI / DevTools / DTD / device runtime / native bridge が絡むためです。

したがって、進め方は次の順にします。

1. **read-heavy で安定化**
2. **run / attach / test の反復確立**
3. **artifact / profiling 追加**
4. **native bridge**
5. **optional runtime interaction**

## 現在地点

この repository では Phase 4 の platform bridge checkpoint まで実装済みです。

- workspace/session/launcher/runtime_readonly/tests が local で動く
- repo-local `fixtures/sample_app` で deterministic validation ができる
- package search → approval → dependency add/remove が local で動く
- integration test / coverage artifact / approval audit が local で動く
- vm_service-backed profiling / session health / owned-session guard が local で動く
- native handoff bundle / iOS local-network hypothesis / Android synthetic contract が local で動く
- 以降の優先順位は runtime interaction

## Phase 0 — Foundation

### 目的

- contract の核を固定する
- repo を切る
- docs / ADR を確定する
- stdio server 骨格を作る

### Deliverables

- MCP frontend skeleton
- versioned tool registry
- roots handling
- config file format
- audit log skeleton
- docs site build

### Exit criteria

- `workspace_show`
- `session_open`
- `session_list`
- `workspace_set_root`
- `serverInfo` / capability negotiation

## Phase 1 — Alpha: Local read / run loop

### 目的

- まず「理解して走らせる」を成立させる

### Deliverables

- workspace discovery
- analyze / resolve / format
- device list
- `run_app`
- `attach_app`
- `stop_app`
- `get_logs`
- `get_runtime_errors`
- `get_widget_tree`
- unit/widget tests
- basic resource store

### Exit criteria

- ローカル Flutter app を起動し session 化できる
- layout error の観測までできる
- widget tree を resource として読める
- unit / widget test report が resource 化される

## Phase 2 — Beta: Test / package / coverage

### 目的

- 変更を安全に入れ、検証し、結果を残せるようにする

### Deliverables

- `pub_search`
- `dependency_add`
- `dependency_remove`
- integration tests
- coverage collection
- confirmation tokens
- audit log completion
- root fallback mode

### Exit criteria

- package search → approval → dependency add が成立
- integration tests が run id / report / logs を返す
- coverage resource が読める
- risky actions に確認が必ず入る

## Phase 3 — Profiling

### 目的

- performance / memory diagnostics を session に接続する

### Deliverables

- `start_cpu_profile`
- `stop_cpu_profile`
- `capture_memory_snapshot`
- `capture_timeline`
- `toggle_performance_overlay`
- profile session guidance
- stale session health diagnostics

### Exit criteria

- owned session 上で profiling loop を扱える
- CPU / memory / timeline が resource 化される
- diagnostics failure が `session://<id>/health` と capability metadata で説明される

## Phase 4 — Platform bridge

### 目的

- Flutter だけで閉じない不具合を native 側へ橋渡しできるようにする

### Deliverables

- `ios_debug_context`
- `android_debug_context`
- `native_handoff_summary`
- session から native handoff bundle 生成
- iOS local network permission diagnostics

### Exit criteria

- native 側へ持ち込むべき artifact, logs, hypotheses がまとまる
- FlutterHelm が native debugger replacement ではないことが UX 上も明確

## Phase 5 — Optional runtime interaction

### 目的

- 実行中 UI への操作を optional な高次 workflow として提供する

### Deliverables

- runtime driver abstraction
- `tap_widget`
- `enter_text`
- `scroll_until_visible`
- `capture_screenshot`
- driver health / capability discovery
- semantic locator contract

### Exit criteria

- driver 未接続でも core workflow に影響しない
- widget semantics が弱い場合の失敗が明確
- screenshot が artifact として扱える

## Phase 6 — Hardening / Ecosystem

### 目的

- 実運用での安定性と拡張性を上げる

### Deliverables

- Streamable HTTP preview
- concurrency handling
- pinned artifacts
- config profiles
- compatibility matrix
- extension / plugin point for custom adapters

### Exit criteria

- contract バージョニングが定着
- downgrade / fallback が十分に説明可能
- community or internal adapter を受け入れられる構造

## リリースチャネル案

| Channel | 目的 | 特徴 |
|---|---|---|
| `nightly` | contract 検証 | breaking あり |
| `alpha` | local flow 実験 | limited support |
| `beta` | 実務試用 | migration notes あり |
| `stable` | contract 重視 | cautious changes |

## 優先順位の考え方

FlutterHelm の価値は「派手な UI automation」ではなく、

- 実行中アプリを session として掴める
- 観測 artifact を resource として残せる
- 依存変更や state 破壊を安全に扱える

ことにあります。

したがって、roadmap の優先順位は次の通りです。

1. run / inspect / test
2. safety / audit
3. profiling
4. native bridge
5. UI interaction

順序を逆にすると、見た目は派手でも土台が脆くなります。
