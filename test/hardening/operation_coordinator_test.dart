import 'dart:async';

import 'package:flutterhelm/hardening/operation_coordinator.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:test/test.dart';

void main() {
  group('OperationCoordinator', () {
    test('rejects concurrent session operations with SESSION_BUSY', () async {
      final coordinator = OperationCoordinator();
      final blocker = Completer<void>();

      final first = coordinator.runLocked<void>(
        toolName: 'capture_timeline',
        sessionId: 'sess_1',
        action: () => blocker.future,
      );

      await Future<void>.delayed(Duration.zero);

      await expectLater(
        coordinator.runLocked<void>(
          toolName: 'capture_screenshot',
          sessionId: 'sess_1',
          action: () async {},
        ),
        throwsA(
          isA<FlutterHelmToolError>()
              .having((error) => error.code, 'code', 'SESSION_BUSY')
              .having(
                (error) => error.details?['activeTool'],
                'activeTool',
                'capture_timeline',
              ),
        ),
      );

      blocker.complete();
      await first;
    });

    test('rejects concurrent workspace operations with WORKSPACE_BUSY', () async {
      final coordinator = OperationCoordinator();
      final blocker = Completer<void>();

      final first = coordinator.runLocked<void>(
        toolName: 'run_widget_tests',
        workspaceRoot: '/tmp/sample_app',
        action: () => blocker.future,
      );

      await Future<void>.delayed(Duration.zero);

      await expectLater(
        coordinator.runLocked<void>(
          toolName: 'analyze_project',
          workspaceRoot: '/tmp/sample_app',
          action: () async {},
        ),
        throwsA(
          isA<FlutterHelmToolError>()
              .having((error) => error.code, 'code', 'WORKSPACE_BUSY')
              .having(
                (error) => error.details?['busyKey'],
                'busyKey',
                '/tmp/sample_app',
              ),
        ),
      );

      blocker.complete();
      await first;
    });
  });
}
