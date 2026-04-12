import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('FlutterHelm MCP server', () {
    test('implements Phase 0 handshake, roots, tools, and resources', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
      addTearDown(() => sandbox.delete(recursive: true));

      final workspace = Directory(p.join(sandbox.path, 'workspace'));
      await workspace.create(recursive: true);
      await File(
        p.join(workspace.path, 'pubspec.yaml'),
      ).writeAsString('name: sample');

      final stateDir = Directory(p.join(sandbox.path, 'state'));
      final client = await _TestMcpClient.start(
        repoRoot: Directory.current.path,
        workspaceRoot: workspace.path,
        stateDir: stateDir.path,
      );
      addTearDown(client.close);

      final initialize = await client.request('initialize', <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{
          'roots': <String, Object?>{'listChanged': true},
        },
        'clientInfo': <String, Object?>{
          'name': 'test-client',
          'version': '1.0.0',
        },
      });

      expect(initialize['serverInfo'], containsPair('name', 'flutterhelm'));
      client.notify('notifications/initialized');

      final toolsList = await client.request('tools/list');
      final toolNames = (toolsList['tools'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> tool) => tool['name'])
          .toSet();
      expect(
        toolNames,
        containsAll(<String>[
          'analyze_project',
          'attach_app',
          'collect_coverage',
          'dependency_add',
          'dependency_remove',
          'device_list',
          'format_files',
          'get_app_state_summary',
          'get_logs',
          'get_runtime_errors',
          'get_test_results',
          'get_widget_tree',
          'pub_search',
          'resolve_symbol',
          'run_app',
          'run_integration_tests',
          'run_unit_tests',
          'run_widget_tests',
          'workspace_show',
          'workspace_set_root',
          'session_open',
          'session_list',
        ]),
      );

      final workspaceShow = await client.request(
        'tools/call',
        <String, Object?>{
          'name': 'workspace_show',
          'arguments': <String, Object?>{},
        },
      );
      final workspaceStructured =
          workspaceShow['structuredContent'] as Map<Object?, Object?>;
      expect(workspaceStructured['rootsMode'], 'roots-aware');
      expect((workspaceStructured['clientRoots'] as List<Object?>), isNotEmpty);

      final rootSet = await client.request('tools/call', <String, Object?>{
        'name': 'workspace_set_root',
        'arguments': <String, Object?>{'workspaceRoot': workspace.path},
      });
      expect(
        (rootSet['structuredContent'] as Map<Object?, Object?>)['activeRoot'],
        isNotNull,
      );

      final opened = await client.request('tools/call', <String, Object?>{
        'name': 'session_open',
        'arguments': <String, Object?>{},
      });
      final session = opened['structuredContent'] as Map<Object?, Object?>;
      final sessionId = session['sessionId'] as String;
      expect(session['state'], 'created');

      final sessionList = await client.request('tools/call', <String, Object?>{
        'name': 'session_list',
        'arguments': <String, Object?>{},
      });
      final sessions =
          ((sessionList['structuredContent']
                      as Map<Object?, Object?>)['sessions']
                  as List<Object?>)
              .cast<Map<Object?, Object?>>();
      expect(sessions, hasLength(1));
      expect(sessions.single['sessionId'], sessionId);

      final resources = await client.request('resources/list');
      final uris = (resources['resources'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> resource) => resource['uri'])
          .toSet();
      expect(uris, contains('config://workspace/current'));
      expect(uris, contains('session://$sessionId/summary'));

      final sessionResource = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'session://$sessionId/summary'},
      );
      final contents =
          (sessionResource['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final decoded =
          jsonDecode(contents['text'] as String) as Map<String, Object?>;
      expect(decoded['sessionId'], sessionId);

      final auditFile = File(p.join(stateDir.path, 'audit.jsonl'));
      expect(await auditFile.exists(), isTrue);
      final auditLines = await auditFile.readAsLines();
      expect(
        auditLines.any((String line) => line.contains('"method":"tools/call"')),
        isTrue,
      );
    });

    test('runs sample app unit and widget tests and publishes resources', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
      addTearDown(() => sandbox.delete(recursive: true));

      final stateDir = Directory(p.join(sandbox.path, 'state'));
      final sampleAppRoot = p.join(Directory.current.path, 'fixtures', 'sample_app');
      final client = await _TestMcpClient.start(
        repoRoot: Directory.current.path,
        workspaceRoot: sampleAppRoot,
        stateDir: stateDir.path,
      );
      addTearDown(client.close);

      await client.request('initialize', <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{
          'roots': <String, Object?>{'listChanged': true},
        },
        'clientInfo': <String, Object?>{
          'name': 'test-client',
          'version': '1.0.0',
        },
      });
      client.notify('notifications/initialized');

      await client.request('tools/call', <String, Object?>{
        'name': 'workspace_set_root',
        'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
      });

      final deviceList = await client.request('tools/call', <String, Object?>{
        'name': 'device_list',
        'arguments': <String, Object?>{},
      });
      final devices =
          ((deviceList['structuredContent'] as Map<Object?, Object?>)['devices']
                  as List<Object?>)
              .cast<Map<Object?, Object?>>();
      expect(devices, isNotEmpty);

      final unitTests = await client.request('tools/call', <String, Object?>{
        'name': 'run_unit_tests',
        'arguments': <String, Object?>{'coverage': true},
      }, const Duration(minutes: 2));
      expect(unitTests['isError'], isFalse);
      final unitStructured =
          unitTests['structuredContent'] as Map<Object?, Object?>;
      final unitRunId = unitStructured['runId'] as String;
      expect((unitStructured['summary'] as Map<Object?, Object?>)['failed'], 0);

      final widgetTests = await client.request('tools/call', <String, Object?>{
        'name': 'run_widget_tests',
        'arguments': <String, Object?>{'coverage': true},
      }, const Duration(minutes: 2));
      expect(widgetTests['isError'], isFalse);
      final widgetStructured =
          widgetTests['structuredContent'] as Map<Object?, Object?>;
      final widgetRunId = widgetStructured['runId'] as String;
      expect((widgetStructured['summary'] as Map<Object?, Object?>)['failed'], 0);

      final getResults = await client.request('tools/call', <String, Object?>{
        'name': 'get_test_results',
        'arguments': <String, Object?>{'runId': unitRunId},
      });
      expect(getResults['isError'], isFalse);

      final coverage = await client.request('tools/call', <String, Object?>{
        'name': 'collect_coverage',
        'arguments': <String, Object?>{'runId': unitRunId},
      });
      expect(coverage['isError'], isFalse);

      final resources = await client.request('resources/list');
      final uris = (resources['resources'] as List<Object?>)
          .cast<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> resource) => resource['uri'])
          .toSet();
      expect(uris, contains('test-report://$unitRunId/summary'));
      expect(uris, contains('test-report://$widgetRunId/summary'));
      expect(uris, contains('coverage://$unitRunId/summary'));
      expect(uris, contains('coverage://$unitRunId/lcov'));

      final unitSummary = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'test-report://$unitRunId/summary'},
      );
      final unitContents =
          (unitSummary['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final decoded =
          jsonDecode(unitContents['text'] as String) as Map<String, Object?>;
      expect(decoded['runId'], unitRunId);
    });

    test('supports pub search and approval replay for dependency mutation', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
      addTearDown(() => sandbox.delete(recursive: true));

      final sampleAppRoot = await _copyDirectory(
        p.join(Directory.current.path, 'fixtures', 'sample_app'),
        p.join(sandbox.path, 'sample_app_copy'),
      );
      final stateDir = Directory(p.join(sandbox.path, 'state'));
      final client = await _TestMcpClient.start(
        repoRoot: Directory.current.path,
        workspaceRoot: sampleAppRoot,
        stateDir: stateDir.path,
      );
      addTearDown(client.close);

      await _initializeClient(client);

      await client.request('tools/call', <String, Object?>{
        'name': 'workspace_set_root',
        'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
      });

      final pubSearch = await client.request('tools/call', <String, Object?>{
        'name': 'pub_search',
        'arguments': <String, Object?>{'query': 'async', 'limit': 3},
      }, const Duration(seconds: 30));
      expect(pubSearch['isError'], isFalse);
      final searchPackages =
          ((pubSearch['structuredContent'] as Map<Object?, Object?>)['packages']
                  as List<Object?>)
              .cast<Map<Object?, Object?>>();
      expect(searchPackages, isNotEmpty);

      final addAttempt = await client.request('tools/call', <String, Object?>{
        'name': 'dependency_add',
        'arguments': <String, Object?>{
          'package': 'async',
        },
      });
      final addStructured =
          addAttempt['structuredContent'] as Map<Object?, Object?>;
      expect(addAttempt['isError'], isFalse);
      expect(addStructured['status'], 'approval_required');
      final approvalToken = addStructured['approvalRequestId'] as String;

      final addApproved = await client.request('tools/call', <String, Object?>{
        'name': 'dependency_add',
        'arguments': <String, Object?>{
          'package': 'async',
          'approvalToken': approvalToken,
        },
      }, const Duration(minutes: 2));
      expect(addApproved['isError'], isFalse);
      final addApprovedStructured =
          addApproved['structuredContent'] as Map<Object?, Object?>;
      expect(addApprovedStructured['status'], 'completed');
      expect(addApprovedStructured['dependency'], isNotNull);

      final removeAttempt = await client.request('tools/call', <String, Object?>{
        'name': 'dependency_remove',
        'arguments': <String, Object?>{
          'package': 'async',
        },
      });
      final removeStructured =
          removeAttempt['structuredContent'] as Map<Object?, Object?>;
      expect(removeAttempt['isError'], isFalse);
      expect(removeStructured['status'], 'approval_required');

      final removeApproved = await client.request('tools/call', <String, Object?>{
        'name': 'dependency_remove',
        'arguments': <String, Object?>{
          'package': 'async',
          'approvalToken': removeStructured['approvalRequestId'],
        },
      }, const Duration(minutes: 2));
      expect(removeApproved['isError'], isFalse);

      final auditFile = File(p.join(stateDir.path, 'audit.jsonl'));
      final auditLines = await auditFile.readAsLines();
      expect(
        auditLines.any((String line) => line.contains('"result":"approval_required"')),
        isTrue,
      );
      expect(
        auditLines.any((String line) => line.contains('"result":"approved"')),
        isTrue,
      );
    });

    test('requires approval for fallback workspace root selection', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
      addTearDown(() => sandbox.delete(recursive: true));

      final sampleAppRoot = p.join(Directory.current.path, 'fixtures', 'sample_app');
      final stateDir = Directory(p.join(sandbox.path, 'state'));
      final client = await _TestMcpClient.start(
        repoRoot: Directory.current.path,
        workspaceRoot: null,
        stateDir: stateDir.path,
        allowRootFallback: true,
      );
      addTearDown(client.close);

      await _initializeClient(client, supportsRoots: false);

      final firstAttempt = await client.request('tools/call', <String, Object?>{
        'name': 'workspace_set_root',
        'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
      });
      expect(firstAttempt['isError'], isFalse);
      final structured =
          firstAttempt['structuredContent'] as Map<Object?, Object?>;
      expect(structured['status'], 'approval_required');

      final approved = await client.request('tools/call', <String, Object?>{
        'name': 'workspace_set_root',
        'arguments': <String, Object?>{
          'workspaceRoot': sampleAppRoot,
          'approvalToken': structured['approvalRequestId'],
        },
      });
      expect(approved['isError'], isFalse);
      expect(
        (approved['structuredContent'] as Map<Object?, Object?>)['activeRoot'],
        isNotNull,
      );
    });

    test(
      'runs integration tests and exposes stored results',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
        addTearDown(() => sandbox.delete(recursive: true));

        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final sampleAppRoot = p.join(
          Directory.current.path,
          'fixtures',
          'sample_app',
        );
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: sampleAppRoot,
          stateDir: stateDir.path,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
        });

        final integration = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'run_integration_tests',
            'arguments': <String, Object?>{
              'platform': 'ios',
              'target': 'integration_test/app_test.dart',
            },
          },
          const Duration(minutes: 10),
        );
        expect(integration['isError'], isFalse);
        final structured =
            integration['structuredContent'] as Map<Object?, Object?>;
        final runId = structured['runId'] as String;
        expect(structured['status'], 'completed');

        final getResults = await client.request('tools/call', <String, Object?>{
          'name': 'get_test_results',
          'arguments': <String, Object?>{'runId': runId},
        });
        expect(getResults['isError'], isFalse);

        final resources = await client.request('resources/list');
        final uris = (resources['resources'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> resource) => resource['uri'])
            .toSet();
        expect(uris, contains('test-report://$runId/summary'));
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test(
      'returns structured tool errors when no active root is available',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'flutterhelm-e2e',
        );
        addTearDown(() => sandbox.delete(recursive: true));

        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: null,
          stateDir: stateDir.path,
        );
        addTearDown(client.close);

        await client.request('initialize', <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': const <String, Object?>{},
          'clientInfo': <String, Object?>{
            'name': 'test-client',
            'version': '1.0.0',
          },
        });
        client.notify('notifications/initialized');

        final result = await client.request('tools/call', <String, Object?>{
          'name': 'session_open',
          'arguments': <String, Object?>{},
        });

        expect(result['isError'], isTrue);
        final error =
            (result['structuredContent'] as Map<Object?, Object?>)['error']
                as Map<Object?, Object?>;
        expect(error['code'], 'WORKSPACE_ROOT_REQUIRED');
      },
    );
  });
}

