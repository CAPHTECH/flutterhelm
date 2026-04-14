import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/observability/store.dart';
import 'package:flutterhelm/server/support_levels.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;

const Duration stdioJsonProviderInvokeTimeout = Duration(seconds: 30);
const List<Duration> stdioJsonProviderBackoffSchedule = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 5),
  Duration(seconds: 30),
];

class RuntimeDriverHealth {
  const RuntimeDriverHealth({
    required this.connected,
    required this.driverName,
    required this.driverVersion,
    required this.supportedPlatforms,
    required this.supportedActions,
    required this.supportedLocatorFields,
    required this.screenshotFormats,
    this.error,
  });

  final bool connected;
  final String? driverName;
  final String? driverVersion;
  final List<String> supportedPlatforms;
  final List<String> supportedActions;
  final List<String> supportedLocatorFields;
  final List<String> screenshotFormats;
  final String? error;
}

class DelegateHealth {
  const DelegateHealth({
    required this.connected,
    required this.serverName,
    required this.serverVersion,
    required this.supportedOperations,
    this.command,
    this.args = const <String>[],
    this.error,
  });

  final bool connected;
  final String? serverName;
  final String? serverVersion;
  final List<String> supportedOperations;
  final String? command;
  final List<String> args;
  final String? error;
}

abstract class DelegateAdapter {
  Future<DelegateHealth> health();

  Future<Map<String, Object?>> analyzeProject({
    required String workspaceRoot,
    required bool fatalInfos,
    required bool fatalWarnings,
  });

  Future<Map<String, Object?>> resolveSymbol({
    required String workspaceRoot,
    required String symbol,
  });

  Future<Map<String, Object?>> pubSearch({
    required String query,
    required int limit,
  });

  Future<Map<String, Object?>> dependencyAdd({
    required String workspaceRoot,
    required String package,
    required String? versionConstraint,
    required bool devDependency,
  });

  Future<Map<String, Object?>> dependencyRemove({
    required String workspaceRoot,
    required String package,
  });

  Future<Map<String, Object?>> getRuntimeErrors({
    required String dtdUri,
  });

  Future<Map<String, Object?>> getWidgetTree({
    required String dtdUri,
    required int depth,
    required bool includeProperties,
  });

  Future<void> hotReload({required String dtdUri});

  Future<void> hotRestart({required String dtdUri});
}

abstract class RuntimeDriverAdapter {
  Future<RuntimeDriverHealth> health();

  Future<List<Map<String, Object?>>> listElements({
    required String deviceId,
  });

  Future<void> tap({
    required String deviceId,
    required double x,
    required double y,
  });

  Future<void> enterText({
    required String deviceId,
    required String text,
    required bool submit,
  });

  Future<void> scroll({
    required String deviceId,
    required String direction,
    int? distance,
  });

  Future<void> captureScreenshot({
    required String deviceId,
    required String saveTo,
    required String format,
  });
}

enum _ProviderLifecycleState { starting, healthy, degraded, backoff }

class _ProviderLifecycleSnapshot {
  const _ProviderLifecycleSnapshot({
    required this.state,
    required this.healthy,
    required this.reasons,
    required this.failureCount,
    this.backoffUntil,
    this.providerInfo,
  });

  final _ProviderLifecycleState state;
  final bool healthy;
  final List<String> reasons;
  final int failureCount;
  final DateTime? backoffUntil;
  final Map<String, Object?>? providerInfo;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'state': state.name,
      'healthy': healthy,
      'reasons': reasons,
      'reason': reasons.isEmpty ? null : reasons.first,
      'failureCount': failureCount,
      if (backoffUntil != null) 'backoffUntil': backoffUntil!.toUtc().toIso8601String(),
      if (providerInfo != null) 'providerInfo': providerInfo,
    };
  }
}

class AdapterFamilyStatus {
  const AdapterFamilyStatus({
    required this.family,
    required this.activeProviderId,
    required this.kind,
    required this.builtin,
    required this.healthy,
    required this.operations,
    required this.supportLevel,
    required this.familySupportLevel,
    required this.activeProviderSupportLevel,
    required this.includedInStableLane,
    required this.state,
    required this.reasons,
    required this.failureCount,
    this.reason,
    this.backoffUntil,
    this.providerInfo,
  });

  final String family;
  final String? activeProviderId;
  final String? kind;
  final bool builtin;
  final bool healthy;
  final List<String> operations;
  final String supportLevel;
  final String familySupportLevel;
  final String activeProviderSupportLevel;
  final bool includedInStableLane;
  final String state;
  final List<String> reasons;
  final int failureCount;
  final String? reason;
  final DateTime? backoffUntil;
  final Map<String, Object?>? providerInfo;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'family': family,
      'activeProviderId': activeProviderId,
      'kind': kind,
      'builtin': builtin,
      'healthy': healthy,
      'operations': operations,
      'supportLevel': supportLevel,
      'familySupportLevel': familySupportLevel,
      'activeProviderSupportLevel': activeProviderSupportLevel,
      'includedInStableLane': includedInStableLane,
      'state': state,
      'reasons': reasons,
      if (reason != null) 'reason': reason,
      'failureCount': failureCount,
      if (backoffUntil != null) 'backoffUntil': backoffUntil!.toUtc().toIso8601String(),
      if (providerInfo != null) 'providerInfo': providerInfo,
    };
  }
}

class AdapterRegistry {
  AdapterRegistry({
    required this.config,
    required this.processRunner,
    this.observability,
  });

  final FlutterHelmConfig config;
  final ProcessRunner processRunner;
  final ObservabilityStore? observability;
  final Map<String, _StdioJsonProviderClient> _providerClients =
      <String, _StdioJsonProviderClient>{};
  DelegateAdapter? _delegateAdapter;
  RuntimeDriverAdapter? _runtimeDriverAdapter;

  static const List<String> supportedFamilies = <String>[
    'delegate',
    'flutterCli',
    'profiling',
    'runtimeDriver',
    'platformBridge',
    'nativeBuild',
  ];

  Future<DelegateAdapter> delegateAdapter() async {
    final existing = _delegateAdapter;
    if (existing != null) {
      return existing;
    }

    final provider = config.adapters.providerForFamily('delegate');
    if (provider == null) {
      final adapter = _UnavailableDelegateAdapter(
        reason: 'No active delegate provider is configured.',
      );
      _delegateAdapter = adapter;
      return adapter;
    }

    final adapter = switch (provider.kind) {
      'stdio_json' => _StdioJsonDelegateAdapter(client: _providerClient(provider)),
      _ => _BuiltinFlutterMcpDelegateAdapter(
        command: provider.command ?? 'dart',
        args: provider.args.isNotEmpty
            ? provider.args
            : const <String>[
                'mcp-server',
                '--tools',
                'all',
                '--force-roots-fallback',
              ],
        startupTimeout: Duration(
          milliseconds: provider.startupTimeoutMs > 0
              ? provider.startupTimeoutMs
              : 10000,
        ),
        observability: observability,
      ),
    };
    _delegateAdapter = adapter;
    return adapter;
  }

  Future<RuntimeDriverAdapter> runtimeDriverAdapter() async {
    final existing = _runtimeDriverAdapter;
    if (existing != null) {
      return existing;
    }

    final provider = config.adapters.providerForFamily('runtimeDriver');
    if (provider == null) {
      final adapter = _UnavailableRuntimeDriverAdapter(
        reason: 'No active runtimeDriver provider is configured.',
      );
      _runtimeDriverAdapter = adapter;
      return adapter;
    }

    final adapter = switch (provider.kind) {
      'stdio_json' => _StdioJsonRuntimeDriverAdapter(
        client: _providerClient(provider),
      ),
      _ => _BuiltinMcpRuntimeDriverAdapter(
        enabled:
            config.adapters.runtimeDriverEnabled &&
            provider.id == 'builtin.runtime_driver.external_process',
        command:
            provider.command ??
            config.adapters.runtimeDriverCommand,
        args: provider.args.isNotEmpty
            ? provider.args
            : config.adapters.runtimeDriverArgs,
        startupTimeout: Duration(
          milliseconds: provider.startupTimeoutMs > 0
              ? provider.startupTimeoutMs
              : config.adapters.runtimeDriverStartupTimeoutMs,
        ),
      ),
    };
    _runtimeDriverAdapter = adapter;
    return adapter;
  }

  Future<List<Map<String, Object?>>> list({String? family}) async {
    final families = family == null ? supportedFamilies : <String>[family];
    final results = <Map<String, Object?>>[];
    for (final entry in families) {
      results.add((await familyStatus(entry)).toJson());
    }
    return results;
  }

  Future<Map<String, Object?>> familyHealth(String family) async {
    return (await familyStatus(family)).toJson();
  }

  Future<Object?> invokeFamily({
    required String family,
    required String operation,
    required Map<String, Object?> input,
  }) async {
    final provider = config.adapters.providerForFamily(family);
    if (provider == null) {
      throw StateError('No active provider is configured for family $family.');
    }
    if (provider.kind != 'stdio_json') {
      throw StateError(
        'Provider ${provider.id} does not expose invokeFamily().',
      );
    }
    return _providerClient(provider).invoke(
      family: family,
      operation: operation,
      input: input,
    );
  }

