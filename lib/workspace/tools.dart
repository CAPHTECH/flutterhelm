import 'dart:io';

import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class WorkspaceToolService {
  WorkspaceToolService({required this.processRunner, required this.flutterExecutable});

  final ProcessRunner processRunner;
  final String flutterExecutable;

  Future<List<Map<String, Object?>>> discoverWorkspaces({
    required List<String> roots,
  }) async {
    final seen = <String>{};
    final results = <Map<String, Object?>>[];
    for (final root in roots) {
      final directory = Directory(root);
      if (!await directory.exists()) {
        continue;
      }
      await for (final entity in directory.list(recursive: true, followLinks: false)) {
        if (entity is! File || p.basename(entity.path) != 'pubspec.yaml') {
          continue;
        }
        final workspaceRoot = p.dirname(entity.path);
        if (!seen.add(workspaceRoot)) {
          continue;
        }
        final pubspec = await _loadPubspec(entity);
        if (!_isFlutterWorkspace(pubspec)) {
          continue;
        }
        results.add(<String, Object?>{
          'workspaceRoot': workspaceRoot,
          'name': pubspec['name'] as String? ?? p.basename(workspaceRoot),
          'target': 'lib/main.dart',
        });
      }
    }
    results.sort((left, right) =>
        (left['workspaceRoot'] as String).compareTo(right['workspaceRoot'] as String));
    return results;
  }

  Future<Map<String, Object?>> analyzeProject({
    required String workspaceRoot,
    bool fatalInfos = false,
    bool fatalWarnings = true,
  }) async {
    final arguments = <String>[
      'analyze',
      if (fatalInfos) '--fatal-infos',
      if (!fatalWarnings) '--no-fatal-warnings',
      '--no-preamble',
      '--no-congratulate',
    ];
    final result = await processRunner.run(
      flutterExecutable,
      arguments,
      workingDirectory: workspaceRoot,
      timeout: const Duration(minutes: 5),
    );
    final issueLines = result.stdout
        .split('\n')
        .where((String line) => line.contains('•') || line.contains(' info • '))
        .toList();
    return <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'exitCode': result.exitCode,
      'issueCount': issueLines.length,
      'durationMs': result.duration.inMilliseconds,
      'status': result.exitCode == 0 ? 'ok' : 'issues_found',
      'stdout': result.stdout,
      'stderr': result.stderr,
    };
  }

  Future<Map<String, Object?>> formatFiles({
    required String workspaceRoot,
    required List<String> paths,
    int? lineLength,
  }) async {
    if (paths.isEmpty) {
      throw FlutterHelmToolError(
        code: 'FORMAT_PATHS_REQUIRED',
        category: 'validation',
        message: 'format_files requires at least one path.',
        retryable: true,
      );
    }
    final resolvedPaths = <String>[
      for (final path in paths)
        p.isAbsolute(path) ? path : p.join(workspaceRoot, path),
    ];
    for (final resolvedPath in resolvedPaths) {
      if (!(resolvedPath == workspaceRoot || p.isWithin(workspaceRoot, resolvedPath))) {
        throw FlutterHelmToolError(
          code: 'ROOTS_MISMATCH',
          category: 'roots',
          message: 'format_files path is outside the active workspace root.',
          retryable: false,
        );
      }
    }
    final arguments = <String>[
      'format',
      if (lineLength != null) '--line-length=$lineLength',
      ...resolvedPaths,
    ];
    final result = await processRunner.run(
      Platform.resolvedExecutable,
      arguments,
      workingDirectory: workspaceRoot,
      timeout: const Duration(minutes: 2),
    );
    return <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'paths': resolvedPaths,
      'exitCode': result.exitCode,
      'durationMs': result.duration.inMilliseconds,
      'stdout': result.stdout,
      'stderr': result.stderr,
    };
  }

  Future<Map<String, Object?>> resolveSymbol({
    required String workspaceRoot,
    required String symbol,
  }) async {
    final matches = <Map<String, Object?>>[];
    await for (final entity in Directory(workspaceRoot).list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final lines = await entity.readAsLines();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        final trimmed = line.trimLeft();
        if (_looksLikeSymbolDefinition(trimmed, symbol)) {
          matches.add(<String, Object?>{
            'symbol': symbol,
            'path': entity.path,
            'line': index + 1,
            'column': line.indexOf(symbol) + 1,
            'snippet': trimmed,
          });
        }
      }
    }
    return <String, Object?>{
      'symbol': symbol,
      'matches': matches,
      'resolved': matches.isNotEmpty,
    };
  }

  Future<Map<String, Object?>> _loadPubspec(File file) async {
    final document = loadYaml(await file.readAsString());
    if (document is! YamlMap) {
      return <String, Object?>{};
    }
    return document.map<String, Object?>(
      (dynamic key, dynamic value) => MapEntry<String, Object?>(key.toString(), value),
    );
  }

  bool _isFlutterWorkspace(Map<String, Object?> pubspec) {
    if (pubspec['flutter'] != null) {
      return true;
    }
    final dependencies = pubspec['dependencies'];
    if (dependencies is YamlMap) {
      return dependencies.containsKey('flutter');
    }
    return false;
  }

  bool _looksLikeSymbolDefinition(String line, String symbol) {
    final candidates = <Pattern>[
      'class $symbol',
      'enum $symbol',
      'mixin $symbol',
      'extension $symbol',
      'typedef $symbol',
      'void $symbol(',
      'Future $symbol(',
      'Future<$symbol>',
      'Widget $symbol(',
      'final $symbol =',
    ];
    for (final candidate in candidates) {
      if (line.contains(candidate)) {
        return true;
      }
    }
    return RegExp('\\b${RegExp.escape(symbol)}\\s*\\(').hasMatch(line) && line.contains('{');
  }
}