Future<void> _initializeClient(
  _TestMcpClient client, {
  bool supportsRoots = true,
}) async {
  await client.request('initialize', <String, Object?>{
    'protocolVersion': '2025-06-18',
    'capabilities': supportsRoots
        ? <String, Object?>{
            'roots': <String, Object?>{'listChanged': true},
          }
        : const <String, Object?>{},
    'clientInfo': <String, Object?>{
      'name': 'test-client',
      'version': '1.0.0',
    },
  });
  client.notify('notifications/initialized');
}

Future<String> _copyDirectory(String sourcePath, String targetPath) async {
  final source = Directory(sourcePath);
  final target = Directory(targetPath);
  await target.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final destinationPath = p.join(target.path, relative);
    if (entity is Directory) {
      await Directory(destinationPath).create(recursive: true);
      continue;
    }
    if (entity is File) {
      await File(destinationPath).parent.create(recursive: true);
      await entity.copy(destinationPath);
    }
  }
  return target.path;
}

class _TestMcpClient {
  _TestMcpClient._({required this.process, required this.workspaceRoot}) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdout);
  }

  final Process process;
  final String? workspaceRoot;
  final Map<String, Completer<Map<String, Object?>>> _pendingRequests =
      <String, Completer<Map<String, Object?>>>{};
  int _nextRequestId = 1;

  static Future<_TestMcpClient> start({
    required String repoRoot,
    required String? workspaceRoot,
    required String stateDir,
    bool allowRootFallback = false,
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      'run',
      'bin/flutterhelm.dart',
      'serve',
      '--state-dir',
      stateDir,
      if (allowRootFallback) '--allow-root-fallback',
    ], workingDirectory: repoRoot);

    return _TestMcpClient._(process: process, workspaceRoot: workspaceRoot);
  }

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
    Duration timeout = const Duration(seconds: 10),
  ]) {
    final id = (_nextRequestId++).toString();
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[id] = completer;
    _send(<String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    return completer.future.timeout(timeout);
  }

  void notify(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    _send(<String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      if (params.isNotEmpty) 'params': params,
    });
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return 1;
      },
    );
  }

  void _handleStdout(String line) {
    final message = jsonDecode(line) as Map<String, Object?>;
    final method = message['method'] as String?;
    if (method != null) {
      if (method == 'roots/list') {
        final id = message['id']?.toString();
        if (id == null) {
          return;
        }
        _send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, Object?>{
            'roots': workspaceRoot == null
                ? const <Object?>[]
                : <Map<String, Object?>>[
                    <String, Object?>{
                      'uri': Uri.directory(workspaceRoot!).toString(),
                      'name': 'workspace',
                    },
                  ],
          },
        });
      }
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

    if (message['error'] case final Map<Object?, Object?> error) {
      completer.completeError(error['message'] ?? 'Unknown protocol error');
      return;
    }

    completer.complete(message['result'] as Map<String, Object?>);
  }

  void _send(Map<String, Object?> message) {
    process.stdin.writeln(jsonEncode(message));
  }
}
