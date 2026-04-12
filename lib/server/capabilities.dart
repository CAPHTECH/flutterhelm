import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/server/registry.dart';
import 'package:flutterhelm/version.dart';

Map<String, Object?> buildServerCapabilities({
  required ToolRegistry toolRegistry,
  required FlutterHelmConfig config,
}) {
  return <String, Object?>{
    'logging': <String, Object?>{},
    'resources': <String, Object?>{'subscribe': false, 'listChanged': false},
    'tools': <String, Object?>{'listChanged': false},
    'experimental': <String, Object?>{
      'contractVersion': flutterHelmContractVersion,
      'workflowStatus': toolRegistry.workflowStatus(config),
      'profiling': const <String, Object?>{
        'backend': 'vm_service',
        'ownershipPolicy': 'owned_only',
        'dtdRequired': false,
      },
      'platformBridge': const <String, Object?>{
        'mode': 'handoff_only',
        'ideAutomation': false,
        'supportedPlatforms': <String>['ios', 'android'],
        'defaultEnabled': true,
      },
      'runtimeInteraction': const <String, Object?>{
        'defaultEnabled': false,
        'uiBackend': 'external_adapter',
        'hotOpBackend': 'flutter_daemon',
        'screenshotWorkflow': 'runtime_readonly',
        'hotOpsOwnershipPolicy': 'owned_only',
      },
    },
  };
}
