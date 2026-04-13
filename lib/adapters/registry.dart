import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/utils/process_runner.dart';

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

class AdapterFamilyStatus {
  const AdapterFamilyStatus({
    required this.family,
    required this.activeProviderId,
    required this.kind,
    required this.builtin,
    required this.healthy,
    required this.operations,
    this.reason,
    this.providerInfo,
  });

  final String family;
  final String? activeProviderId;
  final String? kind;
  final bool builtin;
  final bool healthy;
  final List<String> operations;
  final String? reason;
  final Map<String, Object?>? providerInfo;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'family': family,
      'activeProviderId': activeProviderId,
      'kind': kind,
      'builtin': builtin,
      'healthy': healthy,
      'operations': operations,
      if (reason != null) 'reason': reason,
      if (providerInfo != null) 'providerInfo': providerInfo,
    };
  }
}

class AdapterRegistry {
  AdapterRegistry({
    required this.config,
    required this.processRunner,
  });

  final FlutterHelmConfig config;
  final ProcessRunner processRunner;
  final Map<String, _StdioJsonProviderClient> _providerClients =
      <String, _StdioJsonProviderClient>{};
  RuntimeDriverAdapter? _runtimeDriverAdapter;

  static const List<String> supportedFamilies = <String>[
    'delegate',
    'flutterCli',
    'profiling',
    'runtimeDriver',
    'platformBridge',
  ];

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

  Future<Map<String, Object?>> currentResource() async {
    final families = <Map<String, Object?>>[];
    for (final family in supportedFamilies) {
      families.add((await familyStatus(family)).toJson());
    }
    return <String, Object?>{
      'families': families,
      'active': config.adapters.activeProviders,
      'providers': <String, Object?>{
        for (final entry in config.adapters.providers.entries)
          entry.key: <String, Object?>{
            'kind': entry.value.kind,
            'families': entry.value.families,
            'builtin': entry.value.builtin,
            if (entry.value.command != null) 'command': entry.value.command,
            if (entry.value.args.isNotEmpty) 'args': entry.value.args,
            if (entry.value.startupTimeoutMs > 0)
              'startupTimeoutMs': entry.value.startupTimeoutMs,
          },
      },
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
        reason: 'Configured provider $providerId was not found.',
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
        reason: 'Provider $providerId does not support family $family.',
      );
    }

    if (provider.kind == 'stdio_json') {
      try {
        final health = await _providerClient(provider).health();
        final familyHealth = _coerceMap(
          _coerceMap(health['families'])[family],
        );
        final operations = _coerceStringList(familyHealth['operations']);
        final healthy = familyHealth['healthy'] as bool? ?? false;
        return AdapterFamilyStatus(
          family: family,
          activeProviderId: providerId,
          kind: provider.kind,
          builtin: provider.builtin,
          healthy: healthy,
          operations: operations,
          reason: familyHealth['reason'] as String?,
          providerInfo: _coerceMap(health['providerInfo']),
        );
      } on Object catch (error) {
        return AdapterFamilyStatus(
          family: family,
          activeProviderId: providerId,
          kind: provider.kind,
          builtin: provider.builtin,
          healthy: false,
          operations: const <String>[],
          reason: error.toString(),
        );
      }
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
        reason: health.error,
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
    );
  }

  _StdioJsonProviderClient _providerClient(AdapterProviderConfig provider) {
    return _providerClients.putIfAbsent(
      provider.id,
      () => _StdioJsonProviderClient(
        providerId: provider.id,
        command: provider.command ?? '',
        args: provider.args,
        startupTimeout: Duration(
          milliseconds: provider.startupTimeoutMs > 0
              ? provider.startupTimeoutMs
              : 5000,
        ),
      ),
    );
  }
}

const Map<String, List<String>> _builtinOperations = <String, List<String>>{
  'delegate': <String>['analyze_project', 'resolve_symbol', 'pub_search'],
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
    return RuntimeDriverHealth(
      connected: family['healthy'] as bool? ?? false,
      driverName: providerInfo['name'] as String?,
      driverVersion: providerInfo['version'] as String?,
      supportedPlatforms: _coerceStringList(family['supportedPlatforms']),
      supportedActions: _coerceStringList(family['operations']),
      supportedLocatorFields: _coerceStringList(family['supportedLocatorFields']),
      screenshotFormats: _coerceStringList(family['screenshotFormats']),
      error: family['reason'] as String?,
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
    });
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
    required this.startupTimeout,
  });

  final String providerId;
  final String command;
  final List<String> args;
  final Duration startupTimeout;
  _JsonRpcConnection? _connection;
  Map<String, Object?>? _healthCache;

  Future<Map<String, Object?>> health() async {
    if (_healthCache != null) {
      return _healthCache!;
    }
    final connection = await _ensureConnection();
    final payload = await connection.request(
      'provider/health',
      const <String, Object?>{},
    );
    _healthCache = payload;
    return payload;
  }

  Future<Map<String, Object?>> invoke({
    required String family,
    required String operation,
    required Map<String, Object?> input,
  }) async {
    final connection = await _ensureConnection();
    return connection.request(
      'provider/invoke',
      <String, Object?>{
        'family': family,
        'operation': operation,
        'input': input,
      },
    );
  }

  Future<_JsonRpcConnection> _ensureConnection() async {
    final existing = _connection;
    if (existing != null && existing.connected) {
      return existing;
    }
    if (command.isEmpty) {
      throw StateError('Provider $providerId is missing a command.');
    }
    final process = await Process.start(command, args);
    final connection = _JsonRpcConnection._(
      process: process,
      timeout: startupTimeout,
    );
    final initialize = await connection.request(
      'initialize',
      <String, Object?>{
        'protocolVersion': '2025-06-18',
        'clientInfo': <String, Object?>{
          'name': 'flutterhelm-adapter-host',
          'version': '0.1.0',
        },
      },
    );
    final protocolVersion = initialize['adapterProtocolVersion'] as String?;
    if (protocolVersion != 'flutterhelm.adapter.v1') {
      throw StateError(
        'Provider $providerId returned unsupported adapterProtocolVersion: $protocolVersion',
      );
    }
    _connection = connection;
    _healthCache = null;
    return connection;
  }
}

class _JsonRpcConnection {
  _JsonRpcConnection._({
    required this.process,
    required this.timeout,
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
  final Duration timeout;
  final Map<String, Completer<Map<String, Object?>>> _pendingRequests =
      <String, Completer<Map<String, Object?>>>{};
  int _nextRequestId = 1;
  bool _connected = true;

  bool get connected => _connected;

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
  ) {
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
    return completer.future.timeout(timeout);
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
          completer.completeError(StateError('Runtime driver exited.'));
        }
      }
    });
  }

  final Process process;
  final Duration startupTimeout;
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
  }) async {
    final process = await Process.start(command, args);
    final connection = _McpConnection._(
      process: process,
      startupTimeout: startupTimeout,
    );
    final initialize = await connection.request(
      'initialize',
      <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': <String, Object?>{
          'name': 'flutterhelm-runtime-driver',
          'version': '0.1.0',
        },
      },
    );
    final toolsList = await connection.request(
      'tools/list',
      <String, Object?>{},
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
  ) {
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
    return completer.future.timeout(startupTimeout);
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
