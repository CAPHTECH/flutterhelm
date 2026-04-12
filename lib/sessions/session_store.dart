import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';

class SessionStore {
  final Map<String, SessionRecord> _sessions = <String, SessionRecord>{};
  int _counter = 0;

  SessionRecord createContextSession({
    required String workspaceRoot,
    required String target,
    required String mode,
    required String? flavor,
    DateTime Function()? now,
  }) {
    final clock = now ?? DateTime.now;
    final createdAt = clock().toUtc();
    final sessionId =
        'sess_${createdAt.microsecondsSinceEpoch.toRadixString(36)}_${(_counter++).toRadixString(36)}';
    final session = SessionRecord.context(
      sessionId: sessionId,
      workspaceRoot: workspaceRoot,
      target: target,
      mode: mode,
      flavor: flavor,
      now: createdAt,
    );
    _sessions[sessionId] = session;
    return session;
  }

  List<SessionRecord> listActiveSessions() {
    return _sessions.values
        .where(
          (SessionRecord session) => session.state != SessionState.disposed,
        )
        .toList()
      ..sort(
        (SessionRecord left, SessionRecord right) =>
            left.createdAt.compareTo(right.createdAt),
      );
  }

  SessionRecord? getById(String sessionId, {bool touch = true}) {
    final session = _sessions[sessionId];
    if (session == null) {
      return null;
    }
    if (!touch) {
      return session;
    }
    final updated = session.copyWith(lastSeenAt: DateTime.now().toUtc());
    _sessions[sessionId] = updated;
    return updated;
  }

  SessionRecord updateState(String sessionId, SessionState nextState) {
    final current = _sessions[sessionId];
    if (current == null) {
      throw FlutterHelmToolError(
        code: 'SESSION_NOT_FOUND',
        category: 'runtime',
        message: 'Unknown session: $sessionId',
        retryable: false,
      );
    }

    if (current.state == nextState) {
      return current;
    }

    final allowedNextStates =
        _allowedTransitions[current.state] ?? <SessionState>{};
    if (!allowedNextStates.contains(nextState)) {
      throw FlutterHelmToolError(
        code: 'INVALID_SESSION_TRANSITION',
        category: 'runtime',
        message:
            'Session transition ${current.state.wireName} -> ${nextState.wireName} is not allowed.',
        retryable: false,
      );
    }

    final updated = current.copyWith(
      state: nextState,
      lastSeenAt: DateTime.now().toUtc(),
    );
    _sessions[sessionId] = updated;
    return updated;
  }
}

const Map<SessionState, Set<SessionState>> _allowedTransitions =
    <SessionState, Set<SessionState>>{
      SessionState.created: <SessionState>{
        SessionState.starting,
        SessionState.attached,
      },
      SessionState.starting: <SessionState>{
        SessionState.running,
        SessionState.failed,
      },
      SessionState.running: <SessionState>{
        SessionState.stopped,
        SessionState.failed,
        SessionState.attached,
      },
      SessionState.attached: <SessionState>{
        SessionState.running,
        SessionState.stopped,
      },
      SessionState.failed: <SessionState>{SessionState.disposed},
      SessionState.stopped: <SessionState>{SessionState.disposed},
    };