  Future<Map<String, Object?>> currentResource() async {
    final families = <Map<String, Object?>>[];
    for (final family in supportedFamilies) {
      families.add((await familyStatus(family)).toJson());
    }
    final providers = <String, Object?>{
      for (final entry in config.adapters.providers.entries)
        entry.key: await _providerStatus(entry.value),
    };
    return <String, Object?>{
      'releaseChannel': flutterHelmReleaseChannel,
      'stableFamilies': supportedFamilies
          .where((String family) => workflowIncludedInStableLane(_familyToWorkflow(family)))
          .toList(),
      'families': families,
      'active': config.adapters.activeProviders,
      'providers': <String, Object?>{
        for (final entry in config.adapters.providers.entries)
          entry.key: <String, Object?>{
            'kind': entry.value.kind,
            'families': entry.value.families,
            'builtin': entry.value.builtin,
            'supportLevel': adapterProviderSupportLevel(entry.value).name,
            'includedInStableLane': adapterProviderIncludedInStableLane(entry.value),
            if (entry.value.command != null) 'command': entry.value.command,
            if (entry.value.args.isNotEmpty) 'args': entry.value.args,
            if (entry.value.startupTimeoutMs > 0)
              'startupTimeoutMs': entry.value.startupTimeoutMs,
          },
      },
      'providerStates': providers,
      'deprecations': config.adapters.deprecations,
    };
  }

  Future<Map<String, Object?>> activeAdaptersSummary() async {
    final summary = <String, Object?>{};
    for (final family in supportedFamilies) {
      summary[family] = (await familyStatus(family)).toJson();
    }
    return summary;
  }

  Future<AdapterFamilyStatus> familyStatus(String family) async {
    if (!supportedFamilies.contains(family)) {
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: null,
        kind: null,
        builtin: false,
        healthy: false,
        operations: const <String>[],
        supportLevel: adapterFamilySupportLevel(family).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: SupportLevel.preview.name,
        includedInStableLane: false,
        state: 'degraded',
        reasons: <String>['Unsupported adapter family: $family'],
        failureCount: 0,
        reason: 'Unsupported adapter family: $family',
      );
    }

    final providerId = config.adapters.activeProviders[family];
    if (providerId == null) {
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: null,
        kind: null,
        builtin: false,
        healthy: false,
        operations: const <String>[],
        supportLevel: adapterFamilySupportLevel(family).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: SupportLevel.preview.name,
        includedInStableLane: false,
        state: 'degraded',
        reasons: const <String>['No active provider configured for the family.'],
        failureCount: 0,
        reason: 'No active provider configured for $family.',
      );
    }

    final provider = config.adapters.providers[providerId];
    if (provider == null) {
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: providerId,
        kind: null,
        builtin: false,
        healthy: false,
        operations: const <String>[],
        supportLevel: adapterFamilySupportLevel(family).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: SupportLevel.preview.name,
        includedInStableLane: false,
        state: 'degraded',
        reasons: <String>['Configured provider $providerId was not found.'],
        failureCount: 0,
        reason: 'Configured provider $providerId was not found.',
      );
    }
    if (family == 'nativeBuild' && provider.kind != 'stdio_json') {
      final enabled = provider.options['enabled'] as bool? ?? false;
      final reason = enabled
          ? null
          : 'Native build provider is disabled in the current config.';
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: providerId,
        kind: provider.kind,
        builtin: provider.builtin,
        healthy: enabled,
        operations: const <String>[],
        supportLevel: adapterProviderSupportLevel(provider).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: adapterProviderSupportLevel(provider).name,
        includedInStableLane: adapterFamilyIncludedInStableLane(
          family,
          provider,
        ),
        state: enabled ? 'healthy' : 'degraded',
        reasons: <String>[if (reason != null) reason],
        failureCount: 0,
        reason: reason,
        providerInfo: <String, Object?>{
          'enabled': enabled,
          'kind': provider.kind,
          'builtin': provider.builtin,
        },
      );
    }
    if (!provider.families.contains(family)) {
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: providerId,
        kind: provider.kind,
        builtin: provider.builtin,
        healthy: false,
        operations: const <String>[],
        supportLevel: adapterProviderSupportLevel(provider).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: adapterProviderSupportLevel(provider).name,
        includedInStableLane: false,
        state: 'degraded',
        reasons: <String>['Provider $providerId does not support family $family.'],
        failureCount: 0,
        reason: 'Provider $providerId does not support family $family.',
      );
    }

    if (provider.kind == 'stdio_json') {
      final health = await _providerClient(provider).health();
      final familyHealth = _coerceMap(_coerceMap(health['families'])[family]);
      final operations = _coerceStringList(familyHealth['operations']);
      final healthy = health['state'] == 'healthy' &&
          (familyHealth['healthy'] as bool? ?? false);
      final reasons = <String>[
        ..._coerceStringList(health['reasons']),
        ..._coerceStringList(familyHealth['reasons']),
      ];
      final reason = familyHealth['reason'] as String? ??
          health['reason'] as String? ??
          (reasons.isNotEmpty
              ? reasons.first
              : (healthy ? null : 'Provider $providerId is not healthy.'));
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: providerId,
        kind: provider.kind,
        builtin: provider.builtin,
        healthy: healthy,
        operations: operations,
        supportLevel: adapterProviderSupportLevel(provider).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: adapterProviderSupportLevel(provider).name,
        includedInStableLane: adapterFamilyIncludedInStableLane(
          family,
          provider,
        ),
        state: _stringValue(health['state']) ?? 'degraded',
        reasons: reasons.isEmpty && reason != null
            ? <String>[reason]
            : reasons,
        failureCount: _intValue(health['failureCount']) ?? 0,
        reason: reason,
        backoffUntil: _dateTimeValue(health['backoffUntil']),
        providerInfo: _coerceMap(health['providerInfo']),
      );
    }

    if (family == 'delegate') {
      final adapter = await delegateAdapter();
      final health = await adapter.health();
      final reason = health.error ??
          (!health.connected ? 'Official delegate is not healthy.' : null);
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: providerId,
        kind: provider.kind,
        builtin: provider.builtin,
        healthy: health.connected,
        operations: health.supportedOperations,
        supportLevel: adapterProviderSupportLevel(provider).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: adapterProviderSupportLevel(provider).name,
        includedInStableLane: adapterFamilyIncludedInStableLane(
          family,
          provider,
        ),
        state: health.connected ? 'healthy' : 'degraded',
        reasons: <String>[
          if (health.error != null) health.error!,
          if (!health.connected && health.error == null)
            'Official delegate is not healthy.',
        ],
        failureCount: 0,
        reason: reason,
        providerInfo: <String, Object?>{
          if (health.serverName != null) 'serverName': health.serverName,
          if (health.serverVersion != null) 'serverVersion': health.serverVersion,
          if (health.command != null) 'command': health.command,
          if (health.args.isNotEmpty) 'args': health.args,
        },
      );
    }

    if (family == 'runtimeDriver') {
      final adapter = await runtimeDriverAdapter();
      final health = await adapter.health();
      return AdapterFamilyStatus(
        family: family,
        activeProviderId: providerId,
        kind: provider.kind,
        builtin: provider.builtin,
        healthy: health.connected,
        operations: health.supportedActions,
        supportLevel: adapterProviderSupportLevel(provider).name,
        familySupportLevel: adapterFamilySupportLevel(family).name,
        activeProviderSupportLevel: adapterProviderSupportLevel(provider).name,
        includedInStableLane: adapterFamilyIncludedInStableLane(
          family,
          provider,
        ),
        state: health.connected ? 'healthy' : 'degraded',
        reasons: <String>[
          if (health.error != null) health.error!,
          if (!health.connected && health.error == null)
            'Runtime driver is not healthy.',
        ],
        failureCount: 0,
        reason: health.error ?? (health.connected ? null : 'Runtime driver is not healthy.'),
        providerInfo: <String, Object?>{
          if (health.driverName != null) 'name': health.driverName,
          if (health.driverVersion != null) 'version': health.driverVersion,
          'supportedPlatforms': health.supportedPlatforms,
          'supportedLocatorFields': health.supportedLocatorFields,
          'screenshotFormats': health.screenshotFormats,
        },
      );
    }

    return AdapterFamilyStatus(
      family: family,
      activeProviderId: providerId,
      kind: provider.kind,
      builtin: provider.builtin,
      healthy: true,
      operations: _builtinOperations[family] ?? const <String>[],
      supportLevel: adapterProviderSupportLevel(provider).name,
      familySupportLevel: adapterFamilySupportLevel(family).name,
      activeProviderSupportLevel: adapterProviderSupportLevel(provider).name,
      includedInStableLane: adapterFamilyIncludedInStableLane(family, provider),
      state: 'healthy',
      reasons: const <String>[],
      failureCount: 0,
    );
  }

  _StdioJsonProviderClient _providerClient(AdapterProviderConfig provider) {
    return _providerClients.putIfAbsent(
      provider.id,
      () => _StdioJsonProviderClient(
        providerId: provider.id,
        command: provider.command ?? '',
        args: provider.args,
        families: provider.families,
        startupTimeout: Duration(
          milliseconds: provider.startupTimeoutMs > 0
              ? provider.startupTimeoutMs
              : 5000,
        ),
        observability: observability,
      ),
    );
  }

  Future<Map<String, Object?>> _providerStatus(AdapterProviderConfig provider) async {
    if (provider.kind == 'stdio_json') {
      final health = await _providerClient(provider).health();
      return <String, Object?>{
        ...health,
        'supportLevel': adapterProviderSupportLevel(provider).name,
        'includedInStableLane': adapterProviderIncludedInStableLane(provider),
      };
    }

    if (provider.id == 'builtin.runtime_driver.external_process' ||
        provider.id == 'builtin.native_build.external_process' ||
        provider.families.contains('nativeBuild')) {
      final enabled = provider.options['enabled'] as bool? ?? false;
      final reason = enabled
          ? null
          : (provider.families.contains('nativeBuild') ||
                  provider.id == 'builtin.native_build.external_process'
              ? 'Native build provider is disabled in the current config.'
              : 'Runtime driver is disabled in the current config.');
      return <String, Object?>{
        'state': enabled ? 'healthy' : 'degraded',
        'healthy': enabled,
        'supportLevel': adapterProviderSupportLevel(provider).name,
        'includedInStableLane': adapterProviderIncludedInStableLane(provider),
        'reasons': <String>[if (reason != null) reason],
        'reason': reason,
        'failureCount': 0,
        'providerInfo': <String, Object?>{
          'enabled': enabled,
          if (provider.command != null) 'command': provider.command,
          if (provider.args.isNotEmpty) 'args': provider.args,
          if (provider.startupTimeoutMs > 0)
            'startupTimeoutMs': provider.startupTimeoutMs,
        },
      };
    }

    if (provider.id == 'builtin.delegate.workspace' ||
        provider.families.contains('delegate')) {
      final adapter = await delegateAdapter();
      final health = await adapter.health();
      final reason = health.error ??
          (!health.connected ? 'Official delegate is not healthy.' : null);
      return <String, Object?>{
        'state': health.connected ? 'healthy' : 'degraded',
        'healthy': health.connected,
        'supportLevel': adapterProviderSupportLevel(provider).name,
        'includedInStableLane': adapterProviderIncludedInStableLane(provider),
        'reasons': <String>[if (reason != null) reason],
        'reason': reason,
        'failureCount': 0,
        'providerInfo': <String, Object?>{
          if (health.serverName != null) 'serverName': health.serverName,
          if (health.serverVersion != null) 'serverVersion': health.serverVersion,
          if (health.command != null) 'command': health.command,
          if (health.args.isNotEmpty) 'args': health.args,
          if (provider.startupTimeoutMs > 0)
            'startupTimeoutMs': provider.startupTimeoutMs,
        },
      };
    }

    return <String, Object?>{
      'state': 'healthy',
      'healthy': true,
      'supportLevel': adapterProviderSupportLevel(provider).name,
      'includedInStableLane': adapterProviderIncludedInStableLane(provider),
      'reasons': const <String>[],
      'failureCount': 0,
      'providerInfo': <String, Object?>{
        'kind': provider.kind,
        'builtin': provider.builtin,
      },
    };
  }

  String _familyToWorkflow(String family) {
    return switch (family) {
      'delegate' => 'workspace',
      'flutterCli' => 'launcher',
      'profiling' => 'profiling',
      'runtimeDriver' => 'runtime_interaction',
      'platformBridge' => 'platform_bridge',
      'nativeBuild' => 'native_build',
      _ => family,
    };
  }
}

