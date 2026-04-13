import 'dart:io';

import 'package:flutterhelm/adapters/registry.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/server/capabilities.dart';
import 'package:flutterhelm/server/registry.dart';
import 'package:flutterhelm/server/support_levels.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AdapterRegistry', () {
    test('surfaces support metadata in current resources and compatibility checks', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-adapter-registry',
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
        - healthy
''');
      final registry = AdapterRegistry(
        config: config,
        processRunner: const ProcessRunner(),
      );
      final currentResource = await registry.currentResource();
      expect(currentResource['releaseChannel'], flutterHelmReleaseChannel);
      final providerStates =
          currentResource['providerStates'] as Map<String, Object?>;
      final customState = providerStates['custom.runtime.driver']
          as Map<String, Object?>;
      expect(customState['state'], 'healthy');
      expect(customState['healthy'], isTrue);
      expect(customState['supportLevel'], SupportLevel.beta.name);
      expect(customState['includedInStableLane'], isFalse);
    });

    test('surfaces nativeBuild builtin visibility and capabilities', () async {
      final config = FlutterHelmConfig.defaults();
      final registry = AdapterRegistry(
        config: config,
        processRunner: const ProcessRunner(),
      );

      final nativeBuild = await registry.familyStatus('nativeBuild');
      expect(nativeBuild.activeProviderId, 'builtin.native_build.external_process');
      expect(nativeBuild.supportLevel, SupportLevel.beta.name);
      expect(nativeBuild.familySupportLevel, SupportLevel.beta.name);
      expect(nativeBuild.healthy, isFalse);
      expect(nativeBuild.reason, contains('disabled'));

      final currentResource = await registry.currentResource();
      final providerStates =
          currentResource['providerStates'] as Map<String, Object?>;
      final builtinState = providerStates['builtin.native_build.external_process']
          as Map<String, Object?>;
      expect(builtinState['state'], 'degraded');
      expect(builtinState['healthy'], isFalse);
      expect(builtinState['supportLevel'], SupportLevel.beta.name);
      expect(builtinState['includedInStableLane'], isFalse);

      final capabilities = buildServerCapabilities(
        toolRegistry: ToolRegistry(),
        config: config,
        transportMode: 'stdio',
      );
      final experimental =
          capabilities['experimental'] as Map<String, Object?>;
      final nativeBuildCapabilities =
          experimental['nativeBuild'] as Map<String, Object?>;
      expect(nativeBuildCapabilities['mode'], 'build_launch_attach');
      expect(nativeBuildCapabilities['supportLevel'], SupportLevel.beta.name);
      expect(nativeBuildCapabilities['defaultEnabled'], isFalse);
      expect(nativeBuildCapabilities['supportedPlatforms'], contains('ios'));
      expect(nativeBuildCapabilities['providerKinds'], contains('builtin'));
      expect(nativeBuildCapabilities['providerKinds'], contains('stdio_json'));
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

    test('parses nativeBuild provider families and invokes them', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-native-build-provider',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final providerScript = await _writeProviderScript(tempDir);
      final config = FlutterHelmConfig.fromYamlText('''
version: 1
adapters:
  active:
    nativeBuild: custom.native.build
  providers:
    custom.native.build:
      kind: stdio_json
      families:
        - nativeBuild
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

      final health = await registry.familyHealth('nativeBuild');
      expect(health['state'], 'healthy');
      expect(health['healthy'], isTrue);
      expect(health['supportLevel'], SupportLevel.beta.name);
      expect(health['activeProviderId'], 'custom.native.build');

      final invoke = await registry.invokeFamily(
        family: 'nativeBuild',
        operation: 'native_project_inspect',
        input: <String, Object?>{'workspaceRoot': tempDir.path},
      );
      final invokeResult = invoke as Map<String, Object?>;
      expect(invokeResult['family'], 'nativeBuild');
      expect(invokeResult['operation'], 'native_project_inspect');
      expect(
        (invokeResult['input'] as Map<String, Object?>)['workspaceRoot'],
        tempDir.path,
      );

      final currentResource = await registry.currentResource();
      final providerStates =
          currentResource['providerStates'] as Map<String, Object?>;
      final customState = providerStates['custom.native.build']
          as Map<String, Object?>;
      expect(customState['state'], 'healthy');
      expect(customState['healthy'], isTrue);
      expect(customState['supportLevel'], SupportLevel.beta.name);
      expect(customState['includedInStableLane'], isFalse);
    });
  });
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

Map<String, Object?> familyPayload(String family, String mode) {
  if (family == 'nativeBuild') {
    return <String, Object?>{
      'healthy': mode != 'degraded',
      'operations': <String>[
        'native_project_inspect',
        'native_build_launch',
        'native_attach_flutter_runtime',
        'native_stop',
      ],
      'supportedPlatforms': <String>['ios'],
      'supportedLocatorFields': <String>[],
      'screenshotFormats': <String>[],
      'reason': mode == 'degraded' ? 'temporarily degraded' : null,
      'reasons': mode == 'degraded'
          ? <String>['temporarily degraded']
          : <String>[],
      'state': mode == 'degraded' ? 'degraded' : 'healthy',
    };
  }
  return <String, Object?>{
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
  };
}

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
            'runtimeDriver': familyPayload('runtimeDriver', mode),
            'nativeBuild': familyPayload('nativeBuild', mode),
          },
        },
      }));
      await stdout.flush();
      continue;
    }
    if (method == 'provider/invoke') {
      final params = message['params'] as Map<String, Object?>? ?? const <String, Object?>{};
      stdout.writeln(jsonEncode(<String, Object?>{
        'id': id,
        'result': <String, Object?>{
          'family': params['family'],
          'operation': params['operation'],
          'input': params['input'],
          'ok': true,
        },
      }));
      await stdout.flush();
    }
  }
}
''';
