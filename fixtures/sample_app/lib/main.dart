import 'package:flutter/widgets.dart';
import 'package:sample_app/app.dart';

void main() {
  const rawScenario = String.fromEnvironment(
    'FLUTTERHELM_SCENARIO',
    defaultValue: 'normal',
  );
  runApp(SampleApp(scenario: parseScenario(rawScenario)));
}
