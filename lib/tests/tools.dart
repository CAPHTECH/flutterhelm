import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;

class TestToolService {
  TestToolService({
    required this.processRunner,
    required this.artifactStore,
    required this.flutterExecutable,
  });

  final ProcessRunner processRunner;
  final ArtifactStore artifactStore;
  final String flutterExecutable;

  Future<Map<String, Object?>> runUnitTests({
    required String workspaceRoot,
    required List<String> targets,
    required bool coverage,
  }) {
    return _runTests(
      workspaceRoot: workspaceRoot,
      targets: targets,
      coverage: coverage,
      category: 'unit',
    );
  }

  Future<Map<String, Object?>> runWidgetTests({
    required String workspaceRoot,
    required List<String> targets,
    required bool coverage,
  }) {
    return _runTests(
      workspaceRoot: workspaceRoot,
      targets: targets,
      coverage: coverage,
      category: 'widget',
    );
  }

  Future<Map<String, Object?>> runIntegrationTests({
    required String workspaceRoot,
    required List<String> targets,
    required String platform,
    required String deviceId,
    required bool coverage,
    String? flavor,
  }) {
    return _runTests(
      workspaceRoot: workspaceRoot,
      targets: targets,
      coverage: coverage,
      category: 'integration',
      platform: platform,
      deviceId: deviceId,
      flavor: flavor,
    );
  }

  Future<Map<String, Object?>> getTestResults({required String runId}) async {
    final summary = await artifactStore.readTestRunSummary(runId);
    if (summary == null) {
      throw FlutterHelmToolError(
        code: 'TEST_RUN_NOT_FOUND',
        category: 'workspace',
        message: 'Unknown test run: $runId',
        retryable: false,
      );
    }
    return <String, Object?>{
      'runId': runId,
      'status': summary['status'],
      'summary': summary['summary'],
      'resources': _resourcesForRun(runId, coverage: await _hasCoverage(runId)),
    };
  }

  Future<Map<String, Object?>> collectCoverage({required String runId}) async {
    final summary = await artifactStore.readCoverageSummary(runId);
    final lcov = await artifactStore.readCoverageLcov(runId);
    if (summary == null || lcov == null) {
      throw FlutterHelmToolError(
        code: 'COVERAGE_NOT_FOUND',
        category: 'workspace',
        message: 'Coverage artifacts are unavailable for run $runId.',
        retryable: true,
      );
    }
    return <String, Object?>{
      'runId': runId,
      'summary': summary,
      'resources': <Map<String, Object?>>[
        <String, Object?>{
          'uri': artifactStore.coverageSummaryUri(runId),
          'mimeType': 'application/json',
          'title': 'Coverage summary',
        },
        <String, Object?>{
          'uri': artifactStore.coverageLcovUri(runId),
          'mimeType': 'text/plain',
          'title': 'Coverage LCOV',
        },
      ],
    };
  }

