enum SessionState {
  created,
  starting,
  running,
  attached,
  stopped,
  failed,
  disposed,
}

extension SessionStateWireName on SessionState {
  String get wireName => name;
}

class SessionRecord {
  const SessionRecord({
    required this.sessionId,
    required this.workspaceRoot,
    required this.platform,
    required this.deviceId,
    required this.target,
    required this.flavor,
    required this.mode,
    required this.state,
    required this.pid,
    required this.vmServiceAvailable,
    required this.dtdAvailable,
    required this.createdAt,
    required this.lastSeenAt,
  });

  final String sessionId;
  final String workspaceRoot;
  final String? platform;
  final String? deviceId;
  final String target;
  final String? flavor;
  final String mode;
  final SessionState state;
  final int? pid;
  final bool vmServiceAvailable;
  final bool dtdAvailable;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  factory SessionRecord.context({
    required String sessionId,
    required String workspaceRoot,
    required String target,
    required String mode,
    required String? flavor,
    required DateTime now,
  }) {
    return SessionRecord(
      sessionId: sessionId,
      workspaceRoot: workspaceRoot,
      platform: null,
      deviceId: null,
      target: target,
      flavor: flavor,
      mode: mode,
      state: SessionState.created,
      pid: null,
      vmServiceAvailable: false,
      dtdAvailable: false,
      createdAt: now,
      lastSeenAt: now,
    );
  }

  SessionRecord copyWith({
    String? workspaceRoot,
    String? target,
    String? mode,
    String? flavor,
    SessionState? state,
    DateTime? lastSeenAt,
  }) {
    return SessionRecord(
      sessionId: sessionId,
      workspaceRoot: workspaceRoot ?? this.workspaceRoot,
      platform: platform,
      deviceId: deviceId,
      target: target ?? this.target,
      flavor: flavor ?? this.flavor,
      mode: mode ?? this.mode,
      state: state ?? this.state,
      pid: pid,
      vmServiceAvailable: vmServiceAvailable,
      dtdAvailable: dtdAvailable,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sessionId': sessionId,
      'workspaceRoot': workspaceRoot,
      'platform': platform,
      'deviceId': deviceId,
      'target': target,
      'flavor': flavor,
      'mode': mode,
      'state': state.wireName,
      'pid': pid,
      'vmService': <String, Object?>{'available': vmServiceAvailable},
      'dtd': <String, Object?>{'available': dtdAvailable},
      'adapters': const <String, Object?>{
        'delegate': 'dart_flutter_mcp',
        'launcher': 'flutter_cli',
        'profiling': 'dtd',
        'runtimeDriver': null,
      },
      'createdAt': createdAt.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
    };
  }

  Map<String, Object?> toSummaryJson() {
    return <String, Object?>{
      'sessionId': sessionId,
      'workspaceRoot': workspaceRoot,
      'target': target,
      'mode': mode,
      'state': state.wireName,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
    };
  }
}
