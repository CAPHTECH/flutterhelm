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

Future<void> _writeTextFile(String path, String contents) async {
  await File(path).parent.create(recursive: true);
  await File(path).writeAsString(contents);
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