  Future<Map<String, Object?>> _runTests({
    required String workspaceRoot,
    required List<String> targets,
    required bool coverage,
    required String category,
    String? platform,
    String? deviceId,
    String? flavor,
  }) async {
    final resolvedTargets = targets.isNotEmpty
        ? targets
              .map(
                (String target) =>
                    p.isAbsolute(target) ? target : p.join(workspaceRoot, target),
              )
              .toList()
        : await _discoverTargets(
            workspaceRoot: workspaceRoot,
            category: category,
          );
    if (resolvedTargets.isEmpty) {
      throw FlutterHelmToolError(
        code: 'TEST_TARGET_NOT_FOUND',
        category: 'workspace',
        message: 'No $category test targets were found.',
        retryable: true,
      );
    }
    if (category == 'integration' && (deviceId == null || deviceId.isEmpty)) {
      throw FlutterHelmToolError(
        code: 'DEVICE_NOT_FOUND',
        category: 'runtime',
        message: 'run_integration_tests requires a resolved deviceId.',
        retryable: true,
      );
    }

    final runId =
        'test_${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}_${category.substring(0, 1)}';
    final coveragePath = p.join(artifactStore.testRunArtifactsDir(runId), 'coverage.lcov');
    final arguments = <String>[
      'test',
      '--machine',
      if (coverage) '--coverage',
      if (coverage) '--coverage-path=$coveragePath',
      if (category == 'integration') '-d',
      if (category == 'integration') deviceId!,
      if (flavor != null && flavor.isNotEmpty) '--flavor=$flavor',
      ...resolvedTargets,
    ];
    final result = await processRunner.run(
      flutterExecutable,
      arguments,
      workingDirectory: workspaceRoot,
      timeout: category == 'integration'
          ? const Duration(minutes: 8)
          : const Duration(minutes: 5),
    );

    await _writeLogs(runId: runId, stdout: result.stdout, stderr: result.stderr);

    final summary = _summarizeMachineOutput(result.stdout);
    final status =
        result.exitCode == 0 && (summary['failed'] as int) == 0 ? 'completed' : 'failed';
    final coverageSummary = coverage ? await _publishCoverage(runId, coveragePath) : null;
    final summaryPayload = <String, Object?>{
      'runId': runId,
      'category': category,
      'targets': resolvedTargets,
      'platform': platform,
      'deviceId': deviceId,
      'status': status,
      'summary': <String, Object?>{
        ...summary,
        'durationMs': result.duration.inMilliseconds,
      },
      'coverage': coverageSummary != null,
    };
    await artifactStore.writeTestRunSummary(runId: runId, payload: summaryPayload);
    await artifactStore.writeTestRunDetails(
      runId: runId,
      payload: <String, Object?>{
        'runId': runId,
        'category': category,
        'platform': platform,
        'deviceId': deviceId,
        'machineOutput': _decodeMachineLines(result.stdout),
        'stderr': result.stderr,
      },
    );
    return <String, Object?>{
      'runId': runId,
      'status': status,
      'summary': summaryPayload['summary'],
      if (coverageSummary != null) 'coverageSummary': coverageSummary,
      'resources': _resourcesForRun(runId, coverage: coverageSummary != null),
    };
  }

