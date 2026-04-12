import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sample_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('sample app launches and shows the counter shell', (
    WidgetTester tester,
  ) async {
    app.main();
    await tester.pumpAndSettle();

    expect(find.text('FlutterHelm Sample'), findsOneWidget);
    expect(find.text('Counter value'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
  });
}