const Map<String, List<String>> _builtinOperations = <String, List<String>>{
  'delegate': <String>[
    'analyze_project',
    'resolve_symbol',
    'pub_search',
    'dependency_add',
    'dependency_remove',
    'get_runtime_errors',
    'get_widget_tree',
    'hot_reload',
    'hot_restart',
  ],
  'flutterCli': <String>[
    'device_list',
    'run_app',
    'attach_app',
    'stop_app',
    'format_files',
    'dependency_add',
    'dependency_remove',
    'run_unit_tests',
    'run_widget_tests',
    'run_integration_tests',
    'hot_reload',
    'hot_restart',
  ],
  'profiling': <String>[
    'start_cpu_profile',
    'stop_cpu_profile',
    'capture_timeline',
    'capture_memory_snapshot',
    'toggle_performance_overlay',
  ],
  'runtimeDriver': <String>[
    'capture_screenshot',
    'tap_widget',
    'enter_text',
    'scroll_until_visible',
  ],
  'platformBridge': <String>[
    'ios_debug_context',
    'android_debug_context',
    'native_handoff_summary',
  ],
};

class _UnavailableDelegateAdapter implements DelegateAdapter {
  _UnavailableDelegateAdapter({required this.reason});

  final String reason;

  @override
  Future<DelegateHealth> health() async => DelegateHealth(
    connected: false,
    serverName: null,
    serverVersion: null,
    supportedOperations: const <String>[],
    error: reason,
  );