  Future<List<String>> _discoverTargets({
    required String workspaceRoot,
    required String category,
  }) async {
    final testRoot = Directory(p.join(workspaceRoot, 'test'));
    final integrationRoot = Directory(p.join(workspaceRoot, 'integration_test'));
    final targets = <String>[];

    if (category == 'integration') {
      if (!await integrationRoot.exists()) {
        return const <String>[];
      }
      await for (final entity
          in integrationRoot.list(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.endsWith('_test.dart')) {
          targets.add(p.normalize(entity.path));
        }
      }
      targets.sort();
      return targets;
    }

    if (!await testRoot.exists()) {
      return const <String>[];
    }
    await for (final entity in testRoot.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('_test.dart')) {
        continue;
      }
      final normalized = p.normalize(entity.path);
      final isUnit =
          normalized.contains('${p.separator}test${p.separator}unit${p.separator}');
      final isWidget =
          normalized.contains('${p.separator}test${p.separator}widget${p.separator}');
      if ((category == 'unit' && isUnit) ||
          (category == 'widget' &&
              (isWidget ||
                  (!isUnit &&
                      !normalized.contains(
                        '${p.separator}integration_test${p.separator}',
                      ))))) {
        targets.add(normalized);
      }
    }
    targets.sort();
    return targets;
  }

  Future<void> _writeLogs({
    required String runId,
    required String stdout,
    required String stderr,
  }) async {
    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      await artifactStore.appendTestRunLog(runId: runId, stream: 'stdout', line: line);
    }
    for (final line in stderr.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      await artifactStore.appendTestRunLog(runId: runId, stream: 'stderr', line: line);
    }
  }

  Future<Map<String, Object?>?> _publishCoverage(
    String runId,
    String coveragePath,
  ) async {
    final coverageFile = File(coveragePath);
    if (!await coverageFile.exists()) {
      return null;
    }
    final contents = await coverageFile.readAsString();
    await artifactStore.writeCoverageLcov(runId: runId, contents: contents);
    final summary = _summarizeCoverage(contents, runId);
    await artifactStore.writeCoverageSummary(runId: runId, payload: summary);
    return summary;
  }

  Future<bool> _hasCoverage(String runId) async {
    final summary = await artifactStore.readCoverageSummary(runId);
    final lcov = await artifactStore.readCoverageLcov(runId);
    return summary != null && lcov != null;
  }

  Map<String, Object?> _summarizeMachineOutput(String stdout) {
    var passed = 0;
    var failed = 0;
    var skipped = 0;
    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      Map<String, Object?> decoded;
      try {
        final raw = jsonDecode(line);
        if (raw is Map<String, Object?>) {
          decoded = raw;
        } else if (raw is Map) {
          decoded = raw.map<String, Object?>(
            (Object? key, Object? value) =>
                MapEntry<String, Object?>(key.toString(), value),
          );
        } else {
          continue;
        }
      } catch (_) {
        continue;
      }
      if (decoded['type'] != 'testDone') {
        continue;
      }
      if (decoded['hidden'] == true) {
        continue;
      }
      switch (decoded['result']) {
        case 'success':
          passed += 1;
        case 'failure':
        case 'error':
          failed += 1;
        case 'skipped':
          skipped += 1;
      }
    }
    return <String, Object?>{
      'passed': passed,
      'failed': failed,
      'skipped': skipped,
    };
  }

  List<Map<String, Object?>> _decodeMachineLines(String stdout) {
    final events = <Map<String, Object?>>[];
    for (final line in stdout.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, Object?>) {
          events.add(decoded);
        } else if (decoded is Map) {
          events.add(
            decoded.map<String, Object?>(
              (Object? key, Object? value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            ),
          );
        }
      } catch (_) {
        events.add(<String, Object?>{'type': 'raw', 'line': line});
      }
    }
    return events;
  }

  Map<String, Object?> _summarizeCoverage(String lcov, String runId) {
    var files = 0;
    var linesFound = 0;
    var linesHit = 0;
    for (final line in lcov.split('\n')) {
      if (line.startsWith('SF:')) {
        files += 1;
        continue;
      }
      if (line.startsWith('LF:')) {
        linesFound += int.tryParse(line.substring(3)) ?? 0;
        continue;
      }
      if (line.startsWith('LH:')) {
        linesHit += int.tryParse(line.substring(3)) ?? 0;
      }
    }
    final lineCoverage = linesFound == 0
        ? 0.0
        : (linesHit / linesFound * 100).toDouble();
    return <String, Object?>{
      'runId': runId,
      'files': files,
      'linesFound': linesFound,
      'linesHit': linesHit,
      'lineCoveragePercent': double.parse(lineCoverage.toStringAsFixed(2)),
    };
  }

  List<Map<String, Object?>> _resourcesForRun(
    String runId, {
    required bool coverage,
  }) {
    return <Map<String, Object?>>[
      <String, Object?>{
        'uri': artifactStore.testSummaryUri(runId),
        'mimeType': 'application/json',
        'title': 'Test summary',
      },
      <String, Object?>{
        'uri': artifactStore.testDetailsUri(runId),
        'mimeType': 'application/json',
        'title': 'Test details',
      },
      <String, Object?>{
        'uri': artifactStore.testLogUri(runId, 'stdout'),
        'mimeType': 'text/plain',
        'title': 'Test stdout',
      },
      <String, Object?>{
        'uri': artifactStore.testLogUri(runId, 'stderr'),
        'mimeType': 'text/plain',
        'title': 'Test stderr',
      },
      if (coverage)
        <String, Object?>{
          'uri': artifactStore.coverageSummaryUri(runId),
          'mimeType': 'application/json',
          'title': 'Coverage summary',
        },
      if (coverage)
        <String, Object?>{
          'uri': artifactStore.coverageLcovUri(runId),
          'mimeType': 'text/plain',
          'title': 'Coverage LCOV',
        },
    ];
  }
}
