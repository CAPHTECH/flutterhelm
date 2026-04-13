import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RuntimePaths {
  RuntimePaths({required this.configPath, required this.stateDir});

  final String configPath;
  final String stateDir;

  String get stateFilePath => p.join(stateDir, 'state.json');
  String get auditFilePath => p.join(stateDir, 'audit.jsonl');

  static const String configEnvVar = 'FLUTTERHELM_CONFIG_PATH';
  static const String stateDirEnvVar = 'FLUTTERHELM_STATE_DIR';
  static const String profileEnvVar = 'FLUTTERHELM_PROFILE';

  factory RuntimePaths.fromEnvironment({
    String? configPathOverride,
    String? stateDirOverride,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final defaultStateDir = _resolveDefaultStateDir(env);
    final stateDir = stateDirOverride ?? env[stateDirEnvVar] ?? defaultStateDir;
    final configPath =
        configPathOverride ??
        env[configEnvVar] ??
        p.join(defaultStateDir, 'config.yaml');

    return RuntimePaths(
      configPath: p.normalize(configPath),
      stateDir: p.normalize(stateDir),
    );
  }

  static String _resolveDefaultStateDir(Map<String, String> environment) {
    if (Platform.isWindows) {
      final appData = environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return p.join(appData, 'flutterhelm');
      }

      final userProfile = environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return p.join(userProfile, 'AppData', 'Roaming', 'flutterhelm');
      }
    }

    final xdgConfigHome = environment['XDG_CONFIG_HOME'];
    if (xdgConfigHome != null && xdgConfigHome.isNotEmpty) {
      return p.join(xdgConfigHome, 'flutterhelm');
    }

    final home = environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, '.config', 'flutterhelm');
    }

    return p.join(Directory.current.path, '.flutterhelm');
  }
}

class WorkspaceConfig {
  const WorkspaceConfig({required this.roots});

  final List<String> roots;

  Map<String, Object?> toJson() => <String, Object?>{'roots': roots};
}

class DefaultsConfig {
  const DefaultsConfig({required this.target, required this.mode});

  final String target;
  final String mode;

  Map<String, Object?> toJson() => <String, Object?>{
    'target': target,
    'mode': mode,
  };
}

class FallbacksConfig {
  const FallbacksConfig({required this.allowRootFallback});

  final bool allowRootFallback;

  Map<String, Object?> toJson() => <String, Object?>{
    'allowRootFallback': allowRootFallback,
  };
}

class RetentionConfig {
  const RetentionConfig({
    required this.heavyArtifactsDays,
    required this.metadataDays,
    required this.maxArtifactBytes,
  });

  final int heavyArtifactsDays;
  final int metadataDays;
  final int maxArtifactBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'heavyArtifactsDays': heavyArtifactsDays,
    'metadataDays': metadataDays,
    'maxArtifactBytes': maxArtifactBytes,
  };
}

class SafetyConfig {
  const SafetyConfig({required this.confirmBefore});

  final List<String> confirmBefore;

  Map<String, Object?> toJson() => <String, Object?>{
    'confirmBefore': confirmBefore,
  };
}

class AdapterProviderConfig {
  const AdapterProviderConfig({
    required this.id,
    required this.kind,
    required this.families,
    this.command,
    this.args = const <String>[],
    this.startupTimeoutMs = 5000,
    this.builtin = false,
    this.options = const <String, Object?>{},
  });

  final String id;
  final String kind;
  final List<String> families;
  final String? command;
  final List<String> args;
  final int startupTimeoutMs;
  final bool builtin;
  final Map<String, Object?> options;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind,
      'families': families,
      if (command != null) 'command': command,
      if (args.isNotEmpty) 'args': args,
      if (startupTimeoutMs > 0) 'startupTimeoutMs': startupTimeoutMs,
      if (builtin) 'builtin': builtin,
      if (options.isNotEmpty) 'options': options,
    };
  }
}

class AdaptersConfig {
  const AdaptersConfig({
    required this.delegateType,
    required this.flutterExecutable,
    required this.dtdEnabled,
    required this.runtimeDriverEnabled,
    required this.runtimeDriverCommand,
    required this.runtimeDriverArgs,
    required this.runtimeDriverStartupTimeoutMs,
    required this.activeProviders,
    required this.providers,
    required this.deprecations,
  });

  final String delegateType;
  final String flutterExecutable;
  final bool dtdEnabled;
  final bool runtimeDriverEnabled;
  final String runtimeDriverCommand;
  final List<String> runtimeDriverArgs;
  final int runtimeDriverStartupTimeoutMs;
  final Map<String, String> activeProviders;
  final Map<String, AdapterProviderConfig> providers;
  final List<Map<String, Object?>> deprecations;

