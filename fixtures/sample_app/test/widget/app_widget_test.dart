import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sample_app/app.dart';

void main() {
  testWidgets('counter scenario increments on tap', (WidgetTester tester) async {
    await tester.pumpWidget(
      SampleApp(scenario: DemoScenario.normal),
    );

    expect(find.text('Counter value'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('normal scenario renders the fixture shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      SampleApp(scenario: DemoScenario.normal),
    );

    expect(find.text('FlutterHelm Sample'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
  });
}
