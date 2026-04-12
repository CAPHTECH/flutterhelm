import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/artifacts/resources.dart';
import 'package:path/path.dart' as p;

class ArtifactStore {
  ArtifactStore({required this.stateDir});

  final String stateDir;

  String get _artifactsDir => p.join(stateDir, 'artifacts');

  String sessionArtifactsDir(String sessionId) => p.join(_artifactsDir, 'sessions', sessionId);

  String testRunArtifactsDir(String runId) => p.join(_artifactsDir, 'test-runs', runId);

  String sessionLogUri(String sessionId, String stream) => 'log://$sessionId/$stream';

  String sessionRuntimeErrorsUri(String sessionId) => 'runtime-errors://$sessionId/current';

  String sessionWidgetTreeUri(String sessionId, int depth) =>
      'widget-tree://$sessionId/current?depth=$depth';

  String sessionAppStateUri(String sessionId) => 'app-state://$sessionId/summary';

  String testSummaryUri(String runId) => 'test-report://$runId/summary';

  String testDetailsUri(String runId) => 'test-report://$runId/details';

  String testLogUri(String runId, String stream) => 'log://$runId/$stream';

  Future<void> appendSessionLog({
    required String sessionId,
    required String stream,
    required String line,
  }) async {
    final file = File(p.join(sessionArtifactsDir(sessionId), '$stream.log'));
    await file.parent.create(recursive: true);
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  Future<void> appendSessionMachineEvent({
    required String sessionId,
    required Map<String, Object?> event,
  }) async {
    final file = File(p.join(sessionArtifactsDir(sessionId), 'machine.jsonl'));
    await file.parent.create(recursive: true);
    await file.writeAsString('${jsonEncode(event)}\n', mode: FileMode.append);
  }

  Future<void> writeSessionRuntimeErrors({
    required String sessionId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'runtime-errors-current.json')),
      payload,
    );
  }

  Future<void> writeSessionWidgetTree({
    required String sessionId,
    required int depth,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'widget-tree-depth-$depth.json')),
      payload,
    );
  }

  Future<void> writeSessionAppState({
    required String sessionId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'app-state-summary.json')),
      payload,
    );
  }

  Future<void> writeTestRunSummary({
    required String runId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(File(p.join(testRunArtifactsDir(runId), 'summary.json')), payload);
  }

  Future<void> writeTestRunDetails({
    required String runId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(File(p.join(testRunArtifactsDir(runId), 'details.json')), payload);
  }

  Future<void> appendTestRunLog({
    required String runId,
    required String stream,
    required String line,
  }) async {
    final file = File(p.join(testRunArtifactsDir(runId), '$stream.log'));
    await file.parent.create(recursive: true);
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  Future<ResourceReadResult?> readStoredResource(String uri) async {
    final resolved = _resolveFile(uri);
    if (resolved == null) {
      return null;
    }
    final file = File(resolved.path);
    if (!await file.exists()) {
      return null;
    }
    return ResourceReadResult(
      uri: uri,
      mimeType: resolved.mimeType,
      text: await file.readAsString(),
    );
  }

  Future<List<ResourceDescriptor>> listSessionResources(String sessionId) async {
    final dir = Directory(sessionArtifactsDir(sessionId));
    if (!await dir.exists()) {
      return const <ResourceDescriptor>[];
    }
    final resources = <ResourceDescriptor>[];
    final stdoutFile = File(p.join(dir.path, 'stdout.log'));
    if (await stdoutFile.exists()) {
      resources.add(await _descriptorForFile(
        file: stdoutFile,
        uri: sessionLogUri(sessionId, 'stdout'),
        name: 'session.stdout.$sessionId',
        title: 'Session stdout $sessionId',
        description: 'Collected stdout lines for the session.',
        mimeType: 'text/plain',
      ));
    }
    final stderrFile = File(p.join(dir.path, 'stderr.log'));
    if (await stderrFile.exists()) {
      resources.add(await _descriptorForFile(
        file: stderrFile,
        uri: sessionLogUri(sessionId, 'stderr'),
        name: 'session.stderr.$sessionId',
        title: 'Session stderr $sessionId',
        description: 'Collected stderr lines for the session.',
        mimeType: 'text/plain',
      ));
    }
    final runtimeErrors = File(p.join(dir.path, 'runtime-errors-current.json'));
    if (await runtimeErrors.exists()) {
      resources.add(await _descriptorForFile(
        file: runtimeErrors,
        uri: sessionRuntimeErrorsUri(sessionId),
        name: 'session.runtimeErrors.$sessionId',
        title: 'Runtime errors $sessionId',
        description: 'Current structured runtime errors.',
        mimeType: 'application/json',
      ));
    }
    final appState = File(p.join(dir.path, 'app-state-summary.json'));
    if (await appState.exists()) {
      resources.add(await _descriptorForFile(
        file: appState,
        uri: sessionAppStateUri(sessionId),
        name: 'session.appState.$sessionId',
        title: 'App state $sessionId',
        description: 'High-level session state summary.',
        mimeType: 'application/json',
      ));
    }
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final match = RegExp(r'widget-tree-depth-(\d+)\.json$').firstMatch(entity.path);
      if (match == null) {
        continue;
      }
      final depth = int.parse(match.group(1)!);
      resources.add(await _descriptorForFile(
        file: entity,
        uri: sessionWidgetTreeUri(sessionId, depth),
        name: 'session.widgetTree.$sessionId.$depth',
        title: 'Widget tree $sessionId depth=$depth',
        description: 'Captured widget tree snapshot.',
        mimeType: 'application/json',
      ));
    }
    resources.sort((left, right) => left.uri.compareTo(right.uri));
    return resources;
  }

  Future<List<ResourceDescriptor>> listTestRunResources() async {
    final dir = Directory(p.join(_artifactsDir, 'test-runs'));
    if (!await dir.exists()) {
      return const <ResourceDescriptor>[];
    }
    final resources = <ResourceDescriptor>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) {
        continue;
      }
      final runId = p.basename(entity.path);
      final summary = File(p.join(entity.path, 'summary.json'));
      if (await summary.exists()) {
        resources.add(await _descriptorForFile(
          file: summary,
          uri: testSummaryUri(runId),
          name: 'test.summary.$runId',
          title: 'Test summary $runId',
          description: 'Summary of a test run.',
          mimeType: 'application/json',
        ));
      }
      final details = File(p.join(entity.path, 'details.json'));
      if (await details.exists()) {
        resources.add(await _descriptorForFile(
          file: details,
          uri: testDetailsUri(runId),
          name: 'test.details.$runId',
          title: 'Test details $runId',
          description: 'Detailed machine-readable test output.',
          mimeType: 'application/json',
        ));
      }
      final stdout = File(p.join(entity.path, 'stdout.log'));
      if (await stdout.exists()) {
        resources.add(await _descriptorForFile(
          file: stdout,
          uri: testLogUri(runId, 'stdout'),
          name: 'test.stdout.$runId',
          title: 'Test stdout $runId',
          description: 'stdout from the test run.',
          mimeType: 'text/plain',
        ));
      }
      final stderr = File(p.join(entity.path, 'stderr.log'));
      if (await stderr.exists()) {
        resources.add(await _descriptorForFile(
          file: stderr,
          uri: testLogUri(runId, 'stderr'),
          name: 'test.stderr.$runId',
          title: 'Test stderr $runId',
          description: 'stderr from the test run.',
          mimeType: 'text/plain',
        ));
      }
    }
    resources.sort((left, right) => left.uri.compareTo(right.uri));
    return resources;
  }

  Future<void> _writeJson(File file, Map<String, Object?> payload) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
  }

  Future<ResourceDescriptor> _descriptorForFile({
    required File file,
    required String uri,
    required String name,
    required String title,
    required String description,
    required String mimeType,
  }) async {
    final stat = await file.stat();
    return ResourceDescriptor(
      uri: uri,
      name: name,
      title: title,
      description: description,
      mimeType: mimeType,
      lastModified: stat.modified.toUtc(),
      size: stat.size,
    );
  }

  _ResolvedStoredFile? _resolveFile(String uri) {
    final logMatch = RegExp(r'^log://([^/]+)/(stdout|stderr)$').firstMatch(uri);
    if (logMatch != null) {
      final id = logMatch.group(1)!;
      final stream = logMatch.group(2)!;
      final sessionFile = File(p.join(sessionArtifactsDir(id), '$stream.log'));
      if (sessionFile.existsSync()) {
        return _ResolvedStoredFile(path: sessionFile.path, mimeType: 'text/plain');
      }
      final testFile = File(p.join(testRunArtifactsDir(id), '$stream.log'));
      return _ResolvedStoredFile(path: testFile.path, mimeType: 'text/plain');
    }

    final runtimeMatch = RegExp(r'^runtime-errors://([^/]+)/current$').firstMatch(uri);
    if (runtimeMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(sessionArtifactsDir(runtimeMatch.group(1)!), 'runtime-errors-current.json'),
        mimeType: 'application/json',
      );
    }

    final appStateMatch = RegExp(r'^app-state://([^/]+)/summary$').firstMatch(uri);
    if (appStateMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(sessionArtifactsDir(appStateMatch.group(1)!), 'app-state-summary.json'),
        mimeType: 'application/json',
      );
    }

    final widgetTreeMatch = RegExp(r'^widget-tree://([^/]+)/current(?:\?.*)?$').firstMatch(uri);
    if (widgetTreeMatch != null) {
      final depth = Uri.parse(uri).queryParameters['depth'] ?? '3';
      return _ResolvedStoredFile(
        path: p.join(sessionArtifactsDir(widgetTreeMatch.group(1)!), 'widget-tree-depth-$depth.json'),
        mimeType: 'application/json',
      );
    }

    final testMatch = RegExp(r'^test-report://([^/]+)/(summary|details)$').firstMatch(uri);
    if (testMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(testRunArtifactsDir(testMatch.group(1)!), '${testMatch.group(2)}.json'),
        mimeType: 'application/json',
      );
    }

    return null;
  }
}

class _ResolvedStoredFile {
  const _ResolvedStoredFile({required this.path, required this.mimeType});

  final String path;
  final String mimeType;
}