  static const Map<String, String> defaultActiveProviders = <String, String>{
    'delegate': 'builtin.delegate.workspace',
    'flutterCli': 'builtin.flutter.cli',
    'profiling': 'builtin.profiling.vm_service',
    'runtimeDriver': 'builtin.runtime_driver.external_process',
    'nativeBuild': 'builtin.native_build.external_process',
    'platformBridge': 'builtin.platform_bridge.handoff',
  };

  static Map<String, AdapterProviderConfig> defaultProviders({
    required String delegateType,
    required String flutterExecutable,
    required bool dtdEnabled,
    required bool runtimeDriverEnabled,
    required String runtimeDriverCommand,
    required List<String> runtimeDriverArgs,
    required int runtimeDriverStartupTimeoutMs,
  }) {
    return <String, AdapterProviderConfig>{
      'builtin.delegate.workspace': AdapterProviderConfig(
        id: 'builtin.delegate.workspace',
        kind: 'builtin',
        families: const <String>['delegate'],
        builtin: true,
        options: <String, Object?>{'type': delegateType},
      ),
      'builtin.flutter.cli': AdapterProviderConfig(
        id: 'builtin.flutter.cli',
        kind: 'builtin',
        families: const <String>['flutterCli'],
        builtin: true,
        options: <String, Object?>{
          'executable': flutterExecutable,
          'dtdEnabled': dtdEnabled,
        },
      ),
      'builtin.profiling.vm_service': const AdapterProviderConfig(
        id: 'builtin.profiling.vm_service',
        kind: 'builtin',
        families: <String>['profiling'],
        builtin: true,
      ),
      'builtin.runtime_driver.external_process': AdapterProviderConfig(
        id: 'builtin.runtime_driver.external_process',
        kind: 'builtin',
        families: const <String>['runtimeDriver'],
        builtin: true,
        command: runtimeDriverCommand,
        args: runtimeDriverArgs,
        startupTimeoutMs: runtimeDriverStartupTimeoutMs,
        options: <String, Object?>{'enabled': runtimeDriverEnabled},
      ),
      'builtin.native_build.external_process': const AdapterProviderConfig(
        id: 'builtin.native_build.external_process',
        kind: 'builtin',
        families: <String>['nativeBuild'],
        builtin: true,
        options: <String, Object?>{'enabled': false},
      ),
      'builtin.platform_bridge.handoff': const AdapterProviderConfig(
        id: 'builtin.platform_bridge.handoff',
        kind: 'builtin',
        families: <String>['platformBridge'],
        builtin: true,
      ),
    };
  }

  AdapterProviderConfig? providerForFamily(String family) {
    final providerId = activeProviders[family];
    if (providerId == null) {
      return null;
    }
    return providers[providerId];
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'active': activeProviders,
    'providers': <String, Object?>{
      for (final entry in providers.entries) entry.key: entry.value.toJson(),
    },
    if (deprecations.isNotEmpty) 'deprecations': deprecations,
  };
}

class FlutterHelmConfig {
  const FlutterHelmConfig({
    required this.version,
    required this.workspace,
    required this.defaults,
    required this.enabledWorkflows,
    required this.fallbacks,
    required this.retention,
    required this.safety,
    required this.adapters,
    this.activeProfile,
    this.availableProfiles = const <String>[],
  });

  final int version;
  final WorkspaceConfig workspace;
  final DefaultsConfig defaults;
  final List<String> enabledWorkflows;
  final FallbacksConfig fallbacks;
  final RetentionConfig retention;
  final SafetyConfig safety;
  final AdaptersConfig adapters;
  final String? activeProfile;
  final List<String> availableProfiles;

  static const List<String> defaultWorkflows = <String>[
    'workspace',
    'session',
    'launcher',
    'runtime_readonly',
    'profiling',
    'platform_bridge',
    'tests',
  ];

