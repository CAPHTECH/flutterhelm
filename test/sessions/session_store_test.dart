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
  });
}
