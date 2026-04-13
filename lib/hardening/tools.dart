import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/adapters/registry.dart';
import 'package:flutterhelm/artifacts/pins.dart';
import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/observability/store.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/server/support_levels.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;

class HardeningToolService {
  HardeningToolService({
    required this.artifactStore,
    required this.pinStore,
    required this.processRunner,
    required this.configRepository,
    required this.observability,
  });

  final ArtifactStore artifactStore;
  final ArtifactPinStore pinStore;
  final ProcessRunner processRunner;
  final ConfigRepository configRepository;
  final ObservabilityStore observability;

  Future<Map<String, Object?>> artifactPin({
    required String uri,
    String? label,
  }) async {
    final kind = artifactStore.storedResourceKind(uri);
    if (kind == null) {
      throw FlutterHelmToolError(
        code: 'ARTIFACT_PIN_UNSUPPORTED',
        category: 'workspace',
        message: 'Only file-backed artifact resources can be pinned: $uri',
        retryable: false,
      );
    }
    final exists = await artifactStore.storedResourceExists(uri);
    if (!exists) {
      throw FlutterHelmToolError(
        code: 'ARTIFACT_PIN_NOT_FOUND',
        category: 'workspace',
        message: 'Cannot pin a missing artifact resource: $uri',
        retryable: false,
      );
    }
    final record = await pinStore.pin(uri: uri, kind: kind, label: label);
    return _pinEntry(record, presentOverride: true);
  }

  Future<Map<String, Object?>> artifactUnpin({
    required String uri,
  }) async {
    final removed = await pinStore.unpin(uri);
    if (removed == null) {
      throw FlutterHelmToolError(
        code: 'ARTIFACT_PIN_NOT_FOUND',
        category: 'workspace',
        message: 'No pinned artifact exists for: $uri',
        retryable: false,
      );
    }
    return <String, Object?>{
      'status': 'unpinned',
      'uri': uri,
      'kind': removed.kind,
    };
  }

  Future<Map<String, Object?>> artifactPinList({
    String? sessionId,
    String? kind,
  }) async {
    final entries = <Map<String, Object?>>[];
    for (final record in pinStore.listPins()) {
      if (sessionId != null && _sessionIdFromUri(record.uri) != sessionId) {
        continue;
      }
      if (kind != null && record.kind != kind) {
        continue;
      }
      entries.add(await _pinEntry(record));
    }
    return <String, Object?>{
      'pins': entries,
      'count': entries.length,
      if (sessionId != null) 'sessionId': sessionId,
      if (kind != null) 'kind': kind,
    };
  }

  Future<Map<String, Object?>> pinsIndex() async {
    final pins = <Map<String, Object?>>[];
    for (final record in pinStore.listPins()) {
      pins.add(await _pinEntry(record));
    }
    return <String, Object?>{
      'pins': pins,
      'count': pins.length,
    };
  }

  Future<Map<String, Object?>> artifactStatus({
    FlutterHelmConfig? config,
  }) async {
    final resolvedConfig = config ?? await configRepository.load();
    return artifactStore.artifactStatus(
      retention: resolvedConfig.retention,
      pinnedUris: pinStore.pinnedUris,
    );
  }

  Future<Map<String, Object?>> observabilitySnapshot() async {
    return observability.snapshot();
  }