  factory FlutterHelmConfig.defaults() {
    return FlutterHelmConfig(
      version: 1,
      workspace: const WorkspaceConfig(roots: <String>[]),
      defaults: const DefaultsConfig(target: 'lib/main.dart', mode: 'debug'),
      enabledWorkflows: defaultWorkflows,
      fallbacks: const FallbacksConfig(allowRootFallback: false),
      retention: const RetentionConfig(
        heavyArtifactsDays: 7,
        metadataDays: 30,
        maxArtifactBytes: 536870912,
      ),
      safety: const SafetyConfig(
        confirmBefore: <String>[
          'dependency_add',
          'dependency_remove',
          'hot_restart',
          'build_app:release',
        ],
      ),
      adapters: AdaptersConfig(
        delegateType: 'dart_flutter_mcp',
        flutterExecutable: 'flutter',
        dtdEnabled: true,
        runtimeDriverEnabled: false,
        runtimeDriverCommand: 'npx',
        runtimeDriverArgs: <String>[
          '-y',
          '@mobilenext/mobile-mcp@latest',
          '--stdio',
        ],
        runtimeDriverStartupTimeoutMs: 5000,
        activeProviders: AdaptersConfig.defaultActiveProviders,
        providers: AdaptersConfig.defaultProviders(
          delegateType: 'dart_flutter_mcp',
          flutterExecutable: 'flutter',
          dtdEnabled: true,
          runtimeDriverEnabled: false,
          runtimeDriverCommand: 'npx',
          runtimeDriverArgs: const <String>[
            '-y',
            '@mobilenext/mobile-mcp@latest',
            '--stdio',
          ],
          runtimeDriverStartupTimeoutMs: 5000,
        ),
        deprecations: const <Map<String, Object?>>[],
      ),
    );
  }

  factory FlutterHelmConfig.fromYamlText(
    String yamlText, {
    String? selectedProfile,
  }) {
    final document = loadYaml(yamlText);
    if (document == null) {
      if (selectedProfile != null && selectedProfile.isNotEmpty) {
        throw ConfigException('Unknown config profile: $selectedProfile');
      }
      return FlutterHelmConfig.defaults();
    }
    if (document is! YamlMap) {
      throw ConfigException('Config root must be a YAML object.');
    }

    final root = _toPlainMap(document);
    final profiles = _mapOfMaps(root['profiles']);
    final availableProfiles = profiles.keys.toList()..sort();
    final resolvedRoot = _applyProfileOverlay(
      root,
      profiles: profiles,
      selectedProfile: selectedProfile,
    );
    final version = _intValue(root['version'], 'version') ?? 1;
    if (version != 1) {
      throw ConfigException('Unsupported config version: $version');
    }

    final workspace = _mapValue(resolvedRoot['workspace']);
    final defaults = _mapValue(resolvedRoot['defaults']);
    final fallbacks = _mapValue(resolvedRoot['fallbacks']);
    final retention = _mapValue(resolvedRoot['retention']);
    final safety = _mapValue(resolvedRoot['safety']);
    final adapters = _mapValue(resolvedRoot['adapters']);
    _ensureNoRemovedAdapterFields(adapters);
    final defaultProviders = AdaptersConfig.defaultProviders(
      delegateType: 'dart_flutter_mcp',
      flutterExecutable: 'flutter',
      dtdEnabled: true,
      runtimeDriverEnabled: false,
      runtimeDriverCommand: 'npx',
      runtimeDriverArgs: const <String>[
        '-y',
        '@mobilenext/mobile-mcp@latest',
        '--stdio',
      ],
      runtimeDriverStartupTimeoutMs: 5000,
    );
    final configuredProviders = _parseProviderConfigs(_mapValue(adapters['providers']));
    final providers = <String, AdapterProviderConfig>{
      ...defaultProviders,
      ...configuredProviders,
    };
    final activeProviders = <String, String>{
      ...AdaptersConfig.defaultActiveProviders,
      ..._stringMap(_mapValue(adapters['active'])),
    };
    final delegateType = _stringValue(
          providers['builtin.delegate.workspace']?.options['type'],
        ) ??
        'dart_flutter_mcp';
    final flutterExecutable = _stringValue(
          providers['builtin.flutter.cli']?.options['executable'],
        ) ??
        'flutter';
    final dtdEnabled =
        _boolValue(providers['builtin.flutter.cli']?.options['dtdEnabled']) ??
        true;
    final runtimeDriverEnabled = _boolValue(
          providers['builtin.runtime_driver.external_process']?.options['enabled'],
        ) ??
        false;
    final runtimeDriverCommand =
        providers['builtin.runtime_driver.external_process']?.command ?? 'npx';
    final runtimeDriverArgs =
        providers['builtin.runtime_driver.external_process']?.args ??
        const <String>[
          '-y',
          '@mobilenext/mobile-mcp@latest',
          '--stdio',
        ];
    final runtimeDriverStartupTimeoutMs =
        providers['builtin.runtime_driver.external_process']?.startupTimeoutMs ??
        5000;

    return FlutterHelmConfig(
      version: version,
      workspace: WorkspaceConfig(
        roots: _stringList(workspace['roots']) ?? const <String>[],
      ),
      defaults: DefaultsConfig(
        target: _stringValue(defaults['target']) ?? 'lib/main.dart',
        mode: _stringValue(defaults['mode']) ?? 'debug',
      ),
      enabledWorkflows:
          _stringList(resolvedRoot['enabledWorkflows']) ?? defaultWorkflows,
      fallbacks: FallbacksConfig(
        allowRootFallback: _boolValue(fallbacks['allowRootFallback']) ?? false,
      ),
      retention: RetentionConfig(
        heavyArtifactsDays: _intValue(retention['heavyArtifactsDays']) ?? 7,
        metadataDays: _intValue(retention['metadataDays']) ?? 30,
        maxArtifactBytes: _intValue(retention['maxArtifactBytes']) ?? 536870912,
      ),
      safety: SafetyConfig(
        confirmBefore:
            _stringList(safety['confirmBefore']) ??
            const <String>[
              'dependency_add',
              'dependency_remove',
              'hot_restart',
              'build_app:release',
            ],
      ),
      adapters: AdaptersConfig(
        delegateType: delegateType,
        flutterExecutable: flutterExecutable,
        dtdEnabled: dtdEnabled,
        runtimeDriverEnabled: runtimeDriverEnabled,
        runtimeDriverCommand: runtimeDriverCommand,
        runtimeDriverArgs: runtimeDriverArgs,
        runtimeDriverStartupTimeoutMs: runtimeDriverStartupTimeoutMs,
        activeProviders: activeProviders,
        providers: providers,
        deprecations: const <Map<String, Object?>>[],
      ),
      activeProfile: selectedProfile,
      availableProfiles: availableProfiles,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': version,
      'workspace': workspace.toJson(),
      'defaults': defaults.toJson(),
      'enabledWorkflows': enabledWorkflows,
      'fallbacks': fallbacks.toJson(),
      'retention': retention.toJson(),
      'safety': safety.toJson(),
      'adapters': adapters.toJson(),
      'activeProfile': activeProfile,
      'availableProfiles': availableProfiles,
    };
  }
}