  @override
  Future<Map<String, Object?>> analyzeProject({
    required String workspaceRoot,
    required bool fatalInfos,
    required bool fatalWarnings,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<Map<String, Object?>> dependencyAdd({
    required String workspaceRoot,
    required String package,
    required String? versionConstraint,
    required bool devDependency,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<Map<String, Object?>> dependencyRemove({
    required String workspaceRoot,
    required String package,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<Map<String, Object?>> getRuntimeErrors({
    required String dtdUri,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<Map<String, Object?>> getWidgetTree({
    required String dtdUri,
    required int depth,
    required bool includeProperties,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<void> hotReload({required String dtdUri}) async {
    throw StateError(reason);
  }

  @override
  Future<void> hotRestart({required String dtdUri}) async {
    throw StateError(reason);
  }

  @override
  Future<Map<String, Object?>> pubSearch({
    required String query,
    required int limit,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<Map<String, Object?>> resolveSymbol({
    required String workspaceRoot,
    required String symbol,
  }) async {
    throw StateError(reason);
  }
}

class _StdioJsonDelegateAdapter implements DelegateAdapter {
  _StdioJsonDelegateAdapter({required this.client});

  final _StdioJsonProviderClient client;

  @override
  Future<DelegateHealth> health() async {
    final payload = await client.health();
    final families = _coerceMap(payload['families']);
    final family = _coerceMap(families['delegate']);
    final providerInfo = _coerceMap(payload['providerInfo']);
    final state = payload['state'] as String?;
    final healthy = (payload['healthy'] as bool? ?? false) &&
        (family['healthy'] as bool? ?? false);
    return DelegateHealth(
      connected: healthy || state == 'healthy',
      serverName: providerInfo['serverName'] as String? ?? providerInfo['name'] as String?,
      serverVersion: providerInfo['serverVersion'] as String? ?? providerInfo['version'] as String?,
      supportedOperations: _coerceStringList(family['operations']),
      command: providerInfo['command'] as String?,
      args: _coerceStringList(providerInfo['args']),
      error: family['reason'] as String? ??
          payload['reason'] as String? ??
          _firstReason(payload['reasons']),
    );
  }

  @override
  Future<Map<String, Object?>> analyzeProject({
    required String workspaceRoot,
    required bool fatalInfos,
    required bool fatalWarnings,
  }) async {
    return _invoke('analyze_project', <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'fatalInfos': fatalInfos,
      'fatalWarnings': fatalWarnings,
    });
  }

  @override
  Future<Map<String, Object?>> resolveSymbol({
    required String workspaceRoot,
    required String symbol,
  }) async {
    return _invoke('resolve_symbol', <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'symbol': symbol,
    });
  }

  @override
  Future<Map<String, Object?>> pubSearch({
    required String query,
    required int limit,
  }) async {
    return _invoke('pub_search', <String, Object?>{
      'query': query,
      'limit': limit,
    });
  }

  @override
  Future<Map<String, Object?>> dependencyAdd({
    required String workspaceRoot,
    required String package,
    required String? versionConstraint,
    required bool devDependency,
  }) async {
    return _invoke('dependency_add', <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'package': package,
      if (versionConstraint != null) 'versionConstraint': versionConstraint,
      'devDependency': devDependency,
    });
  }

  @override
  Future<Map<String, Object?>> dependencyRemove({
    required String workspaceRoot,
    required String package,
  }) async {
    return _invoke('dependency_remove', <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'package': package,
    });
  }

  @override
  Future<Map<String, Object?>> getRuntimeErrors({
    required String dtdUri,
  }) async {
    return _invoke('get_runtime_errors', <String, Object?>{'dtdUri': dtdUri});
  }

  @override
  Future<Map<String, Object?>> getWidgetTree({
    required String dtdUri,
    required int depth,
    required bool includeProperties,
  }) async {
    return _invoke('get_widget_tree', <String, Object?>{
      'dtdUri': dtdUri,
      'depth': depth,
      'includeProperties': includeProperties,
    });
  }

  @override
  Future<void> hotReload({required String dtdUri}) async {
    await _invoke('hot_reload', <String, Object?>{'dtdUri': dtdUri});
  }

  @override
  Future<void> hotRestart({required String dtdUri}) async {
    await _invoke('hot_restart', <String, Object?>{'dtdUri': dtdUri});
  }

  Future<Map<String, Object?>> _invoke(
    String operation,
    Map<String, Object?> input,
  ) async {
    final payload = await client.invoke(
      family: 'delegate',
      operation: operation,
      input: input,
    );
    return _coerceMap(payload);
  }
}

class _BuiltinFlutterMcpDelegateAdapter implements DelegateAdapter {
  _BuiltinFlutterMcpDelegateAdapter({
    required this.command,
    required this.args,
    required this.startupTimeout,
    this.observability,
  });

  final String command;
  final List<String> args;
  final Duration startupTimeout;
  final ObservabilityStore? observability;
  _McpConnection? _connection;
  final Set<String> _registeredRoots = <String>{};
  String? _lastError;

  static const Duration _addRootsTimeout = Duration(seconds: 5);
  static const Duration _resolveSymbolTimeout = Duration(seconds: 20);
  static const Duration _pubSearchTimeout = Duration(seconds: 20);
  static const Duration _runtimeDelegateTimeout = Duration(seconds: 10);
  static const Duration _analyzeProjectTimeout = Duration(seconds: 60);
  static const Duration _dependencyMutationTimeout = Duration(seconds: 30);

  @override
  Future<DelegateHealth> health() async {
    try {
      final connection = await _ensureConnection();
      final supportedOperations = _builtinOperations['delegate'] ?? const <String>[];
      return DelegateHealth(
        connected: true,
        serverName: connection.serverName,
        serverVersion: connection.serverVersion,
        supportedOperations: supportedOperations,
        command: command,
        args: args,
      );
    } on Object catch (error) {
      _lastError = error.toString();
      return DelegateHealth(
        connected: false,
        serverName: null,
        serverVersion: null,
        supportedOperations: const <String>[],
        command: command,
        args: args,
        error: _lastError,
      );
    }
  }

  @override
  Future<Map<String, Object?>> analyzeProject({
    required String workspaceRoot,
    required bool fatalInfos,
    required bool fatalWarnings,
  }) async {
    final startedAt = DateTime.now().toUtc();
    await _ensureRootRegistered(workspaceRoot);
    final result = await _callTool(
      toolName: 'analyze_files',
      arguments: <String, Object?>{
        'roots': <Map<String, Object?>>[
          <String, Object?>{'root': _workspaceRootUri(workspaceRoot)},
        ],
      },
      timeout: _analyzeProjectTimeout,
      operation: 'analyze_project',
    );
    return _normalizeAnalyzeProjectResult(
      workspaceRoot: workspaceRoot,
      result: result,
      duration: DateTime.now().toUtc().difference(startedAt),
    );
  }

  @override
  Future<Map<String, Object?>> resolveSymbol({
    required String workspaceRoot,
    required String symbol,
  }) async {
    await _ensureRootRegistered(workspaceRoot);
    final result = await _callTool(
      toolName: 'resolve_workspace_symbol',
      arguments: <String, Object?>{'query': symbol},
      timeout: _resolveSymbolTimeout,
      operation: 'resolve_symbol',
    );
    return _normalizeResolveSymbolResult(
      result: result,
      workspaceRoot: workspaceRoot,
      symbol: symbol,
    );
  }

  @override
  Future<Map<String, Object?>> pubSearch({
    required String query,
    required int limit,
  }) async {
    final result = await _callTool(
      toolName: 'pub_dev_search',
      arguments: <String, Object?>{'query': query},
      timeout: _pubSearchTimeout,
      operation: 'pub_search',
    );
    return _normalizePubSearchResult(result: result, query: query, limit: limit);
  }

  @override
  Future<Map<String, Object?>> dependencyAdd({
    required String workspaceRoot,
    required String package,
    required String? versionConstraint,
    required bool devDependency,
  }) async {
    await _ensureRootRegistered(workspaceRoot);
    final descriptorPrefix = devDependency ? 'dev:' : '';
    final descriptor = versionConstraint == null || versionConstraint.isEmpty
        ? '$descriptorPrefix$package'
        : '$descriptorPrefix$package:$versionConstraint';
    final result = await _callTool(
      toolName: 'pub',
      arguments: <String, Object?>{
        'command': 'add',
        'packageNames': <String>[descriptor],
        'roots': <Map<String, Object?>>[
          <String, Object?>{'root': _workspaceRootUri(workspaceRoot)},
        ],
      },
      timeout: _dependencyMutationTimeout,
      operation: 'dependency_add',
    );
    return <String, Object?>{
      'stdout': _stringifyToolResult(result),
      'stderr': '',
      'exitCode': 0,
    };
  }

  @override
  Future<Map<String, Object?>> dependencyRemove({
    required String workspaceRoot,
    required String package,
  }) async {
    await _ensureRootRegistered(workspaceRoot);
    final result = await _callTool(
      toolName: 'pub',
      arguments: <String, Object?>{
        'command': 'remove',
        'packageNames': <String>[package],
        'roots': <Map<String, Object?>>[
          <String, Object?>{'root': _workspaceRootUri(workspaceRoot)},
        ],
      },
      timeout: _dependencyMutationTimeout,
      operation: 'dependency_remove',
    );
    return <String, Object?>{
      'stdout': _stringifyToolResult(result),
      'stderr': '',
      'exitCode': 0,
    };
  }

  @override
  Future<Map<String, Object?>> getRuntimeErrors({
    required String dtdUri,
  }) async {
    await _connectDtd(dtdUri);
    final result = await _callTool(
      toolName: 'get_runtime_errors',
      arguments: const <String, Object?>{},
      timeout: _runtimeDelegateTimeout,
      operation: 'get_runtime_errors',
    );
    return <String, Object?>{
      'errors': _normalizeRuntimeErrors(result),
    };
  }

  @override
  Future<Map<String, Object?>> getWidgetTree({
    required String dtdUri,
    required int depth,
    required bool includeProperties,
  }) async {
    await _connectDtd(dtdUri);
    final result = await _callTool(
      toolName: 'get_widget_tree',
      arguments: <String, Object?>{
        'summaryOnly': !includeProperties,
      },
      timeout: _runtimeDelegateTimeout,
      operation: 'get_widget_tree',
    );
    return <String, Object?>{
      'tree': _normalizeWidgetTree(result, depth: depth),
    };
  }

  @override
  Future<void> hotReload({required String dtdUri}) async {
    await _connectDtd(dtdUri);
    await _callTool(
      toolName: 'hot_reload',
      arguments: const <String, Object?>{
        'clearRuntimeErrors': false,
      },
      timeout: _runtimeDelegateTimeout,
      operation: 'hot_reload',
    );
  }

  @override
  Future<void> hotRestart({required String dtdUri}) async {
    await _connectDtd(dtdUri);
    await _callTool(
      toolName: 'hot_restart',
      arguments: const <String, Object?>{},
      timeout: _runtimeDelegateTimeout,
      operation: 'hot_restart',
    );
  }

  Future<_McpConnection> _ensureConnection() async {
    final existing = _connection;
    if (existing != null && existing.connected) {
      return existing;
    }
    final connection = await _McpConnection.start(
      command: command,
      args: args,
      startupTimeout: startupTimeout,
      clientName: 'flutterhelm-delegate',
      exitErrorLabel: 'Official Flutter MCP delegate exited.',
    );
    _connection = connection;
    _lastError = null;
    _registeredRoots.clear();
    return connection;
  }

  Future<void> _ensureRootRegistered(String workspaceRoot) async {
    final uri = _workspaceRootUri(workspaceRoot);
    if (_registeredRoots.contains(uri)) {
      return;
    }
    await _callTool(
      toolName: 'add_roots',
      arguments: <String, Object?>{
        'roots': <Map<String, Object?>>[
          <String, Object?>{
            'uri': uri,
            'name': p.basename(workspaceRoot),
          },
        ],
      },
      timeout: _addRootsTimeout,
      operation: 'add_roots',
    );
    _registeredRoots.add(uri);
  }

  Future<void> _connectDtd(String dtdUri) async {
    await _callTool(
      toolName: 'connect_dart_tooling_daemon',
      arguments: <String, Object?>{'uri': dtdUri},
      timeout: _runtimeDelegateTimeout,
      operation: 'connect_dart_tooling_daemon',
    );
  }

  Future<Map<String, Object?>> _callTool({
    required String toolName,
    required Map<String, Object?> arguments,
    required Duration timeout,
    required String operation,
  }) async {
    final startedAt = DateTime.now().toUtc();
    try {
      final connection = await _ensureConnection();
      final result = await connection.request(
        'tools/call',
        <String, Object?>{
          'name': toolName,
          'arguments': arguments,
        },
        timeoutOverride: timeout,
      );
      if (result['isError'] == true) {
        throw StateError(
          _stringifyToolResult(result).isEmpty
              ? 'Official delegate tool call failed: $toolName'
              : _stringifyToolResult(result),
        );
      }
      observability?.recordAdapterInvocation(
        providerId: 'builtin.delegate.workspace',
        family: 'delegate',
        operation: operation,
        duration: DateTime.now().toUtc().difference(startedAt),
        success: true,
      );
      return result;
    } on Object catch (error) {
      _recordFailure(error);
      observability?.recordAdapterInvocation(
        providerId: 'builtin.delegate.workspace',
        family: 'delegate',
        operation: operation,
        duration: DateTime.now().toUtc().difference(startedAt),
        success: false,
      );
      rethrow;
    }
  }

  void _recordFailure(Object error) {
    _lastError = error.toString();
    final connection = _connection;
    _connection = null;
    _registeredRoots.clear();
    if (connection != null && connection.connected) {
      connection.process.kill(ProcessSignal.sigkill);
    }
  }

  String _workspaceRootUri(String workspaceRoot) {
    return Directory(workspaceRoot).absolute.uri.toString();
  }
}

class _UnavailableRuntimeDriverAdapter implements RuntimeDriverAdapter {
  _UnavailableRuntimeDriverAdapter({required this.reason});

  final String reason;

  @override
  Future<RuntimeDriverHealth> health() async => RuntimeDriverHealth(
    connected: false,
    driverName: null,
    driverVersion: null,
    supportedPlatforms: const <String>[],
    supportedActions: const <String>[],
    supportedLocatorFields: const <String>[],
    screenshotFormats: const <String>[],
    error: reason,
  );

  @override
  Future<void> captureScreenshot({
    required String deviceId,
    required String saveTo,
    required String format,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<void> enterText({
    required String deviceId,
    required String text,
    required bool submit,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<List<Map<String, Object?>>> listElements({
    required String deviceId,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<void> scroll({
    required String deviceId,
    required String direction,
    int? distance,
  }) async {
    throw StateError(reason);
  }

  @override
  Future<void> tap({
    required String deviceId,
    required double x,
    required double y,
  }) async {
    throw StateError(reason);
  }
}

class _StdioJsonRuntimeDriverAdapter implements RuntimeDriverAdapter {
  _StdioJsonRuntimeDriverAdapter({required this.client});

  final _StdioJsonProviderClient client;

  @override
  Future<RuntimeDriverHealth> health() async {
    final payload = await client.health();
    final families = _coerceMap(payload['families']);
    final family = _coerceMap(families['runtimeDriver']);
    final providerInfo = _coerceMap(payload['providerInfo']);
    final state = payload['state'] as String?;
    final healthy = (payload['healthy'] as bool? ?? false) &&
        (family['healthy'] as bool? ?? false);
    return RuntimeDriverHealth(
      connected: healthy || state == 'healthy',
      driverName: providerInfo['name'] as String?,
      driverVersion: providerInfo['version'] as String?,
      supportedPlatforms: _coerceStringList(family['supportedPlatforms']),
      supportedActions: _coerceStringList(family['operations']),
      supportedLocatorFields: _coerceStringList(family['supportedLocatorFields']),
      screenshotFormats: _coerceStringList(family['screenshotFormats']),
      error: family['reason'] as String? ??
          payload['reason'] as String? ??
          _firstReason(payload['reasons']),
    );
  }

  @override
  Future<void> captureScreenshot({
    required String deviceId,
    required String saveTo,
    required String format,
  }) async {
    await client.invoke(
      family: 'runtimeDriver',
      operation: 'capture_screenshot',
      input: <String, Object?>{
        'deviceId': deviceId,
        'saveTo': saveTo,
        'format': format,
      },
    );
  }

  @override
  Future<void> enterText({
    required String deviceId,
    required String text,
    required bool submit,
  }) async {
    await client.invoke(
      family: 'runtimeDriver',
      operation: 'enter_text',
      input: <String, Object?>{
        'deviceId': deviceId,
        'text': text,
        'submit': submit,
      },
    );
  }

  @override
  Future<List<Map<String, Object?>>> listElements({
    required String deviceId,
  }) async {
    final payload = await client.invoke(
      family: 'runtimeDriver',
      operation: 'list_elements',
      input: <String, Object?>{'deviceId': deviceId},
    );
    return _coerceList(payload['elements'])
        .map(_coerceMap)
        .toList();
  }

  @override
  Future<void> scroll({
    required String deviceId,
    required String direction,
    int? distance,
  }) async {
    await client.invoke(
      family: 'runtimeDriver',
      operation: 'scroll_until_visible',
      input: <String, Object?>{
        'deviceId': deviceId,
        'direction': direction,
        if (distance != null) 'distance': distance,
      },
    );
  }

  @override
  Future<void> tap({
    required String deviceId,
    required double x,
    required double y,
  }) async {
    await client.invoke(
      family: 'runtimeDriver',
      operation: 'tap',
      input: <String, Object?>{
        'deviceId': deviceId,
        'x': x,
        'y': y,
      },
    );
  }
}

class _BuiltinMcpRuntimeDriverAdapter implements RuntimeDriverAdapter {
  _BuiltinMcpRuntimeDriverAdapter({
    required this.enabled,
    required this.command,
    required this.args,
    required this.startupTimeout,
  });

  final bool enabled;
  final String command;
  final List<String> args;
  final Duration startupTimeout;
  _McpConnection? _connection;
  RuntimeDriverHealth? _cachedHealth;

  @override
  Future<RuntimeDriverHealth> health() async {
    if (!enabled) {
      return const RuntimeDriverHealth(
        connected: false,
        driverName: null,
        driverVersion: null,
        supportedPlatforms: <String>[],
        supportedActions: <String>[],
        supportedLocatorFields: <String>[],
        screenshotFormats: <String>[],
      );
    }
    if (_cachedHealth != null) {
      return _cachedHealth!;
    }
    try {
      final connection = await _ensureConnection();
      final supportedActions = <String>[
        if (connection.toolNames.contains('mobile_click_on_screen_at_coordinates'))
          'tap_widget',
        if (connection.toolNames.contains('mobile_type_keys')) 'enter_text',
        if (connection.toolNames.contains('mobile_swipe_on_screen') &&
            connection.toolNames.contains('mobile_list_elements_on_screen'))
          'scroll_until_visible',
        if (connection.toolNames.contains('mobile_save_screenshot') ||
            connection.toolNames.contains('mobile_take_screenshot'))
          'capture_screenshot',
      ];
      final locatorFields = connection.serverName == 'mobile-mcp'
          ? const <String>[
              'text',
              'textContains',
              'label',
              'labelContains',
              'index',
              'visibleOnly',
            ]
          : const <String>[
              'text',
              'textContains',
              'label',
              'labelContains',
              'valueKey',
              'type',
              'index',
              'visibleOnly',
            ];
      final screenshotFormats = <String>[
        if (connection.toolNames.contains('mobile_save_screenshot')) 'png',
        if (connection.toolNames.contains('mobile_save_screenshot')) 'jpg',
        if (connection.toolNames.contains('mobile_save_screenshot')) 'jpeg',
      ];
      final platforms = connection.serverName == 'mobile-mcp'
          ? const <String>['ios', 'android']
          : const <String>['ios'];
      final health = RuntimeDriverHealth(
        connected: true,
        driverName: connection.serverName,
        driverVersion: connection.serverVersion,
        supportedPlatforms: platforms,
        supportedActions: supportedActions,
        supportedLocatorFields: locatorFields,
        screenshotFormats: screenshotFormats,
      );
      _cachedHealth = health;
      return health;
    } on Object catch (error) {
      final health = RuntimeDriverHealth(
        connected: false,
        driverName: null,
        driverVersion: null,
        supportedPlatforms: const <String>[],
        supportedActions: const <String>[],
        supportedLocatorFields: const <String>[],
        screenshotFormats: const <String>[],
        error: error.toString(),
      );
      _cachedHealth = health;
      return health;
    }
  }

  @override
  Future<void> captureScreenshot({
    required String deviceId,
    required String saveTo,
    required String format,
  }) async {
    await _callTool(
      'mobile_save_screenshot',
      <String, Object?>{
        'device': deviceId,
        'saveTo': saveTo,
        'format': format,
      },
    );
  }

  @override
  Future<void> enterText({
    required String deviceId,
    required String text,
    required bool submit,
  }) async {
    await _callTool(
      'mobile_type_keys',
      <String, Object?>{
        'device': deviceId,
        'text': text,
        'submit': submit,
      },
    );
  }

  @override
  Future<List<Map<String, Object?>>> listElements({
    required String deviceId,
  }) async {
    final payload = await _callTool(
      'mobile_list_elements_on_screen',
      <String, Object?>{'device': deviceId},
    );
    final normalized = payload is String ? _decodeEmbeddedJson(payload) : payload;
    if (normalized is List) {
      return normalized.map(_coerceMap).toList();
    }
    final map = _coerceMap(normalized);
    return _coerceList(map['elements']).map(_coerceMap).toList();
  }

  @override
  Future<void> scroll({
    required String deviceId,
    required String direction,
    int? distance,
  }) async {
    await _callTool(
      'mobile_swipe_on_screen',
      <String, Object?>{
        'device': deviceId,
        'direction': direction,
        if (distance != null) 'distance': distance,
      },
    );
  }

  @override
  Future<void> tap({
    required String deviceId,
    required double x,
    required double y,
  }) async {
    await _callTool(
      'mobile_click_on_screen_at_coordinates',
      <String, Object?>{
        'device': deviceId,
        'x': x,
        'y': y,
      },
    );
  }

  Future<Object?> _callTool(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final connection = await _ensureConnection();
    final result = await connection.request('tools/call', <String, Object?>{
      'name': name,
      'arguments': arguments,
    }, timeoutOverride: startupTimeout);
    return _decodeToolPayload(result);
  }

  Future<_McpConnection> _ensureConnection() async {
    final existing = _connection;
    if (existing != null && existing.connected) {
      return existing;
    }
    final connection = await _McpConnection.start(
      command: command,
      args: args,
      startupTimeout: startupTimeout,
    );
    _connection = connection;
    _cachedHealth = null;
    return connection;
  }
}

class _StdioJsonProviderClient {
  _StdioJsonProviderClient({
    required this.providerId,
    required this.command,
    required this.args,
    required this.families,
    required this.startupTimeout,
    this.observability,
  });

  final String providerId;
  final String command;
  final List<String> args;
  final List<String> families;
  final Duration startupTimeout;
  final ObservabilityStore? observability;
  _JsonRpcConnection? _connection;
  _ProviderLifecycleState _state = _ProviderLifecycleState.starting;
  int _failureCount = 0;
  DateTime? _backoffUntil;
  String? _lastError;
  Map<String, Object?>? _providerInfo;

  Future<Map<String, Object?>> health() async => _refreshHealth();

  Future<Map<String, Object?>> invoke({
    required String family,
    required String operation,
    required Map<String, Object?> input,
  }) async {
    final connection = await _ensureConnection();
    final startedAt = DateTime.now().toUtc();
    try {
      final result = await connection.request(
        'provider/invoke',
        <String, Object?>{
          'family': family,
          'operation': operation,
          'input': input,
        },
        timeoutOverride: stdioJsonProviderInvokeTimeout,
      );
      _recordHealthy();
      observability?.recordAdapterInvocation(
        providerId: providerId,
        family: family,
        operation: operation,
        duration: DateTime.now().toUtc().difference(startedAt),
        success: true,
      );
      return result;
    } on Object catch (error) {
      _recordFailure(error);
      observability?.recordAdapterInvocation(
        providerId: providerId,
        family: family,
        operation: operation,
        duration: DateTime.now().toUtc().difference(startedAt),
        success: false,
      );
      rethrow;
    }
  }

  Future<_JsonRpcConnection> _ensureConnection() async {
    final existing = _connection;
    if (existing != null && existing.connected) {
      return existing;
    }
    return _startConnection();
  }

  Future<Map<String, Object?>> _refreshHealth() async {
    final blocked = _blockedRetrySnapshot();
    if (blocked != null) {
      return _healthResponse(
        snapshot: blocked,
        families: _familyHealthMap(blocked),
      );
    }

    try {
      final connection = await _ensureConnection();
      final startedAt = DateTime.now().toUtc();
      final payload = await connection.request(
        'provider/health',
        const <String, Object?>{},
        timeoutOverride: startupTimeout,
      );
      final familiesPayload = _coerceMap(payload['families']);
      final familyPayloads = <Map<String, Object?>>[
        for (final family in families) _coerceMap(familiesPayload[family]),
      ];
      final providerInfo = _coerceMap(payload['providerInfo']);
      final healthy = familyPayloads.isEmpty
          ? (payload['healthy'] as bool? ?? false)
          : familyPayloads.every((Map<String, Object?> familyPayload) {
              return familyPayload['healthy'] as bool? ?? false;
            });
      final primaryReason = familyPayloads
          .map((Map<String, Object?> familyPayload) => familyPayload['reason'])
          .whereType<String>()
          .firstWhere(
            (_) => true,
            orElse: () => payload['reason'] as String? ?? '',
          );
      final reason = primaryReason.isEmpty ? null : primaryReason;
      final reasons = <String>[
        ..._coerceStringList(payload['reasons']),
        for (final familyPayload in familyPayloads)
          ..._coerceStringList(familyPayload['reasons']),
        if (reason != null) reason,
      ];
      final state = healthy
          ? _ProviderLifecycleState.healthy
          : _providerStateFromSnapshot(
              payload['state'] as String?,
              healthy: healthy,
            );
      _providerInfo = providerInfo;
      if (healthy) {
        _recordHealthy();
      } else {
        _state = _ProviderLifecycleState.degraded;
        _lastError = reason;
      }
      final snapshot = _snapshot(
        state: state,
        healthy: healthy,
        reasons: reasons.isEmpty && reason != null
            ? <String>[reason]
            : reasons,
        backoffUntil: _backoffUntil,
      );
      observability?.recordAdapterInvocation(
        providerId: providerId,
        family: 'provider',
        operation: 'health',
        duration: DateTime.now().toUtc().difference(startedAt),
        success: healthy,
      );
      return _healthResponse(
        snapshot: snapshot,
        families: payload['families'],
        providerInfo: providerInfo,
      );
    } on Object catch (error) {
      final snapshot = _recordFailureSnapshot(error);
      observability?.recordAdapterInvocation(
        providerId: providerId,
        family: 'provider',
        operation: 'health',
        duration: Duration.zero,
        success: false,
      );
      return _healthResponse(
        snapshot: snapshot,
        families: _familyHealthMap(snapshot),
      );
    }
  }

  Map<String, Object?> _familyHealthMap(_ProviderLifecycleSnapshot snapshot) {
    return <String, Object?>{
      for (final family in families)
        family: <String, Object?>{
          'healthy': false,
          'operations': const <String>[],
          'supportedPlatforms': const <String>[],
          'supportedLocatorFields': const <String>[],
          'screenshotFormats': const <String>[],
          'reasons': snapshot.reasons,
          'reason': snapshot.reasons.isNotEmpty
              ? snapshot.reasons.first
              : snapshot.state.name,
          'state': snapshot.state.name,
        },
    };
  }

  Future<_JsonRpcConnection> _startConnection() async {
    if (command.isEmpty) {
      throw StateError('Provider $providerId is missing a command.');
    }
    final blocked = _blockedRetrySnapshot();
    if (blocked != null) {
      throw StateError(
        'Provider $providerId is in backoff until ${blocked.backoffUntil?.toUtc().toIso8601String() ?? 'unknown'}: ${blocked.reasons.join('; ')}',
      );
    }
    _state = _ProviderLifecycleState.starting;
    final startedAt = DateTime.now().toUtc();
    try {
      final process = await Process.start(command, args);
      final connection = _JsonRpcConnection._(process: process);
      final initialize = await connection.request(
        'initialize',
        <String, Object?>{
          'protocolVersion': '2025-06-18',
          'clientInfo': <String, Object?>{
            'name': 'flutterhelm-adapter-host',
            'version': '0.1.0',
          },
        },
        timeoutOverride: startupTimeout,
      );
      final protocolVersion = initialize['adapterProtocolVersion'] as String?;
      if (protocolVersion != 'flutterhelm.adapter.v1') {
        throw StateError(
          'Provider $providerId returned unsupported adapterProtocolVersion: $protocolVersion',
        );
      }
      _connection = connection;
      observability?.recordAdapterInvocation(
        providerId: providerId,
        family: 'provider',
        operation: 'initialize',
        duration: DateTime.now().toUtc().difference(startedAt),
        success: true,
      );
      return connection;
    } on Object catch (error) {
      _recordFailure(error);
      observability?.recordAdapterInvocation(
        providerId: providerId,
        family: 'provider',
        operation: 'initialize',
        duration: DateTime.now().toUtc().difference(startedAt),
        success: false,
      );
      rethrow;
    }
  }

  void _recordHealthy() {
    _state = _ProviderLifecycleState.healthy;
    _failureCount = 0;
    _backoffUntil = null;
    _lastError = null;
  }

  void _recordFailure(Object error) {
    _connection = null;
    _failureCount += 1;
    _state = _ProviderLifecycleState.backoff;
    _lastError = error.toString();
    final delay = _backoffDelayForAttempt(_failureCount);
    _backoffUntil = DateTime.now().toUtc().add(delay);
  }

  _ProviderLifecycleSnapshot _recordFailureSnapshot(Object error) {
    _recordFailure(error);
    return _snapshot();
  }

  _ProviderLifecycleSnapshot? _blockedRetrySnapshot() {
    final backoffUntil = _backoffUntil;
    if (_state != _ProviderLifecycleState.backoff ||
        backoffUntil == null ||
        !DateTime.now().toUtc().isBefore(backoffUntil)) {
      return null;
    }
    return _snapshot(
      state: _ProviderLifecycleState.backoff,
      healthy: false,
      reasons: <String>[
        if (_lastError != null) _lastError!,
        'Retry after ${backoffUntil.toUtc().toIso8601String()}',
      ],
      backoffUntil: backoffUntil,
    );
  }

  _ProviderLifecycleSnapshot _snapshot({
    _ProviderLifecycleState? state,
    bool? healthy,
    List<String>? reasons,
    DateTime? backoffUntil,
  }) {
    final snapshot = _ProviderLifecycleSnapshot(
      state: state ?? _state,
      healthy: healthy ?? (_state == _ProviderLifecycleState.healthy),
      reasons: reasons ??
          <String>[
            if (_lastError != null) _lastError!,
          ],
      failureCount: _failureCount,
      backoffUntil: backoffUntil ?? _backoffUntil,
      providerInfo: _providerInfo,
    );
    return snapshot;
  }

  Map<String, Object?> _healthResponse({
    required _ProviderLifecycleSnapshot snapshot,
    required Object? families,
    Map<String, Object?>? providerInfo,
  }) {
    final familyMap = families == null
        ? const <String, Object?>{}
        : _coerceMap(families);
    return <String, Object?>{
      'state': snapshot.state.name,
      'healthy': snapshot.healthy,
      'reasons': snapshot.reasons,
      'reason': snapshot.reasons.isEmpty ? null : snapshot.reasons.first,
      'failureCount': snapshot.failureCount,
      if (snapshot.backoffUntil != null)
        'backoffUntil': snapshot.backoffUntil!.toUtc().toIso8601String(),
      'families': familyMap,
      'providerInfo': providerInfo ?? snapshot.providerInfo ?? const <String, Object?>{},
    };
  }

  _ProviderLifecycleState _providerStateFromSnapshot(
    String? state, {
    required bool healthy,
  }) {
    return switch (state) {
      'starting' => healthy
          ? _ProviderLifecycleState.healthy
          : _ProviderLifecycleState.starting,
      'healthy' => healthy
          ? _ProviderLifecycleState.healthy
          : _ProviderLifecycleState.degraded,
      'degraded' => _ProviderLifecycleState.degraded,
      'backoff' => _ProviderLifecycleState.backoff,
      _ => healthy
          ? _ProviderLifecycleState.healthy
          : _ProviderLifecycleState.degraded,
    };
  }

  Duration _backoffDelayForAttempt(int attempt) {
    if (attempt <= 1) {
      return stdioJsonProviderBackoffSchedule[0];
    }
    if (attempt == 2) {
      return stdioJsonProviderBackoffSchedule[1];
    }
    return stdioJsonProviderBackoffSchedule[2];
  }
}

class _JsonRpcConnection {
  _JsonRpcConnection._({
    required this.process,
  }) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {});
    process.exitCode.then((_) {
      _connected = false;
      final pending = Map<String, Completer<Map<String, Object?>>>.from(
        _pendingRequests,
      );
      _pendingRequests.clear();
      for (final completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Adapter provider exited.'));
        }
      }
    });
  }

  final Process process;
  final Map<String, Completer<Map<String, Object?>>> _pendingRequests =
      <String, Completer<Map<String, Object?>>>{};
  int _nextRequestId = 1;
  bool _connected = true;

  bool get connected => _connected;

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
    {Duration? timeoutOverride}) {
    final id = (_nextRequestId++).toString();
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[id] = completer;
    process.stdin.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(timeoutOverride ?? stdioJsonProviderInvokeTimeout);
  }

  void _handleStdoutLine(String line) {
    final message = _tryParseJson(line);
    if (message == null) {
      return;
    }
    final id = message['id']?.toString();
    if (id == null) {
      return;
    }
    final completer = _pendingRequests.remove(id);
    if (completer == null) {
      return;
    }
    if (message['error'] != null) {
      completer.completeError(StateError(jsonEncode(message['error'])));
      return;
    }
    completer.complete(_coerceMap(message['result']));
  }
}

class _McpConnection {
  _McpConnection._({
    required this.process,
    required this.startupTimeout,
    required this.exitErrorLabel,
  }) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {});
    process.exitCode.then((_) {
      _connected = false;
      final pending = Map<String, Completer<Map<String, Object?>>>.from(
        _pendingRequests,
      );
      _pendingRequests.clear();
      for (final completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError(exitErrorLabel));
        }
      }
    });
  }

  final Process process;
  final Duration startupTimeout;
  final String exitErrorLabel;
  String serverName = 'runtime-driver';
  String? serverVersion;
  Set<String> toolNames = <String>{};
  final Map<String, Completer<Map<String, Object?>>> _pendingRequests =
      <String, Completer<Map<String, Object?>>>{};
  int _nextRequestId = 1;
  bool _connected = true;

  bool get connected => _connected;

  static Future<_McpConnection> start({
    required String command,
    required List<String> args,
    required Duration startupTimeout,
    String clientName = 'flutterhelm-runtime-driver',
    String exitErrorLabel = 'MCP server exited.',
  }) async {
    final process = await Process.start(command, args);
    final connection = _McpConnection._(
      process: process,
      startupTimeout: startupTimeout,
      exitErrorLabel: exitErrorLabel,
    );
    final initialize = await connection.request(
      'initialize',
      <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': <String, Object?>{
          'name': clientName,
          'version': '0.1.0',
        },
      },
      timeoutOverride: startupTimeout,
    );
    final toolsList = await connection.request(
      'tools/list',
      <String, Object?>{},
      timeoutOverride: startupTimeout,
    );
    final serverInfo =
        initialize['serverInfo'] as Map<Object?, Object?>? ??
        const <Object?, Object?>{};
    final tools =
        toolsList['tools'] as List<Object?>? ?? const <Object?>[];
    connection.serverName = serverInfo['name'] as String? ?? 'runtime-driver';
    connection.serverVersion = serverInfo['version'] as String?;
    connection.toolNames = tools
        .whereType<Map>()
        .map((Map tool) => tool['name']?.toString() ?? '')
        .where((String name) => name.isNotEmpty)
        .toSet();
    return connection;
  }

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
    {Duration? timeoutOverride}) {
    final id = (_nextRequestId++).toString();
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[id] = completer;
    process.stdin.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(timeoutOverride ?? startupTimeout);
  }

  void _handleStdoutLine(String line) {
    final message = _tryParseJson(line);
    if (message == null) {
      return;
    }
    final id = message['id']?.toString();
    if (id == null) {
      return;
    }
    final completer = _pendingRequests.remove(id);
    if (completer == null) {
      return;
    }
    if (message['error'] != null) {
      completer.completeError(StateError(jsonEncode(message['error'])));
      return;
    }
    completer.complete(_coerceMap(message['result']));
  }
}

Object? _decodeToolPayload(Map<String, Object?> result) {
  final content = result['content'];
  if (content is! List) {
    return result;
  }
  final texts = <String>[];
  for (final item in content) {
    if (item is! Map) {
      continue;
    }
    final text = item['text'];
    if (text is String && text.isNotEmpty) {
      texts.add(text);
    }
  }
  if (texts.isEmpty) {
    return result;
  }
  final joined = texts.join('\n').trim();
  try {
    return jsonDecode(joined);
  } catch (_) {
    return joined;
  }
}

Map<String, Object?> _normalizeAnalyzeProjectResult({
  required String workspaceRoot,
  required Map<String, Object?> result,
  required Duration duration,
}) {
  final diagnostics = _extractDiagnostics(result);
  final stdout = _stringifyToolResult(result);
  final exitCode = diagnostics.isEmpty ? 0 : 1;
  return <String, Object?>{
    'workspaceRoot': workspaceRoot,
    'exitCode': exitCode,
    'issueCount': diagnostics.length,
    'durationMs': duration.inMilliseconds,
    'status': exitCode == 0 ? 'ok' : 'issues_found',
    'stdout': stdout,
    'stderr': '',
  };
}

Map<String, Object?> _normalizeResolveSymbolResult({
  required Map<String, Object?> result,
  required String workspaceRoot,
  required String symbol,
}) {
  final matches = _collectSymbolMatches(result, symbol, workspaceRoot);
  return <String, Object?>{
    'symbol': symbol,
    'matches': matches,
    'resolved': matches.isNotEmpty,
  };
}

Map<String, Object?> _normalizePubSearchResult({
  required Map<String, Object?> result,
  required String query,
  required int limit,
}) {
  final packages = <Map<String, Object?>>[];
  for (final item in _contentPayloads(result)) {
    final decoded = _decodeSinglePayload(item);
    final object = _coerceMap(decoded);
    if (object.isEmpty) {
      continue;
    }
    final packageName = _stringValue(object['package']) ??
        _stringValue(object['packageName']);
    if (packageName == null) {
      continue;
    }
    packages.add(<String, Object?>{
      'package': packageName,
      'latestVersion': _stringValue(object['latestVersion']) ??
          _stringValue(object['latest_version']) ??
          _stringValue(object['version']),
      'description': _stringValue(object['description']) ?? '',
      'url': _stringValue(object['url']) ?? 'https://pub.dev/packages/$packageName',
      if (_stringValue(object['publisher']) != null)
        'publisher': _stringValue(object['publisher']),
      if (_stringValue(object['publisherId']) != null)
        'publisher': _stringValue(object['publisherId']),
    });
    if (packages.length >= limit) {
      break;
    }
  }
  if (packages.isEmpty) {
    throw StateError(
      'Official delegate returned an unexpected pub_dev_search payload.',
    );
  }
  return <String, Object?>{
    'query': query,
    'packages': packages,
  };
}

List<Map<String, Object?>> _normalizeRuntimeErrors(Map<String, Object?> result) {
  final container = _decodeStructuredPayload(result);
  final candidates = <Object?>[];
  if (container is List) {
    candidates.addAll(container);
  } else {
    final object = _coerceMap(container);
    if (object['errors'] is List) {
      candidates.addAll(_coerceList(object['errors']));
    } else if (object['runtimeErrors'] is List) {
      candidates.addAll(_coerceList(object['runtimeErrors']));
    } else if (object.isNotEmpty) {
      candidates.add(object);
    }
  }
  final errors = <Map<String, Object?>>[];
  for (final candidate in candidates) {
    final object = _coerceMap(candidate);
    if (object.isEmpty) {
      final text = candidate is String ? candidate.trim() : '';
      if (text.isEmpty) {
        continue;
      }
      errors.add(<String, Object?>{
        'kind': 'runtime_error',
        'summary': text,
      });
      continue;
    }
    final summary = _stringValue(object['summary']) ??
        _stringValue(object['message']) ??
        _stringValue(object['description']) ??
        _stringValue(object['text']);
    if (summary == null) {
      continue;
    }
    errors.add(<String, Object?>{
      'kind': _stringValue(object['kind']) ??
          _stringValue(object['type']) ??
          'runtime_error',
      'summary': summary,
      if (_stringValue(object['category']) != null)
        'category': _stringValue(object['category']),
      if (_intValue(object['line']) != null) 'line': _intValue(object['line']),
    });
  }
  return errors;
}

Map<String, Object?> _normalizeWidgetTree(
  Map<String, Object?> result, {
  required int depth,
}) {
  final decoded = _decodeStructuredPayload(result);
  final tree = _resolveWidgetTreeRoot(decoded);
  if (tree.isEmpty) {
    throw StateError(
      'Official delegate returned an unexpected widget tree payload.',
    );
  }
  return _trimWidgetTree(tree, depth);
}

List<Map<String, Object?>> _extractDiagnostics(Map<String, Object?> result) {
  final decoded = _decodeStructuredPayload(result);
  final diagnostics = <Map<String, Object?>>[];
  void visit(Object? node) {
    if (node is List) {
      for (final item in node) {
        visit(item);
      }
      return;
    }
    final object = _coerceMap(node);
    if (object.isEmpty) {
      return;
    }
    final hasMessage = _stringValue(object['message']) != null ||
        _stringValue(object['problemMessage']) != null;
    final hasLocation = object['location'] != null ||
        object['line'] != null ||
        object['file'] != null ||
        object['path'] != null;
    if (hasMessage && hasLocation) {
      diagnostics.add(object);
    }
    for (final value in object.values) {
      visit(value);
    }
  }

  visit(decoded);
  return diagnostics;
}

List<Map<String, Object?>> _collectSymbolMatches(
  Map<String, Object?> result,
  String symbol,
  String workspaceRoot,
) {
  final decoded = _decodeStructuredPayload(result);
  final matches = <Map<String, Object?>>[];

  void visit(Object? node) {
    if (node is List) {
      for (final item in node) {
        visit(item);
      }
      return;
    }
    final object = _coerceMap(node);
    if (object.isEmpty) {
      return;
    }
    final path = _extractPathLikeValue(object);
    final snippet = _stringValue(object['snippet']) ??
        _stringValue(object['declaration']) ??
        _stringValue(object['signature']) ??
        _stringValue(object['label']) ??
        _stringValue(object['name']);
    final candidateName = _stringValue(object['name']) ??
        _stringValue(object['symbol']) ??
        _stringValue(object['label']);
    if (path != null &&
        (snippet?.contains(symbol) == true || candidateName == symbol)) {
      matches.add(<String, Object?>{
        'symbol': symbol,
        'path': path,
        'line': _intValue(object['line']) ?? 1,
        'column': _intValue(object['column']) ?? 1,
        'snippet': snippet ?? symbol,
      });
    }
    for (final value in object.values) {
      visit(value);
    }
  }

  visit(decoded);
  if (matches.isEmpty) {
    return const <Map<String, Object?>>[];
  }
  final normalizedWorkspaceRoot = p.normalize(workspaceRoot);
  matches.sort((left, right) {
    final leftPath = p.normalize(left['path'] as String);
    final rightPath = p.normalize(right['path'] as String);
    final leftScore = p.isWithin(normalizedWorkspaceRoot, leftPath) ? 0 : 1;
    final rightScore = p.isWithin(normalizedWorkspaceRoot, rightPath) ? 0 : 1;
    if (leftScore != rightScore) {
      return leftScore.compareTo(rightScore);
    }
    final pathCompare = leftPath.compareTo(rightPath);
    if (pathCompare != 0) {
      return pathCompare;
    }
    return ((left['line'] as int?) ?? 0).compareTo(
      (right['line'] as int?) ?? 0,
    );
  });
  final seen = <String>{};
  return <Map<String, Object?>>[
    for (final match in matches)
      if (seen.add(
        '${match['path']}:${match['line']}:${match['column']}:${match['snippet']}',
      ))
        match,
  ];
}

Object? _decodeStructuredPayload(Map<String, Object?> result) {
  final payloads = _contentPayloads(result);
  if (payloads.isEmpty) {
    return _decodeToolPayload(result);
  }
  if (payloads.length == 1) {
    return _decodeSinglePayload(payloads.single);
  }
  final decodedItems = payloads.map(_decodeSinglePayload).toList();
  if (decodedItems.every((Object? item) => item is Map || item is List)) {
    return decodedItems;
  }
  return decodedItems;
}

List<Map<String, Object?>> _contentPayloads(Map<String, Object?> result) {
  final content = _coerceList(result['content']);
  return content
      .map(_coerceMap)
      .where((Map<String, Object?> item) {
        return item['text'] is String &&
            (item['text'] as String).trim().isNotEmpty;
      })
      .toList();
}

Object? _decodeSinglePayload(Map<String, Object?> payload) {
  final text = _stringValue(payload['text']);
  if (text == null) {
    return payload;
  }
  try {
    return jsonDecode(text);
  } catch (_) {
    return text;
  }
}

String _stringifyToolResult(Map<String, Object?> result) {
  final texts = _contentPayloads(result)
      .map((Map<String, Object?> item) => item['text'] as String)
      .where((String text) => text.trim().isNotEmpty)
      .toList();
  if (texts.isNotEmpty) {
    return texts.join('\n').trim();
  }
  final decoded = _decodeToolPayload(result);
  if (decoded is String) {
    return decoded;
  }
  return const JsonEncoder.withIndent('  ').convert(decoded);
}

String? _extractPathLikeValue(Map<String, Object?> object) {
  final directPath = _stringValue(object['path']) ??
      _stringValue(object['file']) ??
      _stringValue(object['filePath']);
  if (directPath != null) {
    return directPath;
  }
  final uri = _stringValue(object['uri']);
  if (uri != null && uri.startsWith('file:')) {
    return Uri.parse(uri).toFilePath();
  }
  final location = _coerceMap(object['location']);
  final locationUri = _stringValue(location['uri']);
  if (locationUri != null && locationUri.startsWith('file:')) {
    return Uri.parse(locationUri).toFilePath();
  }
  return _stringValue(location['path']) ??
      _stringValue(location['file']) ??
      _stringValue(location['filePath']);
}

Map<String, Object?> _resolveWidgetTreeRoot(Object? decoded) {
  if (decoded is Map<String, Object?> && decoded.isNotEmpty) {
    if (decoded.containsKey('tree')) {
      return _coerceMap(decoded['tree']);
    }
    if (decoded.containsKey('root')) {
      return _coerceMap(decoded['root']);
    }
    if (decoded.containsKey('widgetTree')) {
      return _coerceMap(decoded['widgetTree']);
    }
    return decoded;
  }
  if (decoded is List && decoded.isNotEmpty) {
    for (final item in decoded) {
      final object = _resolveWidgetTreeRoot(item);
      if (object.isNotEmpty) {
        return object;
      }
    }
  }
  return <String, Object?>{};
}

Map<String, Object?> _trimWidgetTree(Map<String, Object?> node, int depth) {
  if (depth <= 1) {
    return <String, Object?>{
      for (final entry in node.entries)
        if (entry.key != 'children' && entry.key != 'properties')
          entry.key: entry.value,
      'children': const <Object?>[],
    };
  }
  final children = node['children'];
  final trimmedChildren = <Map<String, Object?>>[];
  if (children is List) {
    for (final child in children) {
      trimmedChildren.add(_trimWidgetTree(_coerceMap(child), depth - 1));
    }
  }
  return <String, Object?>{
    for (final entry in node.entries)
      if (entry.key != 'children') entry.key: entry.value,
    'children': trimmedChildren,
  };
}

Object? _decodeEmbeddedJson(String text) {
  final firstArray = text.indexOf('[');
  final firstObject = text.indexOf('{');
  final indexes = <int>[
    if (firstArray >= 0) firstArray,
    if (firstObject >= 0) firstObject,
  ]..sort();
  if (indexes.isEmpty) {
    return text;
  }
  final candidate = text.substring(indexes.first).trim();
  try {
    return jsonDecode(candidate);
  } catch (_) {
    return text;
  }
}

Map<String, Object?>? _tryParseJson(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
    return null;
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map<String, Object?>(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key.toString(), value),
      );
    }
  } catch (_) {
    return null;
  }
  return null;
}

Map<String, Object?> _coerceMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, Object?>(
      (Object? key, Object? nested) =>
          MapEntry<String, Object?>(key.toString(), nested),
    );
  }
  return <String, Object?>{};
}

List<Object?> _coerceList(Object? value) {
  if (value is List<Object?>) {
    return value;
  }
  if (value is List) {
    return value.cast<Object?>();
  }
  return const <Object?>[];
}

List<String> _coerceStringList(Object? value) {
  return _coerceList(value).whereType<String>().toList();
}

String? _firstReason(Object? value) {
  final reasons = _coerceStringList(value);
  if (reasons.isNotEmpty) {
    return reasons.first;
  }
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

String? _stringValue(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

int? _intValue(Object? value) {
  if (value is int) {
    return value;
  }
  return null;
}

DateTime? _dateTimeValue(Object? value) {
  if (value is String && value.isNotEmpty) {
    return DateTime.tryParse(value);
  }
  return null;
}
