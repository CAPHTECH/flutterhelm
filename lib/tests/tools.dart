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

  Future<Map<String, Object?>> _runTests({
    required String workspaceRoot,
    required List<String> targets,
    required bool coverage,
    required String category,
  }) async {
    final resolvedTargets = targets.isNotEmpty
        ? targets.map((String target) => p.isAbsolute(target) ? target : p.join(workspaceRoot, target)).toList()
        : await _discoverTargets(workspaceRoot: workspaceRoot, category: category);
    if (resolvedTargets.isEmpty) {
      throw FlutterHelmToolError(
        code: 'TEST_TARGET_NOT_FOUND',
        category: 'workspace',
        message: 'No $category test targets were found.',
        retryable: true,
      );
    }

    final runId =
        'test_${DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36)}_${category.substring(0, 1)}';
    final result = await processRunner.run(
      flutterExecutable,
      <String>[
        'test',
        '--machine',
        if (coverage) '--coverage',
        ...resolvedTargets,
      ],
      workingDirectory: workspaceRoot,
      timeout: const Duration(minutes: 5),
    );

    for (final line in result.stdout.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      await artifactStore.appendTestRunLog(runId: runId, stream: 'stdout', line: line);
    }
    for (final line in result.stderr.split('\n')) {
      if (line.trim().isEmpty) {
        continue;
      }
      await artifactStore.appendTestRunLog(runId: runId, stream: 'stderr', line: line);
    }

    final summary = _summarizeMachineOutput(result.stdout);
    final summaryPayload = <String, Object?>{
      'runId': runId,
      'category': category,
      'targets': resolvedTargets,
      'status': result.exitCode == 0 && (summary['failed'] as int) == 0 ? 'completed' : 'failed',
      'summary': <String, Object?>{
        ...summary,
        'durationMs': result.duration.inMilliseconds,
      },
      'coverage': coverage,
    };
    await artifactStore.writeTestRunSummary(runId: runId, payload: summaryPayload);
    await artifactStore.writeTestRunDetails(
      runId: runId,
      payload: <String, Object?>{
        'runId': runId,
        'category': category,
        'machineOutput': _decodeMachineLines(result.stdout),
        'stderr': result.stderr,
      },
    );
    return <String, Object?>{
      'runId': runId,
      'status': summaryPayload['status'],
      'summary': summaryPayload['summary'],
      'resources': <Map<String, Object?>>[
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
      ],
    };
  }

  Future<List<String>> _discoverTargets({
    required String workspaceRoot,
    required String category,
  }) async {
    final testRoot = Directory(p.join(workspaceRoot, 'test'));
    if (!await testRoot.exists()) {
      return const <String>[];
    }
    final targets = <String>[];
    await for (final entity in testRoot.list(recursive: true, followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('_test.dart')) {
        continue;
      }
      final normalized = p.normalize(entity.path);
      final isUnit = normalized.contains('${p.separator}test${p.separator}unit${p.separator}');
      final isWidget = normalized.contains('${p.separator}test${p.separator}widget${p.separator}');
      if ((category == 'unit' && isUnit) ||
          (category == 'widget' && (isWidget || (!isUnit && !normalized.contains('${p.separator}integration_test${p.separator}'))))) {
        targets.add(normalized);
      }
    }
    targets.sort();
    return targets;
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
            (Object? key, Object? value) => MapEntry<String, Object?>(key.toString(), value),
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
          events.add(decoded.map<String, Object?>(
            (Object? key, Object? value) => MapEntry<String, Object?>(key.toString(), value),
          ));
        }
      } catch (_) {
        events.add(<String, Object?>{'type': 'raw', 'line': line});
      }
    }
    return events;
  }
}