class ConfigRepository {
  ConfigRepository(this.runtimePaths);

  final RuntimePaths runtimePaths;

  Future<FlutterHelmConfig> load({String? selectedProfile}) async {
    final file = File(runtimePaths.configPath);
    if (!await file.exists()) {
      if (selectedProfile != null && selectedProfile.isNotEmpty) {
        throw ConfigException('Unknown config profile: $selectedProfile');
      }
      return FlutterHelmConfig.defaults();
    }

    final yamlText = await file.readAsString();
    return FlutterHelmConfig.fromYamlText(
      yamlText,
      selectedProfile: selectedProfile,
    );
  }
}

class ServerState {
  const ServerState({required this.activeRoot, required this.updatedAt});

  final String? activeRoot;
  final DateTime? updatedAt;

  factory ServerState.empty() =>
      const ServerState(activeRoot: null, updatedAt: null);

  factory ServerState.fromJson(Map<String, Object?> json) {
    return ServerState(
      activeRoot: json['activeRoot'] as String?,
      updatedAt: json['updatedAt'] is String
          ? DateTime.parse(json['updatedAt'] as String)
          : null,
    );
  }

  ServerState copyWith({
    String? activeRoot,
    DateTime? updatedAt,
    bool clearActiveRoot = false,
  }) {
    return ServerState(
      activeRoot: clearActiveRoot ? null : (activeRoot ?? this.activeRoot),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'activeRoot': activeRoot,
      'updatedAt': updatedAt?.toUtc().toIso8601String(),
    };
  }
}

class StateRepository {
  StateRepository(this.runtimePaths);

  final RuntimePaths runtimePaths;

  Future<ServerState> load() async {
    final file = File(runtimePaths.stateFilePath);
    if (!await file.exists()) {
      return ServerState.empty();
    }

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw ConfigException('State file must contain a JSON object.');
    }
    return ServerState.fromJson(decoded);
  }

  Future<ServerState> save(ServerState state) async {
    await Directory(runtimePaths.stateDir).create(recursive: true);
    final file = File(runtimePaths.stateFilePath);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(state.toJson()),
    );
    return state;
  }
}

Map<String, Object?> _toPlainMap(YamlMap map) {
  return map.map<String, Object?>((dynamic key, dynamic value) {
    return MapEntry<String, Object?>(key.toString(), _toPlainValue(value));
  });
}

Object? _toPlainValue(Object? value) {
  if (value is YamlMap) {
    return _toPlainMap(value);
  }
  if (value is YamlList) {
    return value.map<Object?>((Object? item) => _toPlainValue(item)).toList();
  }
  return value;
}