  Future<Map<String, Object?>> compatibilityCheck({
    FlutterHelmConfig? config,
    String? profile,
    String? activeRoot,
    String transportMode = 'stdio',
  }) async {
    final resolvedConfig =
        config ?? await configRepository.load(selectedProfile: profile);
    final adapterRegistry = AdapterRegistry(
      config: resolvedConfig,
      processRunner: processRunner,
    );
    final runtimeDriverProvider = resolvedConfig.adapters.providerForFamily(
      'runtimeDriver',
    );
    final flutterProbe = await _probeFlutter(resolvedConfig.adapters.flutterExecutable);
    final runtimeDriverCommand =
        runtimeDriverProvider?.command ??
        resolvedConfig.adapters.runtimeDriverCommand;
    final runtimeDriverProbe = runtimeDriverCommand.isEmpty
        ? const _CommandProbeResult.unavailable(
            reason: 'No runtime driver command is configured.',
          )
        : await _probeCommand(runtimeDriverCommand);
    final xcodeProbe = Platform.isMacOS
        ? await _probeCommand('xcodebuild', args: const <String>['-version'])
        : const _CommandProbeResult.unavailable(
            reason: 'Xcode is only available on macOS.',
          );
    final simctlProbe = Platform.isMacOS
        ? await _probeCommand(
            'xcrun',
            args: const <String>['simctl', 'list', 'devices', 'available'],
            timeout: const Duration(seconds: 10),
          )
        : const _CommandProbeResult.unavailable(
            reason: 'simctl is only available on macOS.',
          );

    final hasIosProject = activeRoot == null ? false : await _hasIosProject(activeRoot);
    final hasAndroidProject = activeRoot == null
        ? false
        : await Directory(p.join(activeRoot, 'android')).exists();

    final checks = <String, Object?>{
      'flutterCli': _probeStatus(
        supported: flutterProbe.available,
        status: flutterProbe.available ? 'ok' : 'unavailable',
        reason: flutterProbe.reason,
        requirements: <String>[
          '${resolvedConfig.adapters.flutterExecutable} must be available on PATH.',
        ],
        extra: <String, Object?>{
          'executable': resolvedConfig.adapters.flutterExecutable,
          if (flutterProbe.version != null) 'version': flutterProbe.version,
        },
      ),
      'runtimeDriver': _probeStatus(
        supported:
            runtimeDriverProvider != null &&
            ((runtimeDriverProvider.kind == 'stdio_json' &&
                    runtimeDriverProbe.available) ||
                (resolvedConfig.adapters.runtimeDriverEnabled &&
                    runtimeDriverProbe.available)),
        status: runtimeDriverProvider == null
            ? 'unavailable'
            : ((runtimeDriverProvider.kind == 'stdio_json' ||
                      resolvedConfig.adapters.runtimeDriverEnabled)
                  ? (runtimeDriverProbe.available ? 'ok' : 'unavailable')
                  : 'degraded'),
        reason: runtimeDriverProvider == null
            ? 'No runtimeDriver provider is configured.'
            : (runtimeDriverProvider.kind == 'stdio_json'
                  ? runtimeDriverProbe.reason
                  : (!resolvedConfig.adapters.runtimeDriverEnabled
                        ? 'Runtime driver is disabled in the current config.'
                        : runtimeDriverProbe.reason)),
        requirements: <String>[
          if (runtimeDriverProvider?.kind != 'stdio_json')
            'runtimeDriver.enabled must be true.',
          '$runtimeDriverCommand must be available on PATH.',
        ],
        supportLevel: SupportLevel.beta,
        includedInStableLane: false,
        extra: <String, Object?>{
          'providerId': runtimeDriverProvider?.id,
          'kind': runtimeDriverProvider?.kind,
          'command': runtimeDriverCommand,
          'args':
              runtimeDriverProvider?.args ?? resolvedConfig.adapters.runtimeDriverArgs,
        },
      ),
      'iosTooling': _probeStatus(
        supported: Platform.isMacOS && xcodeProbe.available && simctlProbe.available,
        status: !Platform.isMacOS
            ? 'unavailable'
            : (xcodeProbe.available && simctlProbe.available ? 'ok' : 'degraded'),
        reason: !Platform.isMacOS
            ? 'iOS simulator tooling requires macOS.'
            : _combineReasons(<String?>[xcodeProbe.reason, simctlProbe.reason]),
        requirements: const <String>[
          'xcodebuild must be available.',
          'xcrun simctl must be available.',
        ],
      ),
      'platformProjects': _probeStatus(
        supported: hasIosProject || hasAndroidProject,
        status: activeRoot == null
            ? 'degraded'
            : (hasIosProject || hasAndroidProject ? 'ok' : 'degraded'),
        reason: activeRoot == null
            ? 'No active workspace root is configured.'
            : (!(hasIosProject || hasAndroidProject)
                  ? 'Active workspace root does not contain ios/ or android/ project files.'
                  : null),
        requirements: const <String>[
          'Set an active workspace root before checking platform-specific support.',
        ],
        extra: <String, Object?>{
          'hasIosProject': hasIosProject,
          'hasAndroidProject': hasAndroidProject,
        },
      ),
    };

    final workflows = <String, Object?>{
      'workspace': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('workspace'),
        supported: true,
        reason: null,
      ),
      'session': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('session'),
        supported: true,
        reason: null,
      ),
      'launcher': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('launcher'),
        supported: flutterProbe.available,
        reason: flutterProbe.reason,
      ),
      'runtime_readonly': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('runtime_readonly'),
        supported: flutterProbe.available,
        reason: flutterProbe.reason,
      ),
      'tests': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('tests'),
        supported: flutterProbe.available,
        reason: flutterProbe.reason,
      ),
      'profiling': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('profiling'),
        supported: flutterProbe.available,
        reason: flutterProbe.available
            ? 'Requires debug or profile sessions with VM service.'
            : flutterProbe.reason,
      ),
      'platform_bridge': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('platform_bridge'),
        supported:
            (Platform.isMacOS && hasIosProject && simctlProbe.available) ||
            hasAndroidProject,
        reason: activeRoot == null
            ? 'Set an active workspace root to evaluate native project availability.'
            : null,
      ),
      'runtime_interaction': _workflowStatus(
        configured: resolvedConfig.enabledWorkflows.contains('runtime_interaction'),
        supported:
            runtimeDriverProvider != null &&
            ((runtimeDriverProvider.kind == 'stdio_json' &&
                    runtimeDriverProbe.available) ||
                (resolvedConfig.adapters.runtimeDriverEnabled &&
                    runtimeDriverProbe.available)),
        reason: runtimeDriverProvider == null
            ? 'runtimeDriver provider is missing.'
            : (runtimeDriverProvider.kind == 'stdio_json'
                  ? runtimeDriverProbe.reason
                  : (!resolvedConfig.adapters.runtimeDriverEnabled
                        ? 'runtimeDriver is disabled.'
                        : runtimeDriverProbe.reason)),
        supportLevel: SupportLevel.beta,
        includedInStableLane: false,
      ),
    };

    final adapters = await adapterRegistry.currentResource();

    return <String, Object?>{
      'releaseChannel': flutterHelmReleaseChannel,
      'stableHarnessTags': flutterHelmStableHarnessTags,
      'profile': resolvedConfig.activeProfile,
      'availableProfiles': resolvedConfig.availableProfiles,
      'deprecations': resolvedConfig.adapters.deprecations,
      'workspaceRoot': activeRoot,
      'environment': <String, Object?>{
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'dartVersion': _dartVersion(),
      },
      'transport': <String, Object?>{
        'mode': transportMode,
        'supportLevels': <String, Object?>{
          'stdio': supportLevelMetadata(
            supportLevel: SupportLevel.stable,
            includedInStableLane: true,
          ),
          'http': supportLevelMetadata(
            supportLevel: SupportLevel.preview,
            includedInStableLane: false,
          ),
        },
        'httpPreview': _probeStatus(
          supported: transportMode == 'http',
          status: transportMode == 'http' ? 'degraded' : 'ok',
          reason: transportMode == 'http'
              ? 'HTTP preview is localhost-only, request-response only, and roots transport is unsupported.'
              : 'stdio remains the primary fully roots-aware transport.',
          requirements: const <String>[
            'HTTP preview is intended for localhost development only.',
            'Roots-aware client roots are not available over HTTP preview in Sprint 9.',
          ],
          supportLevel: SupportLevel.preview,
          includedInStableLane: false,
        ),
      },
      'adapters': adapters,
      'checks': checks,
      'workflows': workflows,
      'resources': <String, Object?>{
        'compatibility': 'config://compatibility/current',
        'artifactsStatus': 'config://artifacts/status',
        'observability': 'config://observability/current',
      },
    };
  }

  Future<Map<String, Object?>> _pinEntry(
    ArtifactPinRecord record, {
    bool? presentOverride,
  }) async {
    final present = presentOverride ?? await artifactStore.storedResourceExists(record.uri);
    return <String, Object?>{
      'uri': record.uri,
      'kind': record.kind,
      'status': present ? 'present' : 'missing',
      'present': present,
      'pinnedAt': record.pinnedAt.toUtc().toIso8601String(),
      'updatedAt': record.updatedAt.toUtc().toIso8601String(),
      if (record.label != null) 'label': record.label,
      if (_sessionIdFromUri(record.uri) != null)
        'sessionId': _sessionIdFromUri(record.uri),
    };
  }

  Future<_CommandProbeResult> _probeFlutter(String executable) async {
    try {
      final result = await processRunner.run(
        executable,
        const <String>['--version', '--machine'],
        timeout: const Duration(seconds: 15),
      );
      if (result.exitCode != 0) {
        return _CommandProbeResult(
          available: false,
          reason: result.stderr.trim().isEmpty
              ? '$executable exited with code ${result.exitCode}.'
              : result.stderr.trim(),
        );
      }
      final decoded = jsonDecode(result.stdout);
      if (decoded is Map<String, Object?>) {
        final frameworkVersion = decoded['frameworkVersion'] as String?;
        return _CommandProbeResult(
          available: true,
          version: frameworkVersion,
        );
      }
      return const _CommandProbeResult(available: true);
    } on Object catch (error) {
      return _CommandProbeResult(
        available: false,
        reason: error.toString(),
      );
    }
  }

  Future<_CommandProbeResult> _probeCommand(
    String executable, {
    List<String> args = const <String>['--version'],
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final located = await _commandExists(executable);
    if (!located) {
      return _CommandProbeResult(
        available: false,
        reason: '$executable is not available on PATH.',
      );
    }
    try {
      final result = await processRunner.run(
        executable,
        args,
        timeout: timeout,
      );
      return _CommandProbeResult(
        available: result.exitCode == 0,
        reason: result.exitCode == 0
            ? null
            : (result.stderr.trim().isEmpty
                  ? '$executable exited with code ${result.exitCode}.'
                  : result.stderr.trim()),
      );
    } on Object catch (error) {
      return _CommandProbeResult(
        available: false,
        reason: error.toString(),
      );
    }
  }

  Future<bool> _commandExists(String executable) async {
    final locator = Platform.isWindows ? 'where' : 'which';
    try {
      final result = await processRunner.run(
        locator,
        <String>[executable],
        timeout: const Duration(seconds: 5),
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  Future<bool> _hasIosProject(String workspaceRoot) async {
    final workspace = Directory(p.join(workspaceRoot, 'ios', 'Runner.xcworkspace'));
    if (await workspace.exists()) {
      return true;
    }
    final project = Directory(p.join(workspaceRoot, 'ios', 'Runner.xcodeproj'));
    return project.exists();
  }

  Map<String, Object?> _probeStatus({
    required bool supported,
    required String status,
    required String? reason,
    required List<String> requirements,
    SupportLevel supportLevel = SupportLevel.stable,
    bool includedInStableLane = true,
    Map<String, Object?> extra = const <String, Object?>{},
  }) {
    return <String, Object?>{
      'supported': supported,
      'status': status,
      'reason': reason,
      'requirements': requirements,
      ...supportLevelMetadata(
        supportLevel: supportLevel,
        includedInStableLane: includedInStableLane,
      ),
      ...extra,
    };
  }

  Map<String, Object?> _workflowStatus({
    required bool configured,
    required bool supported,
    required String? reason,
    SupportLevel supportLevel = SupportLevel.stable,
    bool includedInStableLane = true,
  }) {
    return <String, Object?>{
      'configured': configured,
      'supported': supported,
      'status': !configured ? 'unavailable' : (supported ? 'ok' : 'degraded'),
      'reason': reason,
      ...supportLevelMetadata(
        supportLevel: supportLevel,
        includedInStableLane: includedInStableLane,
      ),
    };
  }

  String _dartVersion() {
    final version = Platform.version;
    final firstSpace = version.indexOf(' ');
    if (firstSpace == -1) {
      return version;
    }
    return version.substring(0, firstSpace);
  }

  String? _combineReasons(List<String?> reasons) {
    final values = reasons.whereType<String>().where((String item) => item.isNotEmpty).toList();
    if (values.isEmpty) {
      return null;
    }
    return values.join(' ');
  }

  String? _sessionIdFromUri(String uri) {
    for (final pattern in <RegExp>[
      RegExp(r'^(?:log|runtime-errors|widget-tree|app-state|cpu|timeline|memory|native-handoff|screenshot)://([^/]+)/'),
      RegExp(r'^session://([^/]+)/'),
    ]) {
      final match = pattern.firstMatch(uri);
      if (match != null) {
        return match.group(1);
      }
    }
    return null;
  }
}

class _CommandProbeResult {
  const _CommandProbeResult({
    required this.available,
    this.version,
    this.reason,
  });

  const _CommandProbeResult.unavailable({
    required String reason,
  }) : this(
         available: false,
         reason: reason,
       );

  final bool available;
  final String? version;
  final String? reason;
}
