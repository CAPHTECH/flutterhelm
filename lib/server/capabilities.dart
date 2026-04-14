import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/server/registry.dart';
import 'package:flutterhelm/server/support_levels.dart';

Map<String, Object?> buildServerCapabilities({
  required ToolRegistry toolRegistry,
  required FlutterHelmConfig config,
  required String transportMode,
}) {
  return <String, Object?>{
    'logging': <String, Object?>{},
    'resources': <String, Object?>{'subscribe': false, 'listChanged': false},
    'tools': <String, Object?>{'listChanged': false},
    'experimental': <String, Object?>{
      'stableLane': flutterHelmStableHarnessTags,
      'workflowStatus': toolRegistry.workflowStatus(config),
      'profiling': const <String, Object?>{
        'backend': 'vm_service',
        'ownershipPolicy': 'owned_only',
        'dtdRequired': false,
        'supportLevel': 'stable',
        'includedInStableLane': true,
      },
      'nativeBuild': const <String, Object?>{
        'mode': 'build_launch_attach',
        'defaultEnabled': false,
        'supportedPlatforms': <String>['ios'],
        'providerKinds': <String>['builtin', 'stdio_json'],
        'supportLevel': 'beta',
        'includedInStableLane': false,
      },
      'platformBridge': const <String, Object?>{
        'mode': 'handoff_only',
        'ideAutomation': false,
        'supportedPlatforms': <String>['ios', 'android'],
        'defaultEnabled': true,
        'supportLevel': 'stable',
        'includedInStableLane': true,
      },
      'runtimeInteraction': const <String, Object?>{
        'defaultEnabled': false,
        'uiBackend': 'external_adapter',
        'hotOpBackend': 'flutter_daemon',
        'screenshotWorkflow': 'runtime_readonly',
        'hotOpsOwnershipPolicy': 'owned_only',
        'supportLevel': 'beta',
        'includedInStableLane': false,
      },
      'hardening': const <String, Object?>{
        'busyPolicy': 'fail_fast',
        'pinnedArtifacts': true,
        'configProfiles': true,
        'compatibilityResource': 'config://compatibility/current',
        'artifactsStatusResource': 'config://artifacts/status',
        'observabilityResource': 'config://observability/current',
        'supportLevel': 'stable',
        'includedInStableLane': true,
      },
      'httpPreview': <String, Object?>{
        'mode': 'preview',
        'localhostOnly': true,
        'rootsSupport': 'unsupported',
        'sse': false,
        'resumability': false,
        'sessionExpiryMinutes': 30,
        'activeTransport': transportMode,
        'supportLevel': 'preview',
        'includedInStableLane': false,
      },
      'adapterRegistry': const <String, Object?>{
        'families': <String>[
          'delegate',
          'flutterCli',
          'profiling',
          'runtimeDriver',
          'nativeBuild',
          'platformBridge',
        ],
        'customProviderKinds': <String>['stdio_json'],
        'legacyConfigShim': false,
        'supportLevel': 'stable',
        'includedInStableLane': true,
        'customProviderSupportLevel': 'beta',
      },
      'transportSupport': <String, Object?>{
        'stdio': <String, Object?>{
          'supportLevel': SupportLevel.stable.name,
          'includedInStableLane': true,
        },
        'http': <String, Object?>{
          'supportLevel': SupportLevel.preview.name,
          'includedInStableLane': false,
        },
      },
    },
  };
}