Map<String, Object?> _mapValue(Object? value) {
  if (value is Map<Object?, Object?>) {
    return value.map<String, Object?>(
      (Object? key, Object? nestedValue) =>
          MapEntry<String, Object?>(key.toString(), nestedValue),
    );
  }
  return <String, Object?>{};
}

Map<String, Map<String, Object?>> _mapOfMaps(Object? value) {
  final raw = _mapValue(value);
  final mapped = <String, Map<String, Object?>>{};
  for (final entry in raw.entries) {
    mapped[entry.key] = _mapValue(entry.value);
  }
  return mapped;
}

Map<String, String> _stringMap(Map<String, Object?> value) {
  return <String, String>{
    for (final entry in value.entries)
      if (entry.value is String && (entry.value as String).isNotEmpty)
        entry.key: entry.value as String,
  };
}

Map<String, AdapterProviderConfig> _parseProviderConfigs(
  Map<String, Object?> rawProviders,
) {
    final providers = <String, AdapterProviderConfig>{};
  for (final entry in rawProviders.entries) {
    final provider = _mapValue(entry.value);
    final kind = _stringValue(provider['kind']) ?? 'stdio_json';
    final families = _stringList(provider['families']) ?? const <String>[];
    providers[entry.key] = AdapterProviderConfig(
      id: entry.key,
      kind: kind,
      families: families,
      command: _stringValue(provider['command']),
      args: _stringList(provider['args']) ?? const <String>[],
      startupTimeoutMs: _intValue(provider['startupTimeoutMs']) ?? 5000,
      builtin: _boolValue(provider['builtin']) ?? false,
      options: _mapValue(provider['options']),
    );
  }
  return providers;
}

void _ensureNoRemovedAdapterFields(Map<String, Object?> adapters) {
  const removedFields = <String>[
    'delegate',
    'flutterCli',
    'dtd',
    'runtimeDriver',
  ];
  final detected = removedFields
      .where((String field) => adapters.containsKey(field))
      .map((String field) => 'adapters.$field')
      .toList();
  if (detected.isEmpty) {
    return;
  }
  throw ConfigException(
    'Legacy adapter config fields are no longer supported in 0.2.0-stable: '
    '${detected.join(', ')}. '
    'Use adapters.active / adapters.providers instead. '
    'See docs/10-migration-notes.md.',
  );
}

String? _stringValue(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

int? _intValue(Object? value, [String? fieldName]) {
  if (value == null) {
    return null;
  }
  if (value is int) {
    return value;
  }
  throw ConfigException('Expected ${fieldName ?? 'integer'} to be an int.');
}

bool? _boolValue(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is bool) {
    return value;
  }
  throw ConfigException('Expected a boolean value.');
}

List<String>? _stringList(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is List<Object?>) {
    return value
        .whereType<String>()
        .where((String item) => item.isNotEmpty)
        .toList();
  }
  throw ConfigException('Expected a string array.');
}

Map<String, Object?> _applyProfileOverlay(
  Map<String, Object?> root, {
  required Map<String, Map<String, Object?>> profiles,
  required String? selectedProfile,
}) {
  final base = <String, Object?>{
    for (final entry in root.entries)
      if (entry.key != 'profiles') entry.key: _clonePlainValue(entry.value),
  };
  if (selectedProfile == null || selectedProfile.isEmpty) {
    return base;
  }

  final overlay = profiles[selectedProfile];
  if (overlay == null) {
    throw ConfigException('Unknown config profile: $selectedProfile');
  }
  return _deepMergeMaps(base, overlay);
}

Map<String, Object?> _deepMergeMaps(
  Map<String, Object?> base,
  Map<String, Object?> overlay,
) {
  final merged = <String, Object?>{
    for (final entry in base.entries) entry.key: _clonePlainValue(entry.value),
  };
  for (final entry in overlay.entries) {
    final existing = merged[entry.key];
    final incoming = _clonePlainValue(entry.value);
    if (existing is Map<Object?, Object?> && incoming is Map<Object?, Object?>) {
      merged[entry.key] = _deepMergeMaps(
        _mapValue(existing),
        _mapValue(incoming),
      );
      continue;
    }
    merged[entry.key] = incoming;
  }
  return merged;
}

Object? _clonePlainValue(Object? value) {
  if (value is Map<Object?, Object?>) {
    return value.map<String, Object?>(
      (Object? key, Object? nestedValue) => MapEntry<String, Object?>(
        key.toString(),
        _clonePlainValue(nestedValue),
      ),
    );
  }
  if (value is List) {
    return value.map<Object?>((Object? item) => _clonePlainValue(item)).toList();
  }
  return value;
}
