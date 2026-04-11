# 設計根拠

この文書は、FlutterHelm の設計がどの外部事実に依拠しているかを整理するものです。  
ここで重要なのは、**FlutterHelm がゼロから独自の世界観を作るのではなく、公式の既存面を束ねる前提で設計されている**ことです。

## 1. 公式 Dart and Flutter MCP server は存在する

公式 docs によると、Dart and Flutter MCP server は **experimental** であり、Dart 3.9+ を前提に、AI assistant に対して Flutter / Dart 開発ツール操作を expose します。また、機能利用には MCP client 側で **Tools** と **Resources** の対応が必要で、より良い体験には **Roots** の対応も推奨されています。さらに、client が roots を適切に設定できない場合に備え、`--force-roots-fallback` が案内されています。  
この時点で、Flutter 開発の AI 連携はすでに「MCP で expose する」方向へ明確に舵が切られています。FlutterHelm はこれに逆らうべきではありません。  
参照: [Flutter Docs - Dart and Flutter MCP server](https://docs.flutter.dev/ai/mcp-server)

## 2. 公式サーバーの価値は「静的解析」だけではない

同じ公式 docs では、Dart and Flutter MCP server が次のことを行えると説明されています。

- プロジェクトコードの解析と修正
- symbol 解決と documentation / signature 取得
- 実行中アプリの introspection / interaction
- `pub.dev` 検索
- `pubspec.yaml` の dependency 管理
- テスト実行と結果解析

また、runtime layout error の例では、AI agent が **runtime error を取得し、widget tree を読み、修正を当てる**流れが明示されています。  
つまり設計の重心は、単なるコード補完ではなく**running app を含む closed loop** にあります。  
参照: [Flutter Docs - Dart and Flutter MCP server](https://docs.flutter.dev/ai/mcp-server)

## 3. それでも Flutter の標準実行面は `flutter` CLI

Flutter 公式 docs は、`flutter` command-line tool を、**developer または IDE が Flutter とやり取りする標準インターフェース**として位置づけています。  
これは重要です。FlutterHelm が実行面を設計するとき、`flutter run`, `flutter test`, `flutter build`, `flutter attach` を無視して独自に再定義するのは筋が悪いです。  
実行面は CLI をラップし、policy / session / artifact を追加する方向が自然です。  
参照: [Flutter Docs - The Flutter command-line tool](https://docs.flutter.dev/reference/flutter-cli)

## 4. 観測面の中心は DevTools

Flutter / Dart DevTools は公式 docs で、**performance and debugging tools の suite** と位置づけられています。  
さらに、Flutter inspector は **widget tree を探索する面** として明示され、CPU profiler は CPU サンプリング可視化、Memory view は allocation / leak / memory bloat を扱います。  
このため、FlutterHelm が runtime 観測と profiling を扱う場合、その本体は「DevTools / DTD に寄せて Resource 化する」方が正確です。  
参照:

- [Flutter Docs - DevTools overview](https://docs.flutter.dev/tools/devtools)
- [Flutter Docs - Flutter inspector](https://docs.flutter.dev/tools/devtools/inspector)
- [Flutter Docs - CPU profiler](https://docs.flutter.dev/tools/devtools/cpu-profiler)
- [Flutter Docs - Memory view](https://docs.flutter.dev/tools/devtools/memory)

## 5. profiling は profile mode / physical device 前提で設計すべき

Flutter performance profiling の docs では、実機接続・profile mode・DevTools を用いる流れが明確に整理されています。  
したがって FlutterHelm の profiling workflow は、debug mode の片手間機能として扱うのではなく、**profile session を明示的に作る設計**にすべきです。  
参照: [Flutter Docs - Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance)

## 6. native code の深掘りは native debugger を前提にすべき

Flutter の native debugging docs では、iOS / macOS は Xcode、Android は Android Studio、Windows は Visual Studio を使うとされています。  
これは、FlutterHelm が native bridge を設計する際に重要です。  
FlutterHelm は native debugger を置き換えるべきではなく、**そこへ文脈を渡す橋**に留めるべきです。  
参照: [Flutter Docs - Use a native language debugger](https://docs.flutter.dev/testing/native-debugging)

## 7. iOS には local network permission 由来の実務上の罠がある

Flutter の iOS debugging docs では、iOS 14+ で hot reload や DevTools を使うために local network permission ダイアログの許可が必要と明記されています。  
FlutterHelm が iOS runtime の attach / inspect を扱うとき、これを無視すると「接続不能」の原因を誤診しやすいです。  
参照: [Flutter Docs - iOS debugging](https://docs.flutter.dev/platform-integration/ios/ios-debugging)

## 8. MCP 側の設計原則は Tools / Resources / Roots / transport にある

MCP 仕様では、Resources は **URI で識別される context data** を server が expose する面であり、Roots は client から server へ与えられる filesystem boundary です。  
さらに transports 仕様では、`stdio` と Streamable HTTP が定義され、**clients SHOULD support stdio whenever possible** とされています。  
FlutterHelm はこの原則に沿い、初期 transport を stdio-first にするのが妥当です。  
参照:

- [MCP Specification - Overview](https://modelcontextprotocol.io/specification/2025-11-25)
- [MCP Specification - Resources](https://modelcontextprotocol.io/specification/2025-06-18/server/resources)
- [MCP Specification - Roots](https://modelcontextprotocol.io/specification/2025-06-18/client/roots)
- [MCP Specification - Transports](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)

## 9. ここから導かれる設計方針

以上を踏まえた FlutterHelm の第一原則は次の通りです。

1. **公式 Dart and Flutter MCP server の代替ではなく上位 orchestrator として振る舞う**
2. **`flutter` CLI を実行面の正規口とみなす**
3. **runtime / profiling 出力は Resource 中心に扱う**
4. **native debugger 置換ではなく native bridge として設計する**
5. **stdio-first、Roots-aware、safe-by-default で進める**

この方針が、以後の PRD / architecture / contract / safety 設計の土台になります。
