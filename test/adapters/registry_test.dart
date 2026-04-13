import 'dart:io';

import 'package:flutterhelm/adapters/registry.dart';
import 'package:flutterhelm/artifacts/pins.dart';
import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/hardening/tools.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AdapterRegistry', () {
    test('surfaces legacy adapter deprecations in current resources and compatibility checks', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-adapter-registry',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final providerScript = await _writeProviderScript(tempDir);
      final config = FlutterHelmConfig.fromYamlText('''
version: 1
adapters:
  delegate:
    type: dart_flutter_mcp
  flutterCli:
    executable: flutter
  runtimeDriver:
    enabled: true
    command: dart
    args:
      - run
      - ${providerScript.path}
      - healthy
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
        - ${providerScript.path}
        - healthy
''');
      final registry = AdapterRegistry(
        config: config,
        processRunner: const ProcessRunner(),
      );
      final currentResource = await registry.currentResource();
      expect(currentResource['deprecations'], isNotEmpty);
      final providerStates =
          currentResource['providerStates'] as Map<String, Object?>;
      final customState = providerStates['custom.runtime.driver']
          as Map<String, Object?>;
      expect(customState['state'], 'healthy');
      expect(customState['healthy'], isTrue);

      final compatibility = await (await _buildHardeningService(tempDir))
          .compatibilityCheck(
            config: config,
            activeRoot: tempDir.path,
            transportMode: 'stdio',
          );
      expect(compatibility['deprecations'], isNotEmpty);
      final adapters = compatibility['adapters'] as Map<String, Object?>;
      expect(adapters['deprecations'], isNotEmpty);
      final providerStatesFromCompatibility =
          adapters['providerStates'] as Map<String, Object?>;
      expect(
        (providerStatesFromCompatibility['custom.runtime.driver']
                as Map<String, Object?>)['state'],
        'healthy',
      );
    });

    test('backs off and retries stdio_json providers lazily', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-adapter-backoff',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final providerScript = await _writeProviderScript(tempDir);
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
        - ${providerScript.path}
        - exit-after-init
''');
      final registry = AdapterRegistry(
        config: config,
        processRunner: const ProcessRunner(),
      );

      final first = await registry.familyStatus('runtimeDriver');
      expect(first.state, 'backoff');
      expect(first.failureCount, 1);
      expect(first.healthy, isFalse);
      expect(first.reason, isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      final second = await registry.familyStatus('runtimeDriver');
      expect(second.state, 'backoff');
      expect(second.failureCount, 2);
      expect(second.healthy, isFalse);
      expect(second.backoffUntil, isNotNull);

      final third = await registry.familyStatus('runtimeDriver');
      expect(third.state, 'backoff');
      expect(third.failureCount, 2);
      expect(third.healthy, isFalse);
    });
  });
}

Future<HardeningToolService> _buildHardeningService(Directory tempDir) async {
  final stateDir = p.join(tempDir.path, 'state');
  final pinStore = await ArtifactPinStore.create(stateDir: stateDir);
  return HardeningToolService(
    artifactStore: ArtifactStore(stateDir: stateDir),
    pinStore: pinStore,
    processRunner: const ProcessRunner(),
    configRepository: ConfigRepository(
      RuntimePaths(
        configPath: p.join(tempDir.path, 'config.yaml'),
        stateDir: stateDir,
      ),
    ),
  );
}

Future<File> _writeProviderScript(
  Directory tempDir,
) async {
  final file = File(p.join(tempDir.path, 'temp_provider.dart'));
  await file.writeAsString(_providerScript);
  return file;
}

const String _providerScript = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args.isNotEmpty ? args.last : 'healthy';
  await stdout.flush();
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, Object?>;
    final id = message['id'];
    final method = message['method'] as String?;
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, Object?>{
        'id': id,
        'result': <String, Object?>{
          'adapterProtocolVersion': 'flutterhelm.adapter.v1',
          'providerInfo': <String, Object?>{
            'name': 'temp-provider',
            'version': '1.0.0',
          },
        },
      }));
      await stdout.flush();
      if (mode == 'exit-after-init') {
        exit(0);
      }
      continue;
    }
    if (method == 'provider/health') {
      stdout.writeln(jsonEncode(<String, Object?>{
        'id': id,
        'result': <String, Object?>{
          'state': mode == 'degraded' ? 'degraded' : 'healthy',
          'healthy': mode != 'degraded',
          'reasons': mode == 'degraded'
              ? <String>['temporarily degraded']
              : <String>[],
          'providerInfo': <String, Object?>{
            'name': 'temp-provider',
            'version': '1.0.0',
          },
          'families': <String, Object?>{
            'runtimeDriver': <String, Object?>{
              'healthy': mode != 'degraded',
              'operations': <String>['capture_screenshot'],
              'supportedPlatforms': <String>['ios'],
              'supportedLocatorFields': <String>['text'],
              'screenshotFormats': <String>['png'],
              'reason': mode == 'degraded' ? 'temporarily degraded' : null,
              'reasons': mode == 'degraded'
                  ? <String>['temporarily degraded']
                  : <String>[],
              'state': mode == 'degraded' ? 'degraded' : 'healthy',
            },
          },
        },
      }));
      await stdout.flush();
      continue;
    }
    if (method == 'provider/invoke') {
      stdout.writeln(jsonEncode(<String, Object?>{
        'id': id,
        'result': <String, Object?>{'ok': true},
      }));
      await stdout.flush();
    }
  }
}
''';
