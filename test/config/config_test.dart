import 'dart:io';

import 'package:flutterhelm/flutterhelm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('RuntimePaths', () {
    test('resolves HOME-scoped defaults with env overrides', () {
      final paths = RuntimePaths.fromEnvironment(
        environment: <String, String>{'HOME': '/tmp/example-home'},
      );

      expect(
        paths.configPath,
        p.join('/tmp/example-home', '.config', 'flutterhelm', 'config.yaml'),
      );
      expect(
        paths.stateDir,
        p.join('/tmp/example-home', '.config', 'flutterhelm'),
      );
    });
  });

  group('ConfigRepository', () {
    test('returns defaults when config file is missing', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-config',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final repository = ConfigRepository(
        RuntimePaths(
          configPath: p.join(tempDir.path, 'missing.yaml'),
          stateDir: p.join(tempDir.path, 'state'),
        ),
      );

      final config = await repository.load();
      expect(config.version, 1);
      expect(config.defaults.target, 'lib/main.dart');
      expect(
        config.enabledWorkflows,
        containsAll(<String>['workspace', 'session']),
      );
    });

    test('parses yaml config and preserves workflow defaults', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-config',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final configFile = File(p.join(tempDir.path, 'config.yaml'));
      await configFile.writeAsString('''
version: 1
workspace:
  roots:
    - /work/app
defaults:
  target: lib/staging.dart
  mode: profile
enabledWorkflows:
  - workspace
  - session
fallbacks:
  allowRootFallback: true
''');

      final repository = ConfigRepository(
        RuntimePaths(
          configPath: configFile.path,
          stateDir: p.join(tempDir.path, 'state'),
        ),
      );

      final config = await repository.load();
      expect(config.workspace.roots, <String>['/work/app']);
      expect(config.defaults.target, 'lib/staging.dart');
      expect(config.defaults.mode, 'profile');
      expect(config.fallbacks.allowRootFallback, isTrue);
    });

    test('normalizes legacy adapters into the registry shape', () {
      final config = FlutterHelmConfig.fromYamlText('''
version: 1
adapters:
  delegate:
    type: dart_flutter_mcp
  flutterCli:
    executable: flutter
  runtimeDriver:
    enabled: true
    command: npx
    args:
      - -y
      - "@mobilenext/mobile-mcp@latest"
      - --stdio
    startupTimeoutMs: 8000
''');

      expect(
        config.adapters.activeProviders['runtimeDriver'],
        'builtin.runtime_driver.external_process',
      );
      final provider = config.adapters.providerForFamily('runtimeDriver');
      expect(provider, isNotNull);
      expect(provider!.kind, 'builtin');
      expect(provider.command, 'npx');
      expect(provider.args, contains('--stdio'));
      expect(provider.options['enabled'], isTrue);
      expect(config.adapters.deprecations, isNotEmpty);
      expect(
        config.adapters.deprecations.map((entry) => entry['field']),
        containsAll(<String?>[
          'adapters.delegate',
          'adapters.flutterCli',
          'adapters.runtimeDriver',
        ]),
      );
    });

    test('parses explicit adapter providers and active family selection', () {
      final config = FlutterHelmConfig.fromYamlText('''
version: 1
adapters:
  active:
    runtimeDriver: custom.runtime.driver
  providers:
    custom.runtime.driver:
      kind: stdio_json
      families:
        - runtimeDriver
      command: dart
      args:
        - run
        - tool/fake_stdio_adapter_provider.dart
      startupTimeoutMs: 9000
''');

      expect(
        config.adapters.activeProviders['runtimeDriver'],
        'custom.runtime.driver',
      );
      final provider = config.adapters.providerForFamily('runtimeDriver');
      expect(provider, isNotNull);
      expect(provider!.kind, 'stdio_json');
      expect(provider.command, 'dart');
      expect(provider.args, contains('tool/fake_stdio_adapter_provider.dart'));
      expect(provider.startupTimeoutMs, 9000);
      expect(config.adapters.deprecations, isEmpty);
    });

    test('rejects unsupported config versions', () {
      expect(
        () => FlutterHelmConfig.fromYamlText('version: 2'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('StateRepository', () {
    test('persists active root state', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-state',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final runtimePaths = RuntimePaths(
        configPath: p.join(tempDir.path, 'config.yaml'),
        stateDir: p.join(tempDir.path, 'state'),
      );
      final repository = StateRepository(runtimePaths);

      await repository.save(
        ServerState.empty().copyWith(
          activeRoot: '/tmp/workspace',
          updatedAt: DateTime.utc(2026, 4, 12),
        ),
      );

      final loaded = await repository.load();
      expect(loaded.activeRoot, '/tmp/workspace');
      expect(loaded.updatedAt, DateTime.utc(2026, 4, 12));
    });
  });
}
