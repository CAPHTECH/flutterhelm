import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:path/path.dart' as p;

class LiveSessionHandle {
  LiveSessionHandle({
    this.process,
    required this.stdoutPath,
    required this.stderrPath,
    required this.machinePath,
    this.vmServiceUri,
    this.dtdUri,
  });

  final Process? process;
  final String stdoutPath;
  final String stderrPath;
  final String machinePath;
  String? vmServiceUri;
  String? dtdUri;
  StreamSubscription<String>? stdoutSubscription;
  StreamSubscription<String>? stderrSubscription;
  StreamSubscription<String>? machineSubscription;

  Future<void> dispose() async {
    await stdoutSubscription?.cancel();
    await stderrSubscription?.cancel();
    await machineSubscription?.cancel();
  }
}

class SessionStore {
  SessionStore({String? sessionsFilePath})
    : _sessionsFilePath =
          sessionsFilePath ??
          p.join(Directory.systemTemp.path, 'flutterhelm_sessions_test.json');

  SessionStore._(this._sessionsFilePath);

  final String _sessionsFilePath;
  final Map<String, SessionRecord> _sessions = <String, SessionRecord>{};
  final Map<String, LiveSessionHandle> _liveHandles = <String, LiveSessionHandle>{};
  int _counter = 0;

  static Future<SessionStore> create({required String stateDir}) async {
    final store = SessionStore._(p.join(stateDir, 'sessions.json'));
    await store._load();
    return store;
  }

  Future<void> _load() async {
    final file = File(_sessionsFilePath);
    if (!await file.exists()) {
      return;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      return;
    }

    final sessions = decoded['sessions'];
    if (sessions is! List) {
      return;
    }

    for (final rawSession in sessions) {
      if (rawSession is! Map) {
        continue;
      }
      final session = SessionRecord.fromJson(
        rawSession.map<String, Object?>(
          (Object? key, Object? value) => MapEntry<String, Object?>(key.toString(), value),
        ),
      );
      final restored = _restoreSession(session);
      _sessions[restored.sessionId] = restored;
    }
  }

  SessionRecord _restoreSession(SessionRecord session) {
    if (session.state == SessionState.running ||
        session.state == SessionState.starting ||
        session.state == SessionState.attached) {
      return session.copyWith(
        state: session.ownership == SessionOwnership.attached
            ? SessionState.attached
            : SessionState.stopped,
        stale: true,
        lastSeenAt: DateTime.now().toUtc(),
      );
    }
    return session;
  }

