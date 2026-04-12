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
  });

  final int heavyArtifactsDays;
  final int metadataDays;

  Map<String, Object?> toJson() => <String, Object?>{
    'heavyArtifactsDays': heavyArtifactsDays,
    'metadataDays': metadataDays,
  };
}

class SafetyConfig {
  const SafetyConfig({required this.confirmBefore});

  final List<String> confirmBefore;

  Map<String, Object?> toJson() => <String, Object?>{
    'confirmBefore': confirmBefore,
  };
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
  });

  final String delegateType;
  final String flutterExecutable;
  final bool dtdEnabled;
  final bool runtimeDriverEnabled;
  final String runtimeDriverCommand;
  final List<String> runtimeDriverArgs;
  final int runtimeDriverStartupTimeoutMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'delegate': <String, Object?>{'type': delegateType},
    'flutterCli': <String, Object?>{'executable': flutterExecutable},
    'dtd': <String, Object?>{'enabled': dtdEnabled},
    'runtimeDriver': <String, Object?>{
      'enabled': runtimeDriverEnabled,
      'command': runtimeDriverCommand,
      'args': runtimeDriverArgs,
      'startupTimeoutMs': runtimeDriverStartupTimeoutMs,
    },
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
  });

  final int version;
  final WorkspaceConfig workspace;
  final DefaultsConfig defaults;
  final List<String> enabledWorkflows;
  final FallbacksConfig fallbacks;
  final RetentionConfig retention;
  final SafetyConfig safety;
  final AdaptersConfig adapters;

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
    return const FlutterHelmConfig(
      version: 1,
      workspace: WorkspaceConfig(roots: <String>[]),
      defaults: DefaultsConfig(target: 'lib/main.dart', mode: 'debug'),
      enabledWorkflows: defaultWorkflows,
      fallbacks: FallbacksConfig(allowRootFallback: false),
      retention: RetentionConfig(heavyArtifactsDays: 7, metadataDays: 30),
      safety: SafetyConfig(
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
      ),
    );
  }

  factory FlutterHelmConfig.fromYamlText(String yamlText) {
    final document = loadYaml(yamlText);
    if (document == null) {
      return FlutterHelmConfig.defaults();
    }
    if (document is! YamlMap) {
      throw ConfigException('Config root must be a YAML object.');
    }

    final root = _toPlainMap(document);
    final version = _intValue(root['version'], 'version') ?? 1;
    if (version != 1) {
      throw ConfigException('Unsupported config version: $version');
    }

    final workspace = _mapValue(root['workspace']);
    final defaults = _mapValue(root['defaults']);
    final fallbacks = _mapValue(root['fallbacks']);
    final retention = _mapValue(root['retention']);
    final safety = _mapValue(root['safety']);
    final adapters = _mapValue(root['adapters']);

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
          _stringList(root['enabledWorkflows']) ?? defaultWorkflows,
      fallbacks: FallbacksConfig(
        allowRootFallback: _boolValue(fallbacks['allowRootFallback']) ?? false,
      ),
      retention: RetentionConfig(
        heavyArtifactsDays: _intValue(retention['heavyArtifactsDays']) ?? 7,
        metadataDays: _intValue(retention['metadataDays']) ?? 30,
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
        delegateType:
            _stringValue(_mapValue(adapters['delegate'])['type']) ??
            'dart_flutter_mcp',
        flutterExecutable:
            _stringValue(_mapValue(adapters['flutterCli'])['executable']) ??
            'flutter',
        dtdEnabled: _boolValue(_mapValue(adapters['dtd'])['enabled']) ?? true,
        runtimeDriverEnabled:
            _boolValue(_mapValue(adapters['runtimeDriver'])['enabled']) ??
            false,
        runtimeDriverCommand:
            _stringValue(_mapValue(adapters['runtimeDriver'])['command']) ??
            'npx',
        runtimeDriverArgs:
            _stringList(_mapValue(adapters['runtimeDriver'])['args']) ??
            const <String>[
              '-y',
              '@mobilenext/mobile-mcp@latest',
              '--stdio',
            ],
        runtimeDriverStartupTimeoutMs:
            _intValue(_mapValue(adapters['runtimeDriver'])['startupTimeoutMs']) ??
            5000,
      ),
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
    };
  }
}

class ConfigRepository {
  ConfigRepository(this.runtimePaths);

  final RuntimePaths runtimePaths;

  Future<FlutterHelmConfig> load() async {
    final file = File(runtimePaths.configPath);
    if (!await file.exists()) {
      return FlutterHelmConfig.defaults();
    }

    final yamlText = await file.readAsString();
    return FlutterHelmConfig.fromYamlText(yamlText);
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
