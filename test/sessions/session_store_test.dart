import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:flutterhelm/flutterhelm.dart';
import 'package:test/test.dart';

void main() {
  group('SessionStore', () {
    test('creates context sessions with created state', () {
      final store = SessionStore();
      final session = store.createContextSession(
        workspaceRoot: '/work/app',
        target: 'lib/main.dart',
        mode: 'debug',
        flavor: null,
        now: () => DateTime.utc(2026, 4, 12, 12),
      );

      expect(session.state, SessionState.created);
      expect(session.workspaceRoot, '/work/app');
      expect(store.listActiveSessions(), hasLength(1));
    });

    test('enforces documented state transitions', () {
      final store = SessionStore();
      final session = store.createContextSession(
        workspaceRoot: '/work/app',
        target: 'lib/main.dart',
        mode: 'debug',
        flavor: null,
      );

      store.updateState(session.sessionId, SessionState.starting);
      store.updateState(session.sessionId, SessionState.running);

      expect(
        () => store.updateState(session.sessionId, SessionState.created),
        throwsA(isA<FlutterHelmToolError>()),
      );
    });

    test('restores running sessions as stale and clears active profiling', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-session-store');
      addTearDown(() => sandbox.delete(recursive: true));

      final store = await SessionStore.create(stateDir: sandbox.path);
      final session = store.createContextSession(
        workspaceRoot: '/work/app',
        target: 'lib/main.dart',
        mode: 'profile',
        flavor: null,
      );
      store.transitionContextToOwned(
        sessionId: session.sessionId,
        platform: 'ios',
        deviceId: 'sim-1',
        pid: 1234,
        appId: 'app-1',
        vmServiceMaskedUri: 'ws://127.0.0.1:1234/...',
        dtdMaskedUri: null,
        vmServiceAvailable: true,
        dtdAvailable: false,
      );
      store.setProfileActive(session.sessionId, true);

      final file = File(p.join(sandbox.path, 'sessions.json'));
      for (var attempt = 0; attempt < 20; attempt += 1) {
        if (await file.exists() &&
            (await file.readAsString()).contains(session.sessionId)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final reloaded = await SessionStore.create(stateDir: sandbox.path);
      final restored = reloaded.requireById(session.sessionId);
      expect(restored.stale, isTrue);
      expect(restored.state, SessionState.stopped);
      expect(restored.profileActive, isFalse);
      expect(await file.exists(), isTrue);
    });
  });
}