  Future<void> _persist() async {
    final file = File(_sessionsFilePath);
    await file.parent.create(recursive: true);
    final sorted = _sessions.values.toList()
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'sessions': sorted.map((SessionRecord session) => session.toJson()).toList(),
      }),
    );
  }

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
    unawaited(_persist());
    return session;
  }

  SessionRecord createAttachedSession({
    required String workspaceRoot,
    required String platform,
    required String? deviceId,
    required String target,
    required String mode,
    required String? flavor,
    required int? pid,
    required bool vmServiceAvailable,
    required String? vmServiceMaskedUri,
    required bool dtdAvailable,
    required String? dtdMaskedUri,
    String? appId,
  }) {
    final now = DateTime.now().toUtc();
    final sessionId =
        'sess_${now.microsecondsSinceEpoch.toRadixString(36)}_${(_counter++).toRadixString(36)}';
    final session = SessionRecord.context(
      sessionId: sessionId,
      workspaceRoot: workspaceRoot,
      target: target,
      mode: mode,
      flavor: flavor,
      now: now,
    ).copyWith(
      ownership: SessionOwnership.attached,
      platform: platform,
      deviceId: deviceId,
      state: SessionState.attached,
      pid: pid,
      appId: appId,
      vmServiceAvailable: vmServiceAvailable,
      vmServiceMaskedUri: vmServiceMaskedUri,
      dtdAvailable: dtdAvailable,
      dtdMaskedUri: dtdMaskedUri,
      lastSeenAt: now,
    );
    _sessions[session.sessionId] = session;
    unawaited(_persist());
    return session;
  }

  SessionRecord transitionContextToOwned({
    required String sessionId,
    required String platform,
    required String? deviceId,
    required int? pid,
    required String? appId,
    required String? vmServiceMaskedUri,
    required String? dtdMaskedUri,
    required bool vmServiceAvailable,
    required bool dtdAvailable,
  }) {
    final current = requireById(sessionId);
    final updated = current.copyWith(
      ownership: SessionOwnership.owned,
      platform: platform,
      deviceId: deviceId,
      state: SessionState.running,
      stale: false,
      pid: pid,
      appId: appId,
      vmServiceAvailable: vmServiceAvailable,
      vmServiceMaskedUri: vmServiceMaskedUri,
      dtdAvailable: dtdAvailable,
      dtdMaskedUri: dtdMaskedUri,
      lastSeenAt: DateTime.now().toUtc(),
      lastExitAt: null,
      lastExitCode: null,
    );
    _sessions[sessionId] = updated;
    unawaited(_persist());
    return updated;
  }

  SessionRecord createOwnedSession({
    required String workspaceRoot,
    required String platform,
    required String? deviceId,
    required String target,
    required String mode,
    required String? flavor,
    required int? pid,
    required String? appId,
    required String? vmServiceMaskedUri,
    required String? dtdMaskedUri,
    required bool vmServiceAvailable,
    required bool dtdAvailable,
  }) {
    final session = createContextSession(
      workspaceRoot: workspaceRoot,
      target: target,
      mode: mode,
      flavor: flavor,
    );
    return transitionContextToOwned(
      sessionId: session.sessionId,
      platform: platform,
      deviceId: deviceId,
      pid: pid,
      appId: appId,
      vmServiceMaskedUri: vmServiceMaskedUri,
      dtdMaskedUri: dtdMaskedUri,
      vmServiceAvailable: vmServiceAvailable,
      dtdAvailable: dtdAvailable,
    );
  }

  List<SessionRecord> listActiveSessions() {
    return _sessions.values
        .where((SessionRecord session) => session.state != SessionState.disposed)
        .toList()
      ..sort((SessionRecord left, SessionRecord right) => left.createdAt.compareTo(right.createdAt));
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
    unawaited(_persist());
    return updated;
  }

  SessionRecord requireById(String sessionId, {bool touch = true}) {
    final session = getById(sessionId, touch: touch);
    if (session == null) {
      throw FlutterHelmToolError(
        code: 'SESSION_NOT_FOUND',
        category: 'runtime',
        message: 'Unknown session: $sessionId',
        retryable: false,
      );
    }
    return session;
  }

  SessionRecord updateState(
    String sessionId,
    SessionState nextState, {
    bool? stale,
    int? lastExitCode,
    DateTime? lastExitAt,
  }) {
    final current = requireById(sessionId, touch: false);
    if (current.state != nextState) {
      final allowedNextStates = _allowedTransitions[current.state] ?? <SessionState>{};
      if (!allowedNextStates.contains(nextState)) {
        throw FlutterHelmToolError(
          code: 'INVALID_SESSION_TRANSITION',
          category: 'runtime',
          message:
              'Session transition ${current.state.wireName} -> ${nextState.wireName} is not allowed.',
          retryable: false,
        );
      }
    }

    final updated = current.copyWith(
      state: nextState,
      stale: stale ?? current.stale,
      lastSeenAt: DateTime.now().toUtc(),
      lastExitAt: lastExitAt,
      lastExitCode: lastExitCode,
    );
    _sessions[sessionId] = updated;
    unawaited(_persist());
    return updated;
  }

  SessionRecord replace(SessionRecord session) {
    _sessions[session.sessionId] = session;
    unawaited(_persist());
    return session;
  }

  void attachLiveHandle(String sessionId, LiveSessionHandle handle) {
    _liveHandles[sessionId] = handle;
  }

  LiveSessionHandle? liveHandle(String sessionId) => _liveHandles[sessionId];

  Future<void> detachLiveHandle(String sessionId) async {
    final handle = _liveHandles.remove(sessionId);
    if (handle != null) {
      await handle.dispose();
    }
  }
}

const Map<SessionState, Set<SessionState>> _allowedTransitions = <SessionState, Set<SessionState>>{
  SessionState.created: <SessionState>{SessionState.starting, SessionState.attached, SessionState.running},
  SessionState.starting: <SessionState>{SessionState.running, SessionState.failed, SessionState.stopped},
  SessionState.running: <SessionState>{
    SessionState.stopped,
    SessionState.failed,
    SessionState.attached,
  },
  SessionState.attached: <SessionState>{SessionState.running, SessionState.stopped},
  SessionState.failed: <SessionState>{SessionState.disposed},
  SessionState.stopped: <SessionState>{SessionState.disposed},
};
