import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/adapters/registry.dart';
import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class WorkspaceToolService {
  WorkspaceToolService({
    required this.processRunner,
    required this.artifactStore,
    required this.flutterExecutable,
    this.delegateAdapterFactory,
  });

  final ProcessRunner processRunner;
  final ArtifactStore artifactStore;
  final String flutterExecutable;
  final Future<DelegateAdapter> Function()? delegateAdapterFactory;

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
    final delegateResult = await _tryDelegate<Map<String, Object?>>(
      (DelegateAdapter adapter) => adapter.analyzeProject(
        workspaceRoot: workspaceRoot,
        fatalInfos: fatalInfos,
        fatalWarnings: fatalWarnings,
      ),
    );
    if (delegateResult != null) {
      return delegateResult;
    }
    return _analyzeProjectWithFlutterCli(
      workspaceRoot: workspaceRoot,
      fatalInfos: fatalInfos,
      fatalWarnings: fatalWarnings,
    );
  }

  Future<Map<String, Object?>> _analyzeProjectWithFlutterCli({
    required String workspaceRoot,
    required bool fatalInfos,
    required bool fatalWarnings,
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

  Future<Map<String, Object?>> pubSearch({
    required String query,
    int limit = 10,
  }) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      throw FlutterHelmToolError(
        code: 'PUB_QUERY_REQUIRED',
        category: 'validation',
        message: 'pub_search requires a non-empty query.',
        retryable: true,
      );
    }
    final delegateResult = await _tryDelegate<Map<String, Object?>>(
      (DelegateAdapter adapter) => adapter.pubSearch(
        query: trimmedQuery,
        limit: limit,
      ),
    );
    if (delegateResult != null) {
      return delegateResult;
    }
    return _pubSearchViaHttp(query: trimmedQuery, limit: limit);
  }

  Future<Map<String, Object?>> _pubSearchViaHttp({
    required String query,
    required int limit,
  }) async {
    final effectiveLimit = limit.clamp(1, 20).toInt();
    final client = HttpClient();
    try {
      final searchUri = Uri.https('pub.dev', '/api/search', <String, String>{
        'q': query,
      });
      final searchResponse = await _getJson(client, searchUri);
      final rawPackages = searchResponse['packages'];
      if (rawPackages is! List) {
        throw FlutterHelmToolError(
          code: 'PUB_SEARCH_FAILED',
          category: 'network',
          message: 'pub.dev returned an unexpected search response.',
          retryable: true,
        );
      }
      final packageNames = rawPackages
          .map((Object? item) => item is Map ? item['package'] : null)
          .whereType<String>()
          .take(effectiveLimit)
          .toList();
      final packages = await Future.wait(
        packageNames.map((String package) => _fetchPackageDetails(client, package)),
      );
      return <String, Object?>{
        'query': query,
        'packages': packages,
      };
    } on SocketException catch (error) {
      throw FlutterHelmToolError(
        code: 'PUB_SEARCH_FAILED',
        category: 'network',
        message: 'pub_search failed: ${error.message}',
        retryable: true,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> dependencyAdd({
    required String workspaceRoot,
    required String package,
    required String? versionConstraint,
    required bool devDependency,
  }) async {
    final changeId = _nextChangeId('add');
    final beforeManifest = await _readPubspecText(workspaceRoot);
    await artifactStore.writeMutationSnapshot(
      changeId: changeId,
      label: 'before',
      contents: beforeManifest,
    );

    final descriptorPrefix = devDependency ? 'dev:' : '';
    final descriptor = versionConstraint == null || versionConstraint.isEmpty
        ? '$descriptorPrefix$package'
        : '$descriptorPrefix$package:$versionConstraint';
    final delegateResult = await _tryDelegate<Map<String, Object?>>(
      (DelegateAdapter adapter) => adapter.dependencyAdd(
        workspaceRoot: workspaceRoot,
        package: package,
        versionConstraint: versionConstraint,
        devDependency: devDependency,
      ),
    );
    final result = delegateResult == null
        ? await processRunner.run(
            flutterExecutable,
            <String>['pub', 'add', descriptor],
            workingDirectory: workspaceRoot,
            timeout: const Duration(minutes: 3),
          )
        : ProcessRunResult(
            exitCode: _intValue(delegateResult['exitCode']) ?? 0,
            stdout: delegateResult['stdout'] as String? ?? '',
            stderr: delegateResult['stderr'] as String? ?? '',
            duration: Duration(
              milliseconds: _intValue(delegateResult['durationMs']) ?? 0,
            ),
          );
    await _writeMutationLogs(
      changeId: changeId,
      stdout: result.stdout,
      stderr: result.stderr,
    );

    final afterManifest = await _readPubspecText(workspaceRoot);
    await artifactStore.writeMutationSnapshot(
      changeId: changeId,
      label: 'after',
      contents: afterManifest,
    );

    final beforeSummary = await _dependencySummary(workspaceRoot, yamlText: beforeManifest);
    final afterSummary = await _dependencySummary(workspaceRoot, yamlText: afterManifest);
    final status = result.exitCode == 0 ? 'completed' : 'failed';
    final payload = <String, Object?>{
      'changeId': changeId,
      'action': 'add',
      'workspaceRoot': workspaceRoot,
      'package': package,
      'status': status,
      'exitCode': result.exitCode,
      'section': devDependency ? 'dev_dependencies' : 'dependencies',
      'before': beforeSummary,
      'after': afterSummary,
    };
    await artifactStore.writeMutationSummary(changeId: changeId, payload: payload);
    if (result.exitCode != 0) {
      throw FlutterHelmToolError(
        code: 'DEPENDENCY_ADD_FAILED',
        category: 'workspace',
        message: result.stderr.trim().isEmpty ? 'flutter pub add failed.' : result.stderr.trim(),
        retryable: true,
        detailsResource: <String, Object?>{
          'uri': artifactStore.mutationLogUri(changeId, 'stderr'),
          'mimeType': 'text/plain',
        },
      );
    }
    return <String, Object?>{
      ...payload,
      'resources': <Map<String, Object?>>[
        <String, Object?>{
          'uri': artifactStore.mutationLogUri(changeId, 'stdout'),
          'mimeType': 'text/plain',
          'title': 'Dependency mutation stdout',
        },
        <String, Object?>{
          'uri': artifactStore.mutationLogUri(changeId, 'stderr'),
          'mimeType': 'text/plain',
          'title': 'Dependency mutation stderr',
        },
      ],
      'dependency': _resolvePackageSummary(afterSummary, package, devDependency: devDependency),
    };
  }

  Future<Map<String, Object?>> dependencyRemove({
    required String workspaceRoot,
    required String package,
  }) async {
    final changeId = _nextChangeId('remove');
    final beforeManifest = await _readPubspecText(workspaceRoot);
    await artifactStore.writeMutationSnapshot(
      changeId: changeId,
      label: 'before',
      contents: beforeManifest,
    );

    final delegateResult = await _tryDelegate<Map<String, Object?>>(
      (DelegateAdapter adapter) => adapter.dependencyRemove(
        workspaceRoot: workspaceRoot,
        package: package,
      ),
    );
    final result = delegateResult == null
        ? await processRunner.run(
            flutterExecutable,
            <String>['pub', 'remove', package],
            workingDirectory: workspaceRoot,
            timeout: const Duration(minutes: 3),
          )
        : ProcessRunResult(
            exitCode: _intValue(delegateResult['exitCode']) ?? 0,
            stdout: delegateResult['stdout'] as String? ?? '',
            stderr: delegateResult['stderr'] as String? ?? '',
            duration: Duration(
              milliseconds: _intValue(delegateResult['durationMs']) ?? 0,
            ),
          );
    await _writeMutationLogs(
      changeId: changeId,
      stdout: result.stdout,
      stderr: result.stderr,
    );

    final afterManifest = await _readPubspecText(workspaceRoot);
    await artifactStore.writeMutationSnapshot(
      changeId: changeId,
      label: 'after',
      contents: afterManifest,
    );

    final beforeSummary = await _dependencySummary(workspaceRoot, yamlText: beforeManifest);
    final afterSummary = await _dependencySummary(workspaceRoot, yamlText: afterManifest);
    final removedFrom = _removedSection(beforeSummary, afterSummary, package);
    final status = result.exitCode == 0 ? 'completed' : 'failed';
    final payload = <String, Object?>{
      'changeId': changeId,
      'action': 'remove',
      'workspaceRoot': workspaceRoot,
      'package': package,
      'status': status,
      'exitCode': result.exitCode,
      'removedFrom': removedFrom,
      'before': beforeSummary,
      'after': afterSummary,
    };
    await artifactStore.writeMutationSummary(changeId: changeId, payload: payload);
    if (result.exitCode != 0) {
      throw FlutterHelmToolError(
        code: 'DEPENDENCY_REMOVE_FAILED',
        category: 'workspace',
        message: result.stderr.trim().isEmpty ? 'flutter pub remove failed.' : result.stderr.trim(),
        retryable: true,
        detailsResource: <String, Object?>{
          'uri': artifactStore.mutationLogUri(changeId, 'stderr'),
          'mimeType': 'text/plain',
        },
      );
    }
    return <String, Object?>{
      ...payload,
      'resources': <Map<String, Object?>>[
        <String, Object?>{
          'uri': artifactStore.mutationLogUri(changeId, 'stdout'),
          'mimeType': 'text/plain',
          'title': 'Dependency mutation stdout',
        },
        <String, Object?>{
          'uri': artifactStore.mutationLogUri(changeId, 'stderr'),
          'mimeType': 'text/plain',
          'title': 'Dependency mutation stderr',
        },
      ],
    };
  }

  Future<Map<String, Object?>> resolveSymbol({
    required String workspaceRoot,
    required String symbol,
  }) async {
    final delegateResult = await _tryDelegate<Map<String, Object?>>(
      (DelegateAdapter adapter) => adapter.resolveSymbol(
        workspaceRoot: workspaceRoot,
        symbol: symbol,
      ),
    );
    if (delegateResult != null) {
      return delegateResult;
    }
    return _resolveSymbolLocally(
      workspaceRoot: workspaceRoot,
      symbol: symbol,
    );
  }

  Future<Map<String, Object?>> _resolveSymbolLocally({
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

  Future<T?> _tryDelegate<T>(
    Future<T> Function(DelegateAdapter adapter) action,
  ) async {
    final factory = delegateAdapterFactory;
    if (factory == null) {
      return null;
    }
    try {
      final adapter = await factory();
      final health = await adapter.health();
      if (!health.connected) {
        return null;
      }
      return await action(adapter);
    } on Object {
      return null;
    }
  }

  Future<Map<String, Object?>> _loadPubspec(File file) async {
    final document = loadYaml(await file.readAsString());
    if (document is! YamlMap) {
      return <String, Object?>{};
    }
    return _plainMap(document);
  }

  bool _isFlutterWorkspace(Map<String, Object?> pubspec) {
    if (pubspec['flutter'] != null) {
      return true;
    }
    final dependencies = pubspec['dependencies'];
    if (dependencies is Map) {
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

  Future<Map<String, Object?>> _getJson(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FlutterHelmToolError(
        code: 'PUB_SEARCH_FAILED',
        category: 'network',
        message: 'pub.dev request failed with status ${response.statusCode}.',
        retryable: true,
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map<String, Object?>(
        (Object? key, Object? value) => MapEntry<String, Object?>(key.toString(), value),
      );
    }
    throw FlutterHelmToolError(
      code: 'PUB_SEARCH_FAILED',
      category: 'network',
      message: 'pub.dev returned malformed JSON.',
      retryable: true,
    );
  }

  Future<Map<String, Object?>> _fetchPackageDetails(
    HttpClient client,
    String package,
  ) async {
    final response = await _getJson(
      client,
      Uri.https('pub.dev', '/api/packages/$package'),
    );
    final latest = _mapValue(response['latest']);
    final pubspec = _mapValue(latest['pubspec']);
    return <String, Object?>{
      'package': package,
      'latestVersion': latest['version'],
      'description': pubspec['description'] as String? ?? '',
      'url': 'https://pub.dev/packages/$package',
      if (response['publisherId'] is String) 'publisher': response['publisherId'],
      if (latest['published'] is String) 'publishedAt': latest['published'],
    };
  }

  Future<String> _readPubspecText(String workspaceRoot) {
    return File(p.join(workspaceRoot, 'pubspec.yaml')).readAsString();
  }

  Future<Map<String, Object?>> _dependencySummary(
    String workspaceRoot, {
    String? yamlText,
  }) async {
    final document = loadYaml(yamlText ?? await _readPubspecText(workspaceRoot));
    if (document is! YamlMap) {
      return const <String, Object?>{
        'dependencies': <String, Object?>{},
        'devDependencies': <String, Object?>{},
      };
    }
    final pubspec = _plainMap(document);
    return <String, Object?>{
      'dependencies': _stringifyDependencySection(pubspec['dependencies']),
      'devDependencies': _stringifyDependencySection(pubspec['dev_dependencies']),
    };
  }

  Map<String, Object?> _stringifyDependencySection(Object? section) {
    final plain = _mapValue(section);
    final sortedKeys = plain.keys.toList()..sort();
    return <String, Object?>{
      for (final key in sortedKeys) key: _stringifyDependencyValue(plain[key]),
    };
  }

  Object? _stringifyDependencyValue(Object? value) {
    if (value is Map<Object?, Object?>) {
      return value.map<String, Object?>(
        (Object? key, Object? nestedValue) =>
            MapEntry<String, Object?>(key.toString(), _stringifyDependencyValue(nestedValue)),
      );
    }
    if (value is YamlMap) {
      return _stringifyDependencyValue(_plainMap(value));
    }
    if (value is YamlList) {
      return value.map<Object?>((Object? item) => _stringifyDependencyValue(item)).toList();
    }
    return value;
  }

  Map<String, Object?>? _resolvePackageSummary(
    Map<String, Object?> dependencySummary,
    String package, {
    required bool devDependency,
  }) {
    final section = devDependency ? 'devDependencies' : 'dependencies';
    final values = _mapValue(dependencySummary[section]);
    if (!values.containsKey(package)) {
      return null;
    }
    return <String, Object?>{
      'name': package,
      'section': devDependency ? 'dev_dependencies' : 'dependencies',
      'constraint': values[package],
    };
  }

  String? _removedSection(
    Map<String, Object?> beforeSummary,
    Map<String, Object?> afterSummary,
    String package,
  ) {
    final beforeDependencies = _mapValue(beforeSummary['dependencies']);
    final afterDependencies = _mapValue(afterSummary['dependencies']);
    if (beforeDependencies.containsKey(package) && !afterDependencies.containsKey(package)) {
      return 'dependencies';
    }
    final beforeDevDependencies = _mapValue(beforeSummary['devDependencies']);
    final afterDevDependencies = _mapValue(afterSummary['devDependencies']);
    if (beforeDevDependencies.containsKey(package) &&
        !afterDevDependencies.containsKey(package)) {
      return 'dev_dependencies';
    }
    return null;
  }

  Future<void> _writeMutationLogs({
    required String changeId,
    required String stdout,
    required String stderr,
  }) async {
    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      await artifactStore.appendMutationLog(
        changeId: changeId,
        stream: 'stdout',
        line: line,
      );
    }
    for (final line in stderr.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      await artifactStore.appendMutationLog(
        changeId: changeId,
        stream: 'stderr',
        line: line,
      );
    }
  }

  String _nextChangeId(String action) {
    final now = DateTime.now().toUtc();
    return 'mut_${now.microsecondsSinceEpoch.toRadixString(36)}_${action.substring(0, 1)}';
  }

  Map<String, Object?> _plainMap(YamlMap map) {
    return map.map<String, Object?>(
      (dynamic key, dynamic value) => MapEntry<String, Object?>(key.toString(), _plainValue(value)),
    );
  }

  Object? _plainValue(Object? value) {
    if (value is YamlMap) {
      return _plainMap(value);
    }
    if (value is YamlList) {
      return value.map<Object?>((Object? item) => _plainValue(item)).toList();
    }
    return value;
  }

  Map<String, Object?> _mapValue(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? nestedValue) =>
            MapEntry<String, Object?>(key.toString(), nestedValue),
      );
    }
    return <String, Object?>{};
  }

  int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
  }
}
