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

  String mutationArtifactsDir(String changeId) => p.join(_artifactsDir, 'mutations', changeId);

  String sessionLogUri(String sessionId, String stream) => 'log://$sessionId/$stream';

  String sessionSummaryUri(String sessionId) => 'session://$sessionId/summary';

  String sessionHealthUri(String sessionId) => 'session://$sessionId/health';

  String sessionRuntimeErrorsUri(String sessionId) => 'runtime-errors://$sessionId/current';

  String sessionWidgetTreeUri(String sessionId, int depth) =>
      'widget-tree://$sessionId/current?depth=$depth';

  String sessionAppStateUri(String sessionId) => 'app-state://$sessionId/summary';

  String sessionCpuProfileUri(String sessionId, String captureId) =>
      'cpu://$sessionId/$captureId';

  String sessionTimelineUri(String sessionId, String captureId) =>
      'timeline://$sessionId/$captureId';

  String sessionMemoryUri(String sessionId, String snapshotId) =>
      'memory://$sessionId/$snapshotId';

  String sessionNativeHandoffUri(String sessionId, String platform) =>
      'native-handoff://$sessionId/$platform';

  String testSummaryUri(String runId) => 'test-report://$runId/summary';

  String testDetailsUri(String runId) => 'test-report://$runId/details';

  String testLogUri(String runId, String stream) => 'log://$runId/$stream';

  String mutationLogUri(String changeId, String stream) => 'log://$changeId/$stream';

  String coverageSummaryUri(String runId) => 'coverage://$runId/summary';

  String coverageLcovUri(String runId) => 'coverage://$runId/lcov';

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

  Future<void> writeSessionCpuProfile({
    required String sessionId,
    required String captureId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'cpu-profile-$captureId.json')),
      payload,
    );
  }

  Future<void> writeSessionTimeline({
    required String sessionId,
    required String captureId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'timeline-$captureId.json')),
      payload,
    );
  }

  Future<void> writeSessionMemorySnapshot({
    required String sessionId,
    required String snapshotId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'memory-$snapshotId.json')),
      payload,
    );
  }

  Future<void> writeSessionHeapSnapshotSidecar({
    required String sessionId,
    required String snapshotId,
    required List<List<int>> chunks,
  }) async {
    final file = File(p.join(sessionArtifactsDir(sessionId), 'memory-$snapshotId.heap'));
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      for (final chunk in chunks) {
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
  }

  Future<void> writeSessionNativeHandoff({
    required String sessionId,
    required String platform,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(sessionArtifactsDir(sessionId), 'native-handoff-$platform.json')),
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

  Future<void> writeCoverageSummary({
    required String runId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(testRunArtifactsDir(runId), 'coverage-summary.json')),
      payload,
    );
  }

  Future<void> writeCoverageLcov({
    required String runId,
    required String contents,
  }) async {
    final file = File(p.join(testRunArtifactsDir(runId), 'coverage.lcov'));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> writeMutationSnapshot({
    required String changeId,
    required String label,
    required String contents,
  }) async {
    final file = File(p.join(mutationArtifactsDir(changeId), '$label.pubspec.yaml'));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> writeMutationSummary({
    required String changeId,
    required Map<String, Object?> payload,
  }) {
    return _writeJson(
      File(p.join(mutationArtifactsDir(changeId), 'summary.json')),
      payload,
    );
  }

  Future<void> appendMutationLog({
    required String changeId,
    required String stream,
    required String line,
  }) async {
    final file = File(p.join(mutationArtifactsDir(changeId), '$stream.log'));
    await file.parent.create(recursive: true);
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  Future<Map<String, Object?>?> readTestRunSummary(String runId) {
    return _readJson(File(p.join(testRunArtifactsDir(runId), 'summary.json')));
  }

  Future<Map<String, Object?>?> readTestRunDetails(String runId) {
    return _readJson(File(p.join(testRunArtifactsDir(runId), 'details.json')));
  }

  Future<Map<String, Object?>?> readCoverageSummary(String runId) {
    return _readJson(File(p.join(testRunArtifactsDir(runId), 'coverage-summary.json')));
  }

  Future<String?> readCoverageLcov(String runId) {
    return _readText(File(p.join(testRunArtifactsDir(runId), 'coverage.lcov')));
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
        sessionId: sessionId,
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
        sessionId: sessionId,
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
        sessionId: sessionId,
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
        sessionId: sessionId,
      ));
    }
    await for (final entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      final widgetTreeMatch = RegExp(r'widget-tree-depth-(\d+)\.json$').firstMatch(entity.path);
      if (widgetTreeMatch != null) {
        final depth = int.parse(widgetTreeMatch.group(1)!);
        resources.add(await _descriptorForFile(
          file: entity,
          uri: sessionWidgetTreeUri(sessionId, depth),
          name: 'session.widgetTree.$sessionId.$depth',
          title: 'Widget tree $sessionId depth=$depth',
          description: 'Captured widget tree snapshot.',
          mimeType: 'application/json',
          sessionId: sessionId,
        ));
        continue;
      }

      final cpuMatch = RegExp(r'cpu-profile-(.+)\.json$').firstMatch(entity.path);
      if (cpuMatch != null) {
        final captureId = cpuMatch.group(1)!;
        resources.add(await _descriptorForFile(
          file: entity,
          uri: sessionCpuProfileUri(sessionId, captureId),
          name: 'session.cpu.$sessionId.$captureId',
          title: 'CPU profile $sessionId $captureId',
          description: 'Captured CPU profile summary and raw samples.',
          mimeType: 'application/json',
          sessionId: sessionId,
        ));
        continue;
      }

      final timelineMatch = RegExp(r'timeline-(.+)\.json$').firstMatch(entity.path);
      if (timelineMatch != null) {
        final captureId = timelineMatch.group(1)!;
        resources.add(await _descriptorForFile(
          file: entity,
          uri: sessionTimelineUri(sessionId, captureId),
          name: 'session.timeline.$sessionId.$captureId',
          title: 'Timeline capture $sessionId $captureId',
          description: 'Captured VM timeline and summary.',
          mimeType: 'application/json',
          sessionId: sessionId,
        ));
        continue;
      }

      final memoryMatch = RegExp(r'memory-(.+)\.json$').firstMatch(entity.path);
      if (memoryMatch != null) {
        final snapshotId = memoryMatch.group(1)!;
        resources.add(await _descriptorForFile(
          file: entity,
          uri: sessionMemoryUri(sessionId, snapshotId),
          name: 'session.memory.$sessionId.$snapshotId',
          title: 'Memory snapshot $sessionId $snapshotId',
          description: 'Captured memory summary and heap snapshot metadata.',
          mimeType: 'application/json',
          sessionId: sessionId,
        ));
        continue;
      }

      final nativeHandoffMatch = RegExp(r'native-handoff-(ios|android)\.json$').firstMatch(entity.path);
      if (nativeHandoffMatch != null) {
        final platform = nativeHandoffMatch.group(1)!;
        resources.add(await _descriptorForFile(
          file: entity,
          uri: sessionNativeHandoffUri(sessionId, platform),
          name: 'session.nativeHandoff.$sessionId.$platform',
          title: 'Native handoff $sessionId $platform',
          description: 'Prepared native IDE handoff bundle.',
          mimeType: 'application/json',
          sessionId: sessionId,
        ));
      }
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
      final coverageSummary = File(p.join(entity.path, 'coverage-summary.json'));
      if (await coverageSummary.exists()) {
        resources.add(await _descriptorForFile(
          file: coverageSummary,
          uri: coverageSummaryUri(runId),
          name: 'coverage.summary.$runId',
          title: 'Coverage summary $runId',
          description: 'Coverage summary for the test run.',
          mimeType: 'application/json',
        ));
      }
      final coverageLcov = File(p.join(entity.path, 'coverage.lcov'));
      if (await coverageLcov.exists()) {
        resources.add(await _descriptorForFile(
          file: coverageLcov,
          uri: coverageLcovUri(runId),
          name: 'coverage.lcov.$runId',
          title: 'Coverage LCOV $runId',
          description: 'Raw LCOV output for the test run.',
          mimeType: 'text/plain',
        ));
      }
    }
    resources.sort((left, right) => left.uri.compareTo(right.uri));
    return resources;
  }

  Future<List<ResourceDescriptor>> listMutationResources() async {
    final dir = Directory(p.join(_artifactsDir, 'mutations'));
    if (!await dir.exists()) {
      return const <ResourceDescriptor>[];
    }
    final resources = <ResourceDescriptor>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) {
        continue;
      }
      final changeId = p.basename(entity.path);
      final stdout = File(p.join(entity.path, 'stdout.log'));
      if (await stdout.exists()) {
        resources.add(await _descriptorForFile(
          file: stdout,
          uri: mutationLogUri(changeId, 'stdout'),
          name: 'mutation.stdout.$changeId',
          title: 'Mutation stdout $changeId',
          description: 'stdout from a dependency mutation command.',
          mimeType: 'text/plain',
        ));
      }
      final stderr = File(p.join(entity.path, 'stderr.log'));
      if (await stderr.exists()) {
        resources.add(await _descriptorForFile(
          file: stderr,
          uri: mutationLogUri(changeId, 'stderr'),
          name: 'mutation.stderr.$changeId',
          title: 'Mutation stderr $changeId',
          description: 'stderr from a dependency mutation command.',
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

  Future<Map<String, Object?>?> _readJson(File file) async {
    if (!await file.exists()) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map<String, Object?>(
        (Object? key, Object? value) => MapEntry<String, Object?>(key.toString(), value),
      );
    }
    return null;
  }

  Future<String?> _readText(File file) async {
    if (!await file.exists()) {
      return null;
    }
    return file.readAsString();
  }

  Future<ResourceDescriptor> _descriptorForFile({
    required File file,
    required String uri,
    required String name,
    required String title,
    required String description,
    required String mimeType,
    String? sessionId,
  }) async {
    final stat = await file.stat();
    return ResourceDescriptor(
      uri: uri,
      name: name,
      title: title,
      description: description,
      mimeType: mimeType,
      createdAt: stat.changed.toUtc(),
      lastModified: stat.modified.toUtc(),
      size: stat.size,
      sessionId: sessionId,
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
      if (testFile.existsSync()) {
        return _ResolvedStoredFile(path: testFile.path, mimeType: 'text/plain');
      }
      return _ResolvedStoredFile(
        path: p.join(mutationArtifactsDir(id), '$stream.log'),
        mimeType: 'text/plain',
      );
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

    final cpuMatch = RegExp(r'^cpu://([^/]+)/([^/]+)$').firstMatch(uri);
    if (cpuMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(sessionArtifactsDir(cpuMatch.group(1)!), 'cpu-profile-${cpuMatch.group(2)}.json'),
        mimeType: 'application/json',
      );
    }

    final timelineMatch = RegExp(r'^timeline://([^/]+)/([^/]+)$').firstMatch(uri);
    if (timelineMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(sessionArtifactsDir(timelineMatch.group(1)!), 'timeline-${timelineMatch.group(2)}.json'),
        mimeType: 'application/json',
      );
    }

    final memoryMatch = RegExp(r'^memory://([^/]+)/([^/]+)$').firstMatch(uri);
    if (memoryMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(sessionArtifactsDir(memoryMatch.group(1)!), 'memory-${memoryMatch.group(2)}.json'),
        mimeType: 'application/json',
      );
    }

    final nativeHandoffMatch = RegExp(r'^native-handoff://([^/]+)/(ios|android)$').firstMatch(uri);
    if (nativeHandoffMatch != null) {
      return _ResolvedStoredFile(
        path: p.join(
          sessionArtifactsDir(nativeHandoffMatch.group(1)!),
          'native-handoff-${nativeHandoffMatch.group(2)}.json',
        ),
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

    final coverageMatch = RegExp(r'^coverage://([^/]+)/(summary|lcov)$').firstMatch(uri);
    if (coverageMatch != null) {
      final runId = coverageMatch.group(1)!;
      final kind = coverageMatch.group(2)!;
      return _ResolvedStoredFile(
        path: p.join(
          testRunArtifactsDir(runId),
          kind == 'summary' ? 'coverage-summary.json' : 'coverage.lcov',
        ),
        mimeType: kind == 'summary' ? 'application/json' : 'text/plain',
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
