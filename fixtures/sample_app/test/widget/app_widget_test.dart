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

  testWidgets('interaction scenario exposes tappable and scrollable controls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      SampleApp(scenario: DemoScenario.interactionDemo),
    );
    await tester.pumpAndSettle();

    expect(find.text('Interaction Demo'), findsOneWidget);
    expect(find.text('Tap primary'), findsOneWidget);
    expect(find.text('Name input'), findsWidgets);
    expect(find.text('Deep action'), findsNothing);

    final scrollable = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(
      find.text('Deep action'),
      300,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    expect(find.text('Deep action'), findsOneWidget);
  });
}
