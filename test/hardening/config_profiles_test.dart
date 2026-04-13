import 'dart:io';

import 'package:flutterhelm/config/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ConfigRepository profiles', () {
    test('applies a selected profile overlay and replaces arrays', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-config');
      addTearDown(() => sandbox.delete(recursive: true));

      final runtimePaths = RuntimePaths(
        configPath: p.join(sandbox.path, 'config.yaml'),
        stateDir: p.join(sandbox.path, 'state'),
      );
      await File(runtimePaths.configPath).writeAsString('''
version: 1
workspace:
  roots:
    - /tmp/base
defaults:
  target: lib/main.dart
  mode: debug
enabledWorkflows:
  - workspace
  - session
fallbacks:
  allowRootFallback: false
retention:
  heavyArtifactsDays: 7
  metadataDays: 30
adapters:
  providers:
    custom.runtime.driver:
      kind: stdio_json
      families:
        - runtimeDriver
      command: dart
      args:
        - run
        - tool/fake_runtime_driver.dart
      startupTimeoutMs: 8000
profiles:
  sim:
    defaults:
      mode: profile
    enabledWorkflows:
      - workspace
      - session
      - runtime_interaction
    adapters:
      active:
        runtimeDriver: custom.runtime.driver
''');

      final config = await ConfigRepository(runtimePaths).load(
        selectedProfile: 'sim',
      );

      expect(config.activeProfile, 'sim');
      expect(config.availableProfiles, contains('sim'));
      expect(config.defaults.mode, 'profile');
      expect(config.enabledWorkflows, <String>[
        'workspace',
        'session',
        'runtime_interaction',
      ]);
      expect(
        config.adapters.activeProviders['runtimeDriver'],
        'custom.runtime.driver',
      );
      expect(
        config.adapters.providerForFamily('runtimeDriver')?.kind,
        'stdio_json',
      );
    });

    test('throws when a selected profile does not exist', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-config');
      addTearDown(() => sandbox.delete(recursive: true));

      final runtimePaths = RuntimePaths(
        configPath: p.join(sandbox.path, 'config.yaml'),
        stateDir: p.join(sandbox.path, 'state'),
      );
      await File(runtimePaths.configPath).writeAsString('version: 1\n');

      await expectLater(
        ConfigRepository(runtimePaths).load(selectedProfile: 'missing'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
