import 'package:flutter_test/flutter_test.dart';
import 'package:sample_app/app.dart';

void main() {
  test('parseScenario resolves overflow and normal inputs', () {
    expect(parseScenario('overflow'), DemoScenario.overflow);
    expect(parseScenario('interaction_demo'), DemoScenario.interactionDemo);
    expect(parseScenario('anything-else'), DemoScenario.normal);
  });

  test('CounterModel increments in place', () {
    final counter = CounterModel(value: 3);
    counter.increment();
    counter.increment();

    expect(counter.value, 5);
  });
}
