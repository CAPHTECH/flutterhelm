# Migration Notes

English version: [docs/en/migration-notes.md](en/migration-notes.md)

このドキュメントは FlutterHelm の stable migration notes です。

## 1. Stable release contract

FlutterHelm の current implementation は stable-ready です。  
public contract version は `0.2.0-stable` です。

## 2. 何が変わったか

- adapter registration は `adapters.active` / `adapters.providers` を優先する
- legacy adapter fields はもう受理しない
- Streamable HTTP は localhost-only preview としてのみ提供する
- HTTP preview は request-response only のままで、Roots transport parity は主張しない
- support level は `stable`, `beta`, `preview` を明示する

## 3. Upgrade guidance

- custom adapter は explicit registry entry へ移す
- legacy adapter fields が残っているなら、server 起動前に移行する
- support level と provider status は `adapter_list`, `config://adapters/current`, `compatibility_check` で読む
- preview HTTP endpoint が明示的に必要でない限り、default transport は `stdio` のままにする
- `--allow-root-fallback` は client が有用な Roots 情報を渡せない時だけ使う

## 4. Support levels

- `stable`: `stdio`, workspace/session/launcher/runtime_readonly/tests/profiling/platform_bridge, built-in adapter path
- `beta`: `runtime_interaction`, custom `stdio_json` providers
- `preview`: HTTP transport

## 5. Verification

推奨 stable validation command:

```bash
mise exec -- pnpm -C harness stable
```

推奨 superset validation command:

```bash
mise exec -- pnpm -C harness beta
```

`stable` は supported stable lane を実行します。`beta` はそこに `ecosystem`, `delegate`, `interaction`, `native-build` を加えます。

## 6. Sprint 16 beta wave

Sprint 16 では native build orchestration を beta として追加しました。

- `native_build` is beta
- adapter family は `nativeBuild`
- harness lane は `native-build`
- scope は iOS-first の build / launch / Flutter runtime attach
- stable lane には含めない

## 7. Sprint 17 official delegate wave

Sprint 17 では built-in `delegate` family を official Flutter MCP first に切り替えました。

- primary backend は `dart mcp-server --tools all --force-roots-fallback`
- 対象 tool は `analyze_project`, `resolve_symbol`, `pub_search`, `dependency_add`, `dependency_remove`, `get_runtime_errors`, `get_widget_tree`, `hot_reload`, `hot_restart`
- official delegate unavailable / timeout / malformed payload / DTD connect failure の場合は current backend に fallback
- support level は変えず、stable contract は `0.2.0-stable` のまま

推奨 native build validation command:

```bash
mise exec -- pnpm -C harness native-build
```
