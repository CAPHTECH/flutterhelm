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
          'artifact_pin',
          'artifact_pin_list',
          'artifact_unpin',
          'collect_coverage',
          'compatibility_check',
          'dependency_add',
          'dependency_remove',
          'device_list',
          'android_debug_context',
          'format_files',
          'capture_memory_snapshot',
          'capture_timeline',
          'get_app_state_summary',
          'get_logs',
          'get_runtime_errors',
          'get_test_results',
          'get_widget_tree',
          'ios_debug_context',
          'native_handoff_summary',
          'pub_search',
          'resolve_symbol',
          'run_app',
          'run_integration_tests',
          'run_unit_tests',
          'run_widget_tests',
          'start_cpu_profile',
          'workspace_show',
          'workspace_set_root',
          'session_open',
          'session_list',
          'stop_cpu_profile',
          'toggle_performance_overlay',
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
      expect(uris, contains('config://artifacts/pins'));
      expect(uris, contains('config://compatibility/current'));
      expect(uris, contains('session://$sessionId/summary'));
      expect(uris, contains('session://$sessionId/health'));

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

      final healthResource = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'session://$sessionId/health'},
      );
      final healthContents =
          (healthResource['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final healthDecoded =
          jsonDecode(healthContents['text'] as String) as Map<String, Object?>;
      expect(healthDecoded['sessionId'], sessionId);
      expect(healthDecoded['backend'], 'vm_service');

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
      }, const Duration(minutes: 2));
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
      'profiles the sample app and exposes profiling resources and health guidance',
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

        final running = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'run_app',
            'arguments': <String, Object?>{
              'platform': 'ios',
              'mode': 'debug',
              'dartDefines': <String>['FLUTTERHELM_SCENARIO=profile_demo'],
            },
          },
          const Duration(minutes: 8),
        );
        expect(running['isError'], isFalse);
        final runningStructured =
            running['structuredContent'] as Map<Object?, Object?>;
        final sessionId = runningStructured['sessionId'] as String;
        expect(runningStructured['mode'], 'debug');

        addTearDown(() async {
          final stopResult = await client.request('tools/call', <String, Object?>{
            'name': 'stop_app',
            'arguments': <String, Object?>{'sessionId': sessionId},
          });
          if (stopResult['isError'] == true) {
            stderr.writeln('stop_app during teardown failed: ${stopResult['structuredContent']}');
          }
        });

        final health = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'session://$sessionId/health'},
        );
        final healthBody =
            (health['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final healthDecoded =
            jsonDecode(healthBody['text'] as String) as Map<String, Object?>;
        expect(healthDecoded['ready'], isTrue);
        expect(healthDecoded['recommendedMode'], 'profile');

        final startCpu = await client.request('tools/call', <String, Object?>{
          'name': 'start_cpu_profile',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(startCpu['isError'], isFalse);

        await Future<void>.delayed(const Duration(seconds: 2));

        final stopCpu = await client.request('tools/call', <String, Object?>{
          'name': 'stop_cpu_profile',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(stopCpu['isError'], isFalse);
        final stopCpuStructured =
            stopCpu['structuredContent'] as Map<Object?, Object?>;
        final cpuUri =
            (stopCpuStructured['resource'] as Map<Object?, Object?>)['uri']
                as String;
        final cpuResource = await client.request(
          'resources/read',
          <String, Object?>{'uri': cpuUri},
        );
        final cpuBody =
            (cpuResource['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final cpuDecoded =
            jsonDecode(cpuBody['text'] as String) as Map<String, Object?>;
        expect(cpuDecoded['sessionId'], sessionId);
        expect(
          ((cpuDecoded['summary'] as Map<String, Object?>)['sampleCount'] as num),
          greaterThan(0),
        );

        final timeline = await client.request('tools/call', <String, Object?>{
          'name': 'capture_timeline',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'durationMs': 1000,
          },
        }, const Duration(minutes: 2));
        expect(timeline['isError'], isFalse);
        final timelineStructured =
            timeline['structuredContent'] as Map<Object?, Object?>;
        final timelineUri =
            (timelineStructured['resource'] as Map<Object?, Object?>)['uri']
                as String;
        final timelineResource = await client.request(
          'resources/read',
          <String, Object?>{'uri': timelineUri},
        );
        final timelineBody =
            (timelineResource['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final timelineDecoded =
            jsonDecode(timelineBody['text'] as String) as Map<String, Object?>;
        expect(
          ((timelineDecoded['summary'] as Map<String, Object?>)['eventCount'] as num),
          greaterThan(0),
        );

        final memory = await client.request('tools/call', <String, Object?>{
          'name': 'capture_memory_snapshot',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'gc': true,
          },
        }, const Duration(minutes: 3));
        expect(memory['isError'], isFalse);
        final memoryStructured =
            memory['structuredContent'] as Map<Object?, Object?>;
        final memoryUri =
            (memoryStructured['resource'] as Map<Object?, Object?>)['uri']
                as String;
        final memoryResource = await client.request(
          'resources/read',
          <String, Object?>{'uri': memoryUri},
        );
        final memoryBody =
            (memoryResource['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final memoryDecoded =
            jsonDecode(memoryBody['text'] as String) as Map<String, Object?>;
        expect(memoryDecoded['sessionId'], sessionId);
        expect(memoryDecoded['heapSnapshot'], isNotNull);

        final overlay = await client.request('tools/call', <String, Object?>{
          'name': 'toggle_performance_overlay',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'enabled': true,
          },
        });
        expect(overlay['isError'], isFalse);

        final attached = await client.request('tools/call', <String, Object?>{
          'name': 'attach_app',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'platform': 'ios',
            'mode': 'debug',
          },
        });
        expect(attached['isError'], isFalse);
        final attachedSessionId =
            ((attached['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String;

        final attachedProfile = await client.request('tools/call', <String, Object?>{
          'name': 'capture_timeline',
          'arguments': <String, Object?>{
            'sessionId': attachedSessionId,
            'durationMs': 250,
          },
        });
        expect(attachedProfile['isError'], isTrue);
        final attachedError =
            ((attachedProfile['structuredContent'] as Map<Object?, Object?>)['error'])
                as Map<Object?, Object?>;
        expect(attachedError['code'], 'PROFILE_OWNERSHIP_REQUIRED');
        final detailsResource =
            attachedError['detailsResource'] as Map<Object?, Object?>;
        expect(detailsResource['uri'], 'session://$attachedSessionId/health');

        final resources = await client.request('resources/list');
        final uris = (resources['resources'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> resource) => resource['uri'])
            .toSet();
        expect(uris, contains(cpuUri));
        expect(uris, contains(timelineUri));
        expect(uris, contains(memoryUri));
        expect(uris, contains('session://$sessionId/health'));
      },
      timeout: const Timeout(Duration(minutes: 15)),
    );

    test(
      'creates iOS native handoff bundles and summaries from live and postmortem sessions',
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

        final running = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'run_app',
            'arguments': <String, Object?>{
              'platform': 'ios',
              'mode': 'debug',
            },
          },
          const Duration(minutes: 8),
        );
        expect(running['isError'], isFalse);
        final sessionId =
            ((running['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String;

        addTearDown(() async {
          final stopResult = await client.request('tools/call', <String, Object?>{
            'name': 'stop_app',
            'arguments': <String, Object?>{'sessionId': sessionId},
          });
          if (stopResult['isError'] == true) {
            stderr.writeln('stop_app during teardown failed: ${stopResult['structuredContent']}');
          }
        });

        final handoff = await client.request('tools/call', <String, Object?>{
          'name': 'ios_debug_context',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'tailLines': 50,
          },
        });
        expect(handoff['isError'], isFalse);
        final handoffStructured =
            handoff['structuredContent'] as Map<Object?, Object?>;
        final handoffResource =
            handoffStructured['resource'] as Map<Object?, Object?>;
        final handoffUri = handoffResource['uri'] as String;
        expect(handoffUri, 'native-handoff://$sessionId/ios');

        final handoffBundle = await client.request(
          'resources/read',
          <String, Object?>{'uri': handoffUri},
        );
        final handoffBody =
            (handoffBundle['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final handoffDecoded =
            jsonDecode(handoffBody['text'] as String) as Map<String, Object?>;
        expect(handoffDecoded['status'], 'ready');
        final openPaths =
            (handoffDecoded['openPaths'] as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(
          openPaths.any(
            (Map<Object?, Object?> value) =>
                (value['path'] as String).endsWith('ios/Runner.xcworkspace'),
          ),
          isTrue,
        );
        final evidenceResources =
            (handoffDecoded['evidenceResources'] as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(
          evidenceResources.any(
            (Map<Object?, Object?> value) =>
                value['uri'] == 'session://$sessionId/summary',
          ),
          isTrue,
        );
        expect(
          evidenceResources.any(
            (Map<Object?, Object?> value) =>
                value['uri'] == 'session://$sessionId/health',
          ),
          isTrue,
        );
        final limitations =
            (handoffDecoded['limitations'] as List<Object?>).cast<String>();
        expect(
          limitations.any(
            (String value) => value.contains('not a native debugger replacement'),
          ),
          isTrue,
        );

        final summary = await client.request('tools/call', <String, Object?>{
          'name': 'native_handoff_summary',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(summary['isError'], isFalse);
        final summaryStructured =
            summary['structuredContent'] as Map<Object?, Object?>;
        final platforms =
            (summaryStructured['platforms'] as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(
          platforms.any(
            (Map<Object?, Object?> value) => value['platform'] == 'ios',
          ),
          isTrue,
        );

        final stopped = await client.request('tools/call', <String, Object?>{
          'name': 'stop_app',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(stopped['isError'], isFalse);

        final postmortem = await client.request('tools/call', <String, Object?>{
          'name': 'ios_debug_context',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(postmortem['isError'], isFalse);
        final postmortemBundle = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'native-handoff://$sessionId/ios'},
        );
        final postmortemBody =
            (postmortemBundle['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final postmortemDecoded =
            jsonDecode(postmortemBody['text'] as String) as Map<String, Object?>;
        expect(
          ((postmortemDecoded['session'] as Map<String, Object?>)['state']),
          'stopped',
        );
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test(
      'creates Android native handoff bundles for synthetic workspaces and reports unavailable when missing',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
        addTearDown(() => sandbox.delete(recursive: true));

        final androidWorkspace = Directory(p.join(sandbox.path, 'android-workspace'));
        await androidWorkspace.create(recursive: true);
        await _writeTextFile(
          p.join(androidWorkspace.path, 'pubspec.yaml'),
          'name: android_workspace\n',
        );
        await _writeTextFile(
          p.join(
            androidWorkspace.path,
            'android',
            'app',
            'src',
            'main',
            'AndroidManifest.xml',
          ),
          '<manifest package="com.example.androidworkspace"></manifest>\n',
        );
        await _writeTextFile(
          p.join(androidWorkspace.path, 'android', 'app', 'build.gradle'),
          'plugins {}\n',
        );
        await _writeTextFile(
          p.join(androidWorkspace.path, 'android', 'settings.gradle'),
          'rootProject.name = "android_workspace"\n',
        );
        await _writeTextFile(
          p.join(androidWorkspace.path, 'android', 'gradle.properties'),
          'org.gradle.jvmargs=-Xmx1536M\n',
        );

        final stateDir = Directory(p.join(sandbox.path, 'android-state'));
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: androidWorkspace.path,
          stateDir: stateDir.path,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': androidWorkspace.path},
        });

        final opened = await client.request('tools/call', <String, Object?>{
          'name': 'session_open',
          'arguments': <String, Object?>{},
        });
        final sessionId =
            ((opened['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String;

        final androidContext = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'android_debug_context',
            'arguments': <String, Object?>{'sessionId': sessionId},
          },
        );
        expect(androidContext['isError'], isFalse);

        final androidBundle = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'native-handoff://$sessionId/android'},
        );
        final androidBody =
            (androidBundle['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final androidDecoded =
            jsonDecode(androidBody['text'] as String) as Map<String, Object?>;
        expect(androidDecoded['status'], 'ready');
        final androidOpenPaths =
            (androidDecoded['openPaths'] as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(androidOpenPaths, isNotEmpty);

        final androidSummary = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'native_handoff_summary',
            'arguments': <String, Object?>{'sessionId': sessionId},
          },
        );
        expect(androidSummary['isError'], isFalse);
        final androidPlatforms =
            (((androidSummary['structuredContent'] as Map<Object?, Object?>)['platforms'])
                    as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(
          androidPlatforms.any(
            (Map<Object?, Object?> value) => value['platform'] == 'android',
          ),
          isTrue,
        );

        final missingWorkspace = Directory(p.join(sandbox.path, 'missing-android'));
        await missingWorkspace.create(recursive: true);
        await _writeTextFile(
          p.join(missingWorkspace.path, 'pubspec.yaml'),
          'name: missing_android\n',
        );

        final missingStateDir = Directory(p.join(sandbox.path, 'missing-state'));
        final missingClient = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: missingWorkspace.path,
          stateDir: missingStateDir.path,
        );
        addTearDown(missingClient.close);

        await _initializeClient(missingClient);
        await missingClient.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': missingWorkspace.path},
        });
        final missingOpened = await missingClient.request('tools/call', <String, Object?>{
          'name': 'session_open',
          'arguments': <String, Object?>{},
        });
        final missingSessionId =
            ((missingOpened['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String;

        final missingAndroidContext = await missingClient.request(
          'tools/call',
          <String, Object?>{
            'name': 'android_debug_context',
            'arguments': <String, Object?>{'sessionId': missingSessionId},
          },
        );
        expect(missingAndroidContext['isError'], isFalse);
        final missingBundle = await missingClient.request(
          'resources/read',
          <String, Object?>{'uri': 'native-handoff://$missingSessionId/android'},
        );
        final missingBody =
            (missingBundle['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final missingDecoded =
            jsonDecode(missingBody['text'] as String) as Map<String, Object?>;
        expect(missingDecoded['status'], 'unavailable');
      },
    );

    test('applies config profiles and manages pinned artifacts', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
      addTearDown(() => sandbox.delete(recursive: true));

      final stateDir = Directory(p.join(sandbox.path, 'state'));
      final sampleAppRoot = p.join(Directory.current.path, 'fixtures', 'sample_app');
      final configPath = await _writeConfigFile(
        p.join(sandbox.path, 'config.yaml'),
        '''
version: 1
workspace:
  roots:
    - ${jsonEncode(sampleAppRoot)}
defaults:
  target: lib/main.dart
  mode: debug
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - tests
  - profiling
  - platform_bridge
profiles:
  interactive:
    enabledWorkflows:
      - workspace
      - session
      - launcher
      - runtime_readonly
      - tests
      - profiling
      - platform_bridge
      - runtime_interaction
    adapters:
      active:
        runtimeDriver: builtin.runtime_driver.external_process
      providers:
        builtin.runtime_driver.external_process:
          kind: builtin
          families:
            - runtimeDriver
          command: ${Platform.resolvedExecutable}
          args:
            - run
            - tool/fake_runtime_driver.dart
          startupTimeoutMs: 15000
          options:
            enabled: true
adapters:
  providers:
    builtin.runtime_driver.external_process:
      kind: builtin
      families:
        - runtimeDriver
      command: ${Platform.resolvedExecutable}
      args:
        - run
        - tool/fake_runtime_driver.dart
      startupTimeoutMs: 15000
      options:
        enabled: false
''',
      );
      final client = await _TestMcpClient.start(
        repoRoot: Directory.current.path,
        workspaceRoot: sampleAppRoot,
        stateDir: stateDir.path,
        configPath: configPath,
        profile: 'interactive',
      );
      addTearDown(client.close);

      await _initializeClient(client);

      final workspaceShow = await client.request('tools/call', <String, Object?>{
        'name': 'workspace_show',
        'arguments': <String, Object?>{},
      });
      final workspaceStructured =
          workspaceShow['structuredContent'] as Map<Object?, Object?>;
      expect(workspaceStructured['releaseChannel'], 'stable');
      expect(workspaceStructured['activeProfile'], 'interactive');
      expect(
        (workspaceStructured['availableProfiles'] as List<Object?>)
            .contains('interactive'),
        isTrue,
      );
      expect(
        (workspaceStructured['stableHarnessTags'] as List<Object?>).contains('runtime'),
        isTrue,
      );
      final workspaceSupportLevels =
          workspaceStructured['supportLevels'] as Map<Object?, Object?>;
      final transportSupport =
          workspaceSupportLevels['transport'] as Map<Object?, Object?>;
      expect(
        (transportSupport['stdio'] as Map<Object?, Object?>)['supportLevel'],
        'stable',
      );
      expect(
        (transportSupport['http'] as Map<Object?, Object?>)['supportLevel'],
        'preview',
      );

      final workspaceCurrent = await client.request('resources/read', <String, Object?>{
        'uri': 'config://workspace/current',
      });
      final workspaceCurrentBody =
          (workspaceCurrent['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final workspaceCurrentDecoded =
          jsonDecode(workspaceCurrentBody['text'] as String) as Map<String, Object?>;
      expect(workspaceCurrentDecoded['releaseChannel'], 'stable');
      expect(workspaceCurrentDecoded['activeProfile'], 'interactive');
      expect(
        workspaceCurrentDecoded['artifactsStatusResource'],
        'config://artifacts/status',
      );
      expect(
        workspaceCurrentDecoded['observabilityResource'],
        'config://observability/current',
      );

      final compatibility = await client.request('tools/call', <String, Object?>{
        'name': 'compatibility_check',
        'arguments': <String, Object?>{},
      });
      expect(compatibility['isError'], isFalse);
      final compatibilityStructured =
          compatibility['structuredContent'] as Map<Object?, Object?>;
      expect(compatibilityStructured['releaseChannel'], 'stable');
      final workflows =
          compatibilityStructured['workflows'] as Map<Object?, Object?>;
      final runtimeInteraction =
          workflows['runtime_interaction'] as Map<Object?, Object?>;
      expect(runtimeInteraction['configured'], isTrue);
      expect(runtimeInteraction['supportLevel'], 'beta');
      expect(runtimeInteraction['includedInStableLane'], isFalse);

      final compatibilityResource = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'config://compatibility/current'},
      );
      final compatibilityResourceBody =
          (compatibilityResource['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final compatibilityDecoded =
          jsonDecode(compatibilityResourceBody['text'] as String)
              as Map<String, Object?>;
      expect(compatibilityDecoded['releaseChannel'], 'stable');
      expect(compatibilityDecoded['profile'], 'interactive');

      final artifactStatusResource = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'config://artifacts/status'},
      );
      final artifactStatusBody =
          (artifactStatusResource['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final artifactStatusDecoded =
          jsonDecode(artifactStatusBody['text'] as String)
              as Map<String, Object?>;
      expect(artifactStatusDecoded['capacityBytes'], isA<int>());

      final observabilityResource = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'config://observability/current'},
      );
      final observabilityBody =
          (observabilityResource['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final observabilityDecoded =
          jsonDecode(observabilityBody['text'] as String)
              as Map<String, Object?>;
      expect(observabilityDecoded['transport'], isA<Map<String, Object?>>());

      final attached = await client.request('tools/call', <String, Object?>{
        'name': 'attach_app',
        'arguments': <String, Object?>{
          'workspaceRoot': sampleAppRoot,
          'platform': 'ios',
          'deviceId': 'fake-ios-simulator',
          'target': 'lib/main.dart',
          'mode': 'debug',
          'debugUrl': 'ws://127.0.0.1:34567/ws',
        },
      });
      expect(attached['isError'], isFalse);
      final sessionId =
          ((attached['structuredContent'] as Map<Object?, Object?>)['sessionId'])
              as String;

      final screenshot = await client.request('tools/call', <String, Object?>{
        'name': 'capture_screenshot',
        'arguments': <String, Object?>{'sessionId': sessionId},
      });
      expect(screenshot['isError'], isFalse);
      final screenshotUri =
          (((screenshot['structuredContent'] as Map<Object?, Object?>)['resource']
                  as Map<Object?, Object?>)['uri'])
              as String;

      final pin = await client.request('tools/call', <String, Object?>{
        'name': 'artifact_pin',
        'arguments': <String, Object?>{
          'uri': screenshotUri,
          'label': 'keep-for-debug',
        },
      });
      expect(pin['isError'], isFalse);

      final list = await client.request('tools/call', <String, Object?>{
        'name': 'artifact_pin_list',
        'arguments': <String, Object?>{'sessionId': sessionId},
      });
      final pins =
          ((list['structuredContent'] as Map<Object?, Object?>)['pins']
                  as List<Object?>)
              .cast<Map<Object?, Object?>>();
      expect(pins, hasLength(1));
      expect(pins.single['uri'], screenshotUri);
      expect(pins.single['status'], 'present');

      final pinsResource = await client.request(
        'resources/read',
        <String, Object?>{'uri': 'config://artifacts/pins'},
      );
      final pinsBody =
          (pinsResource['contents'] as List<Object?>).single
              as Map<Object?, Object?>;
      final pinsDecoded =
          jsonDecode(pinsBody['text'] as String) as Map<String, Object?>;
      final pinnedArtifacts =
          (pinsDecoded['pins'] as List<Object?>).cast<Map<Object?, Object?>>();
      expect(
        pinnedArtifacts.any((Map<Object?, Object?> item) => item['uri'] == screenshotUri),
        isTrue,
      );

      final unpin = await client.request('tools/call', <String, Object?>{
        'name': 'artifact_unpin',
        'arguments': <String, Object?>{'uri': screenshotUri},
      });
      expect(unpin['isError'], isFalse);
    });

    test('rejects concurrent workspace operations with WORKSPACE_BUSY', () async {
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

      await _initializeClient(client);
      await client.request('tools/call', <String, Object?>{
        'name': 'workspace_set_root',
        'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
      });

      final first = client.request('tools/call', <String, Object?>{
        'name': 'run_widget_tests',
        'arguments': <String, Object?>{},
      }, const Duration(minutes: 2));

      await Future<void>.delayed(const Duration(milliseconds: 200));

      final second = await client.request('tools/call', <String, Object?>{
        'name': 'run_unit_tests',
        'arguments': <String, Object?>{},
      }, const Duration(minutes: 2));

      expect(second['isError'], isTrue);
      final error =
          ((second['structuredContent'] as Map<Object?, Object?>)['error'])
              as Map<Object?, Object?>;
      expect(error['code'], 'WORKSPACE_BUSY');

      final completedFirst = await first;
      expect(completedFirst['isError'], isFalse);
    });

    test(
      'supports runtime interaction contracts with a fake external driver',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
        addTearDown(() => sandbox.delete(recursive: true));

        final sampleAppRoot = p.join(
          Directory.current.path,
          'fixtures',
          'sample_app',
        );
        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final configPath = await _writeConfigFile(
          p.join(sandbox.path, 'config.yaml'),
          '''
version: 1
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - runtime_interaction
  - profiling
  - platform_bridge
  - tests
adapters:
  active:
    runtimeDriver: builtin.runtime_driver.external_process
  providers:
    builtin.runtime_driver.external_process:
      kind: builtin
      families:
        - runtimeDriver
      command: ${Platform.resolvedExecutable}
      args:
        - run
        - tool/fake_runtime_driver.dart
      startupTimeoutMs: 15000
      options:
        enabled: true
''',
        );
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: sampleAppRoot,
          stateDir: stateDir.path,
          configPath: configPath,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
        });

        final toolsList = await client.request('tools/list');
        final toolNames = (toolsList['tools'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> tool) => tool['name'])
            .toSet();
        expect(
          toolNames,
          containsAll(<String>[
            'capture_screenshot',
            'tap_widget',
            'enter_text',
            'scroll_until_visible',
            'hot_reload',
            'hot_restart',
          ]),
        );

        final attached = await client.request('tools/call', <String, Object?>{
          'name': 'attach_app',
          'arguments': <String, Object?>{
            'workspaceRoot': sampleAppRoot,
            'platform': 'ios',
            'deviceId': 'fake-ios-simulator',
            'target': 'lib/main.dart',
            'mode': 'debug',
            'debugUrl': 'ws://127.0.0.1:34567/ws',
          },
        });
        expect(attached['isError'], isFalse);
        final attachedSessionId =
            (((attached['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String);

        final appState = await client.request('tools/call', <String, Object?>{
          'name': 'get_app_state_summary',
          'arguments': <String, Object?>{'sessionId': attachedSessionId},
        });
        final appStateStructured =
            appState['structuredContent'] as Map<Object?, Object?>;
        expect(appStateStructured['driverConnected'], isTrue);
        expect(
          (appStateStructured['supportedLocatorFields'] as List<Object?>)
              .contains('valueKey'),
          isTrue,
        );

        final tap = await client.request('tools/call', <String, Object?>{
          'name': 'tap_widget',
          'arguments': <String, Object?>{
            'sessionId': attachedSessionId,
            'locator': <String, Object?>{'valueKey': 'primaryButton'},
          },
        });
        expect(tap['isError'], isFalse);

        final enterText = await client.request('tools/call', <String, Object?>{
          'name': 'enter_text',
          'arguments': <String, Object?>{
            'sessionId': attachedSessionId,
            'locator': <String, Object?>{'valueKey': 'nameField'},
            'text': 'Rin',
            'submit': true,
          },
        });
        expect(enterText['isError'], isFalse);

        final scroll = await client.request('tools/call', <String, Object?>{
          'name': 'scroll_until_visible',
          'arguments': <String, Object?>{
            'sessionId': attachedSessionId,
            'locator': <String, Object?>{'valueKey': 'deepItem'},
            'direction': 'down',
          },
        });
        expect(scroll['isError'], isFalse);

        final tapDeep = await client.request('tools/call', <String, Object?>{
          'name': 'tap_widget',
          'arguments': <String, Object?>{
            'sessionId': attachedSessionId,
            'locator': <String, Object?>{'valueKey': 'deepItem'},
          },
        });
        expect(tapDeep['isError'], isFalse);

        final screenshot = await client.request('tools/call', <String, Object?>{
          'name': 'capture_screenshot',
          'arguments': <String, Object?>{
            'sessionId': attachedSessionId,
            'format': 'png',
          },
        });
        expect(screenshot['isError'], isFalse);
        final screenshotStructured =
            screenshot['structuredContent'] as Map<Object?, Object?>;
        final screenshotUri =
            ((screenshotStructured['resource'] as Map<Object?, Object?>)['uri'])
                as String;
        final screenshotResource = await client.request(
          'resources/read',
          <String, Object?>{'uri': screenshotUri},
        );
        final screenshotBody =
            (screenshotResource['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        expect(screenshotBody['blob'], isNotNull);
        expect(screenshotBody['text'], isNull);

        final hotReload = await client.request('tools/call', <String, Object?>{
          'name': 'hot_reload',
          'arguments': <String, Object?>{'sessionId': attachedSessionId},
        });
        expect(hotReload['isError'], isTrue);
        final hotReloadError =
            (hotReload['structuredContent'] as Map<Object?, Object?>)['error']
                as Map<Object?, Object?>;
        expect(hotReloadError['code'], 'HOT_RELOAD_UNAVAILABLE');

        final hotRestart = await client.request('tools/call', <String, Object?>{
          'name': 'hot_restart',
          'arguments': <String, Object?>{'sessionId': attachedSessionId},
        });
        expect(hotRestart['isError'], isTrue);
        final hotRestartError =
            (hotRestart['structuredContent'] as Map<Object?, Object?>)['error']
                as Map<Object?, Object?>;
        expect(hotRestartError['code'], 'HOT_RESTART_UNAVAILABLE');
      },
    );

    test(
      'runs real runtime interaction against the sample app on iOS simulator',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
        addTearDown(() => sandbox.delete(recursive: true));

        final sampleAppRoot = p.join(
          Directory.current.path,
          'fixtures',
          'sample_app',
        );
        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final configPath = await _writeConfigFile(
          p.join(sandbox.path, 'config.yaml'),
          '''
version: 1
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - runtime_interaction
  - profiling
  - platform_bridge
  - tests
adapters:
  active:
    runtimeDriver: builtin.runtime_driver.external_process
  providers:
    builtin.runtime_driver.external_process:
      kind: builtin
      families:
        - runtimeDriver
      command: npx
      args:
        - -y
        - "@mobilenext/mobile-mcp@latest"
        - --stdio
      startupTimeoutMs: 15000
      options:
        enabled: true
''',
        );
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: sampleAppRoot,
          stateDir: stateDir.path,
          configPath: configPath,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
        });

        final running = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'run_app',
            'arguments': <String, Object?>{
              'platform': 'ios',
              'mode': 'debug',
              'dartDefines': <String>['FLUTTERHELM_SCENARIO=interaction_demo'],
            },
          },
          const Duration(minutes: 8),
        );
        expect(running['isError'], isFalse);
        final runningStructured =
            running['structuredContent'] as Map<Object?, Object?>;
        final sessionId = runningStructured['sessionId'] as String;

        addTearDown(() async {
          final stopResult = await client.request('tools/call', <String, Object?>{
            'name': 'stop_app',
            'arguments': <String, Object?>{'sessionId': sessionId},
          });
          if (stopResult['isError'] == true) {
            stderr.writeln(
              'stop_app during teardown failed: ${stopResult['structuredContent']}',
            );
          }
        });

        final health = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'session://$sessionId/health'},
        );
        final healthBody =
            (health['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final healthDecoded =
            jsonDecode(healthBody['text'] as String) as Map<String, Object?>;
        expect(healthDecoded['driverConfigured'], isTrue);
        expect(healthDecoded['driverConnected'], isTrue);
        expect(healthDecoded['runtimeInteractionReady'], isTrue);
        expect(healthDecoded['screenshotReady'], isTrue);

        final screenshot = await client.request('tools/call', <String, Object?>{
          'name': 'capture_screenshot',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(screenshot['isError'], isFalse);
        final screenshotStructured =
            screenshot['structuredContent'] as Map<Object?, Object?>;
        expect(screenshotStructured['driverConnected'], isTrue);
        expect(screenshotStructured['fallbackUsed'], isA<bool>());
        if (screenshotStructured['fallbackUsed'] == true) {
          expect(screenshotStructured['fallbackReason'], isNotNull);
        }

        final tap = await client.request('tools/call', <String, Object?>{
          'name': 'tap_widget',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'locator': <String, Object?>{'text': 'Tap primary'},
          },
        }, const Duration(minutes: 2));
        expect(tap['isError'], isFalse);

        final enterText = await client.request('tools/call', <String, Object?>{
          'name': 'enter_text',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'locator': <String, Object?>{'textContains': 'Name input'},
            'text': 'Codex',
            'submit': true,
          },
        }, const Duration(minutes: 2));
        expect(enterText['isError'], isFalse);

        final scroll = await client.request('tools/call', <String, Object?>{
          'name': 'scroll_until_visible',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'locator': <String, Object?>{'text': 'Deep action'},
            'direction': 'down',
            'maxScrolls': 10,
          },
        }, const Duration(minutes: 2));
        expect(scroll['isError'], isFalse);

        final tapDeep = await client.request('tools/call', <String, Object?>{
          'name': 'tap_widget',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'locator': <String, Object?>{'text': 'Deep action'},
          },
        }, const Duration(minutes: 2));
        expect(tapDeep['isError'], isFalse);

        await Future<void>.delayed(const Duration(seconds: 2));

        final logs = await client.request('tools/call', <String, Object?>{
          'name': 'get_logs',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'stream': 'stdout',
            'tailLines': 200,
          },
        });
        final logsStructured =
            logs['structuredContent'] as Map<Object?, Object?>;
        final preview =
            (logsStructured['preview'] as Map<Object?, Object?>)['stdout']
                as String? ??
            '';
        expect(preview, contains('interaction: primary tapped'));
        expect(preview, contains('interaction: text submitted=Codex'));
        expect(preview, contains('interaction: deep action tapped'));

        final hotReload = await client.request('tools/call', <String, Object?>{
          'name': 'hot_reload',
          'arguments': <String, Object?>{'sessionId': sessionId},
        }, const Duration(minutes: 2));
        expect(hotReload['isError'], isFalse);

        final hotRestartAttempt = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'hot_restart',
            'arguments': <String, Object?>{'sessionId': sessionId},
          },
        );
        final hotRestartStructured =
            hotRestartAttempt['structuredContent'] as Map<Object?, Object?>;
        expect(hotRestartStructured['status'], 'approval_required');

        final hotRestartApproved = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'hot_restart',
            'arguments': <String, Object?>{
              'sessionId': sessionId,
              'approvalToken': hotRestartStructured['approvalRequestId'],
            },
          },
          const Duration(minutes: 3),
        );
        expect(hotRestartApproved['isError'], isFalse);

        final attached = await client.request('tools/call', <String, Object?>{
          'name': 'attach_app',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'workspaceRoot': sampleAppRoot,
            'platform': 'ios',
            'target': 'lib/main.dart',
            'mode': 'debug',
          },
        });
        expect(attached['isError'], isFalse);
        final attachedSessionId =
            (((attached['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String);

        final attachedHotReload = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'hot_reload',
            'arguments': <String, Object?>{'sessionId': attachedSessionId},
          },
        );
        expect(attachedHotReload['isError'], isTrue);

        final attachedHotRestart = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'hot_restart',
            'arguments': <String, Object?>{'sessionId': attachedSessionId},
          },
        );
        expect(attachedHotRestart['isError'], isTrue);
        final attachedHotRestartError =
            (attachedHotRestart['structuredContent'] as Map<Object?, Object?>)['error']
                as Map<Object?, Object?>;
        expect(attachedHotRestartError['code'], 'HOT_RESTART_UNAVAILABLE');
      },
      timeout: const Timeout(Duration(minutes: 16)),
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

    test(
      'activates a custom stdio_json runtime driver provider through the adapter registry',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('flutterhelm-e2e');
        addTearDown(() => sandbox.delete(recursive: true));

        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final sampleAppRoot = p.join(Directory.current.path, 'fixtures', 'sample_app');
        final configPath = await _writeConfigFile(
          p.join(sandbox.path, 'config.yaml'),
          '''
version: 1
workspace:
  roots:
    - ${jsonEncode(sampleAppRoot)}
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - runtime_interaction
adapters:
  active:
    runtimeDriver: custom.runtime.driver
  providers:
    custom.runtime.driver:
      kind: stdio_json
      families:
        - runtimeDriver
      command: ${Platform.resolvedExecutable}
      args:
        - run
        - tool/fake_stdio_adapter_provider.dart
      startupTimeoutMs: 15000
''',
        );
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: sampleAppRoot,
          stateDir: stateDir.path,
          configPath: configPath,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
        });

        final adapterList = await client.request('tools/call', <String, Object?>{
          'name': 'adapter_list',
          'arguments': <String, Object?>{'family': 'runtimeDriver'},
        });
        expect(adapterList['isError'], isFalse);
        final adapters =
            ((adapterList['structuredContent'] as Map<Object?, Object?>)['adapters']
                    as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(adapters, hasLength(1));
        expect(adapters.single['activeProviderId'], 'custom.runtime.driver');
        expect(adapters.single['kind'], 'stdio_json');
        expect(adapters.single['healthy'], isTrue);

        final adaptersResource = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'config://adapters/current'},
        );
        final adaptersBody =
            (adaptersResource['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final adaptersDecoded =
            jsonDecode(adaptersBody['text'] as String) as Map<String, Object?>;
        final active = adaptersDecoded['active'] as Map<String, Object?>;
        expect(active['runtimeDriver'], 'custom.runtime.driver');

        final attached = await client.request('tools/call', <String, Object?>{
          'name': 'attach_app',
          'arguments': <String, Object?>{
            'workspaceRoot': sampleAppRoot,
            'platform': 'ios',
            'deviceId': 'fake-ios-simulator',
            'target': 'lib/main.dart',
            'mode': 'debug',
            'debugUrl': 'ws://127.0.0.1:34567/ws',
          },
        });
        final sessionId =
            ((attached['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String;
        final screenshot = await client.request('tools/call', <String, Object?>{
          'name': 'capture_screenshot',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(screenshot['isError'], isFalse);
        final screenshotStructured =
            screenshot['structuredContent'] as Map<Object?, Object?>;
        expect(screenshotStructured['backend'], 'external_adapter');
        expect(screenshotStructured['driverConnected'], isTrue);
        expect(screenshotStructured['fallbackUsed'], isFalse);
        expect(screenshotStructured.containsKey('fallbackReason'), isFalse);
        final screenshotUri =
            ((screenshotStructured['resource']
                    as Map<Object?, Object?>)['uri'])
                as String;
        expect(screenshotUri, startsWith('screenshot://$sessionId/'));
      },
    );

    test(
      'reports runtime interaction readiness and screenshot fallback when the driver is disabled',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'flutterhelm-runtime-driver-disabled',
        );
        addTearDown(() => sandbox.delete(recursive: true));

        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final sampleAppRoot = p.join(
          Directory.current.path,
          'fixtures',
          'sample_app',
        );
        final configPath = await _writeConfigFile(
          p.join(sandbox.path, 'config.yaml'),
          '''
version: 1
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - runtime_interaction
  - profiling
  - platform_bridge
  - tests
adapters:
  active:
    runtimeDriver: builtin.runtime_driver.external_process
  providers:
    builtin.runtime_driver.external_process:
      kind: builtin
      families:
        - runtimeDriver
      command: npx
      args:
        - -y
        - "@mobilenext/mobile-mcp@latest"
        - --stdio
      startupTimeoutMs: 15000
      options:
        enabled: false
''',
        );
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: sampleAppRoot,
          stateDir: stateDir.path,
          configPath: configPath,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
        });

        final running = await client.request(
          'tools/call',
          <String, Object?>{
            'name': 'run_app',
            'arguments': <String, Object?>{
              'platform': 'ios',
              'mode': 'debug',
              'dartDefines': <String>['FLUTTERHELM_SCENARIO=interaction_demo'],
            },
          },
          const Duration(minutes: 8),
        );
        expect(running['isError'], isFalse);
        final sessionId =
            ((running['structuredContent'] as Map<Object?, Object?>)['sessionId'])
                as String;

        addTearDown(() async {
          final stopResult = await client.request('tools/call', <String, Object?>{
            'name': 'stop_app',
            'arguments': <String, Object?>{'sessionId': sessionId},
          });
          if (stopResult['isError'] == true) {
            stderr.writeln(
              'stop_app during teardown failed: ${stopResult['structuredContent']}',
            );
          }
        });

        final health = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'session://$sessionId/health'},
        );
        final healthBody =
            (health['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final healthDecoded =
            jsonDecode(healthBody['text'] as String) as Map<String, Object?>;
        expect(healthDecoded['ready'], isFalse);
        expect(healthDecoded['runtimeDriverEnabled'], isFalse);
        expect(healthDecoded['runtimeInteractionReady'], isFalse);
        expect(healthDecoded['screenshotReady'], isTrue);
        expect(
          (healthDecoded['issues'] as List<Object?>).contains(
            'runtime driver is disabled',
          ),
          isTrue,
        );

        final screenshot = await client.request('tools/call', <String, Object?>{
          'name': 'capture_screenshot',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        expect(screenshot['isError'], isFalse);
        final screenshotStructured =
            screenshot['structuredContent'] as Map<Object?, Object?>;
        expect(screenshotStructured['backend'], 'ios_simctl');
        expect(screenshotStructured['driverConnected'], isFalse);
        expect(screenshotStructured['fallbackUsed'], isTrue);
        expect(screenshotStructured['fallbackReason'], isNotNull);

        final tap = await client.request('tools/call', <String, Object?>{
          'name': 'tap_widget',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'locator': <String, Object?>{'text': 'Tap primary'},
          },
        });
        expect(tap['isError'], isTrue);
        final tapError =
            ((tap['structuredContent'] as Map<Object?, Object?>)['error'])
                as Map<Object?, Object?>;
        expect(tapError['code'], 'RUNTIME_DRIVER_UNAVAILABLE');
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );

    test(
      'supports nativeBuild beta sessions and correlated native resources',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'flutterhelm-native-build',
        );
        addTearDown(() => sandbox.delete(recursive: true));

        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final sampleAppRoot = p.join(
          Directory.current.path,
          'fixtures',
          'sample_app',
        );
        final configPath = await _writeConfigFile(
          p.join(sandbox.path, 'config.yaml'),
          '''
version: 1
workspace:
  roots:
    - ${jsonEncode(sampleAppRoot)}
enabledWorkflows:
  - workspace
  - session
  - launcher
  - runtime_readonly
  - profiling
  - platform_bridge
  - native_build
adapters:
  active:
    nativeBuild: custom.native.build
  providers:
    custom.native.build:
      kind: stdio_json
      families:
        - nativeBuild
      command: ${Platform.resolvedExecutable}
      args:
        - run
        - tool/fake_native_build_provider.dart
      startupTimeoutMs: 15000
''',
        );
        final client = await _TestMcpClient.start(
          repoRoot: Directory.current.path,
          workspaceRoot: sampleAppRoot,
          stateDir: stateDir.path,
          configPath: configPath,
        );
        addTearDown(client.close);

        await _initializeClient(client);
        await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': sampleAppRoot},
        });

        final tools = await client.request('tools/list');
        final toolNames = (tools['tools'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> tool) => tool['name'])
            .toSet();
        expect(
          toolNames,
          containsAll(<String>[
            'native_project_inspect',
            'native_build_launch',
            'native_attach_flutter_runtime',
            'native_stop',
          ]),
        );

        final adapterList = await client.request('tools/call', <String, Object?>{
          'name': 'adapter_list',
          'arguments': <String, Object?>{'family': 'nativeBuild'},
        });
        final adapters =
            ((adapterList['structuredContent'] as Map<Object?, Object?>)['adapters']
                    as List<Object?>)
                .cast<Map<Object?, Object?>>();
        expect(adapters.single['activeProviderId'], 'custom.native.build');
        expect(adapters.single['supportLevel'], 'beta');
        expect(adapters.single['healthy'], isTrue);

        final inspect = await client.request('tools/call', <String, Object?>{
          'name': 'native_project_inspect',
          'arguments': <String, Object?>{'platform': 'ios'},
        });
        final inspectStructured =
            inspect['structuredContent'] as Map<Object?, Object?>;
        expect(inspectStructured['platform'], 'ios');
        expect(
          (inspectStructured['schemes'] as List<Object?>).contains('Runner'),
          isTrue,
        );

        final launch = await client.request('tools/call', <String, Object?>{
          'name': 'native_build_launch',
          'arguments': <String, Object?>{'platform': 'ios'},
        });
        final launchStructured =
            launch['structuredContent'] as Map<Object?, Object?>;
        final sessionId = launchStructured['sessionId'] as String;
        final launchSession =
            launchStructured['session'] as Map<Object?, Object?>;
        final launchNativeContext =
            launchSession['nativeContext'] as Map<Object?, Object?>;
        expect(launchNativeContext['providerId'], 'custom.native.build');
        expect(launchNativeContext['flutterRuntimeAttached'], isFalse);

        final resources = await client.request('resources/list');
        final uris = (resources['resources'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> resource) => resource['uri'])
            .toSet();
        expect(uris, contains('session://$sessionId/native-summary'));
        expect(uris, contains('log://$sessionId/native-build'));
        expect(uris, contains('log://$sessionId/native-device'));

        final nativeSummary = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'session://$sessionId/native-summary'},
        );
        final nativeSummaryBody =
            (nativeSummary['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final nativeSummaryDecoded =
            jsonDecode(nativeSummaryBody['text'] as String)
                as Map<String, Object?>;
        expect(nativeSummaryDecoded['sessionId'], sessionId);

        final attachHints =
            launchStructured['runtimeAttachHints'] as Map<Object?, Object?>;
        final attach = await client.request('tools/call', <String, Object?>{
          'name': 'native_attach_flutter_runtime',
          'arguments': <String, Object?>{
            'sessionId': sessionId,
            'debugUrl': attachHints['debugUrl'] as String,
            'appId': attachHints['appId'] as String,
            'deviceId': attachHints['deviceId'] as String,
          },
        });
        final attachStructured =
            attach['structuredContent'] as Map<Object?, Object?>;
        final attachedSession =
            attachStructured['session'] as Map<Object?, Object?>;
        final attachedNativeContext =
            attachedSession['nativeContext'] as Map<Object?, Object?>;
        expect(attachedNativeContext['flutterRuntimeAttached'], isTrue);

        final appState = await client.request('tools/call', <String, Object?>{
          'name': 'get_app_state_summary',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        final appStateStructured =
            appState['structuredContent'] as Map<Object?, Object?>;
        expect(appStateStructured['nativeBuildAttached'], isTrue);

        final iosContext = await client.request('tools/call', <String, Object?>{
          'name': 'ios_debug_context',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        final iosStructured =
            iosContext['structuredContent'] as Map<Object?, Object?>;
        final handoffResource =
            iosStructured['resource'] as Map<Object?, Object?>;
        expect(handoffResource['uri'], 'native-handoff://$sessionId/ios');

        final handoffBundle = await client.request(
          'resources/read',
          <String, Object?>{'uri': 'native-handoff://$sessionId/ios'},
        );
        final handoffBody =
            (handoffBundle['contents'] as List<Object?>).single
                as Map<Object?, Object?>;
        final handoffDecoded =
            jsonDecode(handoffBody['text'] as String) as Map<String, Object?>;
        expect(handoffDecoded['nativeContext'], isA<Map<String, Object?>>());
        final evidence =
            handoffDecoded['evidenceResources'] as List<Object?>;
        expect(
          evidence.any(
            (Object? item) =>
                (item as Map<Object?, Object?>)['uri'] ==
                'session://$sessionId/native-summary',
          ),
          isTrue,
        );
        expect(
          evidence.any(
            (Object? item) =>
                (item as Map<Object?, Object?>)['uri'] ==
                'log://$sessionId/native-build',
          ),
          isTrue,
        );

        final stop = await client.request('tools/call', <String, Object?>{
          'name': 'native_stop',
          'arguments': <String, Object?>{'sessionId': sessionId},
        });
        final stopStructured =
            stop['structuredContent'] as Map<Object?, Object?>;
        final stoppedSession =
            stopStructured['session'] as Map<Object?, Object?>;
        expect(stoppedSession['state'], 'stopped');
      },
    );

    test(
      'supports HTTP preview session lifecycle and fallback-only root flow',
      () async {
        final sandbox = await Directory.systemTemp.createTemp('flutterhelm-http');
        addTearDown(() => sandbox.delete(recursive: true));

        final workspace = Directory(p.join(sandbox.path, 'workspace'));
        await workspace.create(recursive: true);
        await File(
          p.join(workspace.path, 'pubspec.yaml'),
        ).writeAsString('name: http_sample\n');

        final stateDir = Directory(p.join(sandbox.path, 'state'));
        final client = await _HttpTestMcpClient.start(
          repoRoot: Directory.current.path,
          stateDir: stateDir.path,
          allowRootFallback: true,
        );
        addTearDown(client.close);

        final initialize = await client.request('initialize', <String, Object?>{
          'protocolVersion': '2025-06-18',
          'capabilities': const <String, Object?>{},
          'clientInfo': <String, Object?>{
            'name': 'http-test-client',
            'version': '1.0.0',
          },
        });
        expect(initialize['serverInfo'], containsPair('name', 'flutterhelm'));
        final experimental =
            (initialize['capabilities'] as Map<Object?, Object?>)['experimental']
                as Map<Object?, Object?>;
        final httpPreview =
            experimental['httpPreview'] as Map<Object?, Object?>;
        expect(httpPreview['sessionExpiryMinutes'], 30);
        await client.notify('notifications/initialized');

        final tools = await client.request('tools/list');
        final toolNames = (tools['tools'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> tool) => tool['name'])
            .toSet();
        expect(toolNames, contains('adapter_list'));

        final workspaceShow = await client.request('tools/call', <String, Object?>{
          'name': 'workspace_show',
          'arguments': const <String, Object?>{},
        });
        final workspaceStructured =
            workspaceShow['structuredContent'] as Map<Object?, Object?>;
        expect(workspaceStructured['transportMode'], 'http');
        expect(workspaceStructured['rootsTransportSupport'], 'unsupported');

        final firstRootSet = await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{'workspaceRoot': workspace.path},
        });
        expect(firstRootSet['isError'], isFalse);
        final approvalRequired =
            firstRootSet['structuredContent'] as Map<Object?, Object?>;
        expect(approvalRequired['status'], 'approval_required');
        final approvalToken = approvalRequired['approvalRequestId'] as String;

        final secondRootSet = await client.request('tools/call', <String, Object?>{
          'name': 'workspace_set_root',
          'arguments': <String, Object?>{
            'workspaceRoot': workspace.path,
            'approvalToken': approvalToken,
          },
        });
        expect(secondRootSet['isError'], isFalse);
        final rootSetStructured =
            secondRootSet['structuredContent'] as Map<Object?, Object?>;
        expect(rootSetStructured['activeRoot'], isNotNull);

        final resources = await client.request('resources/list');
        final uris = (resources['resources'] as List<Object?>)
            .cast<Map<Object?, Object?>>()
            .map((Map<Object?, Object?> resource) => resource['uri'])
            .toSet();
        expect(uris, contains('config://adapters/current'));

        final getStatus = await client.getStatusCode();
        expect(getStatus, HttpStatus.methodNotAllowed);

        final deleteStatus = await client.deleteSession();
        expect(deleteStatus, HttpStatus.noContent);

        final afterDelete = await client.rawRequest(
          'tools/list',
          const <String, Object?>{},
        );
        expect(afterDelete.statusCode, HttpStatus.notFound);
      },
    );

    test('normalizes HTTP preview failures and expires idle sessions', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-http');
      addTearDown(() => sandbox.delete(recursive: true));

      final stateDir = Directory(p.join(sandbox.path, 'state'));
      final client = await _HttpTestMcpClient.start(
        repoRoot: Directory.current.path,
        stateDir: stateDir.path,
        allowRootFallback: true,
        httpPreviewSessionExpiryMinutesOverride: 0.01,
      );
      addTearDown(client.close);

      await client.request('initialize', <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': const <String, Object?>{},
        'clientInfo': <String, Object?>{
          'name': 'http-test-client',
          'version': '1.0.0',
        },
      });
      await client.notify('notifications/initialized');

      final invalidOrigin = await client.rawRequest(
        'tools/list',
        const <String, Object?>{},
        headers: <String, String>{'Origin': 'https://example.com'},
      );
      expect(invalidOrigin.statusCode, HttpStatus.forbidden);
      expect(
        ((jsonDecode(invalidOrigin.body) as Map<String, Object?>)['error']
                as Map<String, Object?>)['code'],
        'HTTP_PREVIEW_INVALID_ORIGIN',
      );

      final invalidProtocol = await client.rawRequest(
        'tools/list',
        const <String, Object?>{},
        includeProtocolVersion: false,
      );
      expect(invalidProtocol.statusCode, HttpStatus.badRequest);
      expect(
        ((jsonDecode(invalidProtocol.body) as Map<String, Object?>)['error']
                as Map<String, Object?>)['code'],
        'HTTP_PREVIEW_INVALID_PROTOCOL',
      );

      await Future<void>.delayed(const Duration(milliseconds: 900));

      final expired = await client.rawRequest(
        'tools/list',
        const <String, Object?>{},
      );
      expect(expired.statusCode, HttpStatus.notFound);
      expect(
        ((jsonDecode(expired.body) as Map<String, Object?>)['error']
                as Map<String, Object?>)['code'],
        'HTTP_PREVIEW_SESSION_EXPIRED',
      );
    });
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

Future<void> _writeTextFile(String path, String contents) async {
  await File(path).parent.create(recursive: true);
  await File(path).writeAsString(contents);
}

Future<String> _writeConfigFile(String path, String contents) async {
  await _writeTextFile(path, contents);
  return path;
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, Object?>(
      (Object? key, Object? nested) =>
          MapEntry<String, Object?>(key.toString(), nested),
    );
  }
  return <String, Object?>{};
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
    String? configPath,
    String? profile,
    bool allowRootFallback = false,
  }) async {
    final process = await Process.start(Platform.resolvedExecutable, <String>[
      'run',
      'bin/flutterhelm.dart',
      'serve',
      if (configPath != null) '--config',
      if (configPath != null) configPath,
      if (profile != null) '--profile',
      if (profile != null) profile,
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
      completer.completeError(
        'Protocol error for request $id: ${jsonEncode(error)}',
      );
      return;
    }

    completer.complete(message['result'] as Map<String, Object?>);
  }

  void _send(Map<String, Object?> message) {
    process.stdin.writeln(jsonEncode(message));
  }
}

class _RawHttpResponse {
  const _RawHttpResponse({
    required this.statusCode,
    required this.body,
    required this.headers,
  });

  final int statusCode;
  final String body;
  final HttpHeaders headers;
}

class _HttpTestMcpClient {
  _HttpTestMcpClient._({
    required this.process,
    required this.endpoint,
    required this.httpClient,
  });

  final Process process;
  final Uri endpoint;
  final HttpClient httpClient;
  String? _sessionId;
  String? _protocolVersion;
  int _nextRequestId = 1;

  static Future<_HttpTestMcpClient> start({
    required String repoRoot,
    required String stateDir,
    String? configPath,
    String? profile,
    bool allowRootFallback = false,
    double? httpPreviewSessionExpiryMinutesOverride,
  }) async {
    final environment = <String, String>{
      if (httpPreviewSessionExpiryMinutesOverride != null)
        'FLUTTERHELM_HTTP_PREVIEW_SESSION_EXPIRY_MINUTES_OVERRIDE':
            httpPreviewSessionExpiryMinutesOverride.toString(),
    };
    final process = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        'run',
        'bin/flutterhelm.dart',
        'serve',
        '--transport',
        'http',
        '--http-host',
        '127.0.0.1',
        '--http-port',
        '0',
        '--http-path',
        '/mcp',
        if (configPath != null) '--config',
        if (configPath != null) configPath,
        if (profile != null) '--profile',
        if (profile != null) profile,
        '--state-dir',
        stateDir,
        if (allowRootFallback) '--allow-root-fallback',
      ],
      workingDirectory: repoRoot,
      environment: environment.isEmpty ? null : environment,
    );

    final endpointCompleter = Completer<Uri>();
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          final marker = 'HTTP preview listening on ';
          final index = line.indexOf(marker);
          if (index < 0 || endpointCompleter.isCompleted) {
            return;
          }
          final uriText = line.substring(index + marker.length).trim();
          endpointCompleter.complete(Uri.parse(uriText));
        });

    final endpoint = await endpointCompleter.future.timeout(
      const Duration(seconds: 20),
    );
    return _HttpTestMcpClient._(
      process: process,
      endpoint: endpoint,
      httpClient: HttpClient(),
    );
  }

  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    final id = (_nextRequestId++).toString();
    final raw = await rawRequest(
      method,
      params,
      id: id,
      timeout: timeout,
    );
    if (raw.statusCode != HttpStatus.ok) {
      throw StateError(
        'HTTP request failed with status ${raw.statusCode}: ${raw.body}',
      );
    }
    final decoded = jsonDecode(raw.body) as Map<String, Object?>;
    if (decoded['error'] case final Map<Object?, Object?> error) {
      throw StateError(jsonEncode(error));
    }
    return decoded['result'] as Map<String, Object?>;
  }

  Future<void> notify(
    String method, [
    Map<String, Object?> params = const <String, Object?>{},
    Duration timeout = const Duration(seconds: 10),
  ]) async {
    final raw = await _send(
      <String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        if (params.isNotEmpty) 'params': params,
      },
      timeout: timeout,
    );
    expect(raw.statusCode, anyOf(HttpStatus.accepted, HttpStatus.ok));
  }

  Future<int> getStatusCode() async {
    final request = await httpClient.getUrl(endpoint);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  Future<int> deleteSession() async {
    final request = await httpClient.deleteUrl(endpoint);
    if (_sessionId != null) {
      request.headers.set('MCP-Session-Id', _sessionId!);
    }
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  Future<_RawHttpResponse> rawRequest(
    String method,
    Map<String, Object?> params, {
    String? id,
    Map<String, String>? headers,
    bool includeSessionId = true,
    bool includeProtocolVersion = true,
    Duration timeout = const Duration(seconds: 10),
  }) {
    return _send(
      <String, Object?>{
        'jsonrpc': '2.0',
        if (id != null) 'id': id,
        'method': method,
        'params': params,
      },
      headers: headers,
      includeSessionId: includeSessionId,
      includeProtocolVersion: includeProtocolVersion,
      timeout: timeout,
    );
  }

  Future<_RawHttpResponse> _send(
    Map<String, Object?> payload, {
    Map<String, String>? headers,
    bool includeSessionId = true,
    bool includeProtocolVersion = true,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final request = await httpClient.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    if (includeSessionId && _sessionId != null) {
      request.headers.set('MCP-Session-Id', _sessionId!);
    }
    if (includeProtocolVersion && _protocolVersion != null) {
      request.headers.set('MCP-Protocol-Version', _protocolVersion!);
    }
    headers?.forEach((String key, String value) {
      request.headers.set(key, value);
    });
    request.write(jsonEncode(payload));
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join();
    final sessionIdHeader = response.headers.value('MCP-Session-Id');
    if (sessionIdHeader != null && sessionIdHeader.isNotEmpty) {
      _sessionId = sessionIdHeader;
    }
    if (payload['method'] == 'initialize') {
      _protocolVersion =
          (_asMap(payload['params'])['protocolVersion'] as String?) ??
          '2025-06-18';
    }
    return _RawHttpResponse(
      statusCode: response.statusCode,
      body: body,
      headers: response.headers,
    );
  }

  Future<_RawHttpResponse> getRaw({
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final request = await httpClient.getUrl(endpoint);
    headers?.forEach((String key, String value) {
      request.headers.set(key, value);
    });
    if (_sessionId != null) {
      request.headers.set('MCP-Session-Id', _sessionId!);
    }
    final response = await request.close().timeout(timeout);
    final body = await utf8.decoder.bind(response).join();
    return _RawHttpResponse(
      statusCode: response.statusCode,
      body: body,
      headers: response.headers,
    );
  }

  Future<void> close() async {
    httpClient.close(force: true);
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 1,
    );
  }
}
