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
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      'run',
      'bin/flutterhelm.dart',
      'serve',
      '--state-dir',
      stateDir,
    ], workingDirectory: repoRoot);

    return _TestMcpClient._(process: process, workspaceRoot: workspaceRoot);
  }

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
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
    return completer.future.timeout(const Duration(seconds: 10));
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
