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

enum SessionOwnership { context, owned, attached }

extension SessionOwnershipWireName on SessionOwnership {
  String get wireName => name;
}

class NativeContext {
  const NativeContext({
    required this.providerId,
    required this.platform,
    required this.projectPath,
    required this.workspacePath,
    required this.scheme,
    required this.configuration,
    required this.destination,
    required this.buildId,
    required this.launchStatus,
    required this.nativeDebuggerAttached,
    required this.flutterRuntimeAttached,
    this.nativeAppId,
  });

  final String providerId;
  final String platform;
  final String projectPath;
  final String workspacePath;
  final String scheme;
  final String configuration;
  final String destination;
  final String buildId;
  final String launchStatus;
  final bool nativeDebuggerAttached;
  final bool flutterRuntimeAttached;
  final String? nativeAppId;

  NativeContext copyWith({
    String? providerId,
    String? platform,
    String? projectPath,
    String? workspacePath,
    String? scheme,
    String? configuration,
    String? destination,
    String? buildId,
    String? launchStatus,
    bool? nativeDebuggerAttached,
    bool? flutterRuntimeAttached,
    String? nativeAppId,
  }) {
    return NativeContext(
      providerId: providerId ?? this.providerId,
      platform: platform ?? this.platform,
      projectPath: projectPath ?? this.projectPath,
      workspacePath: workspacePath ?? this.workspacePath,
      scheme: scheme ?? this.scheme,
      configuration: configuration ?? this.configuration,
      destination: destination ?? this.destination,
      buildId: buildId ?? this.buildId,
      launchStatus: launchStatus ?? this.launchStatus,
      nativeDebuggerAttached:
          nativeDebuggerAttached ?? this.nativeDebuggerAttached,
      flutterRuntimeAttached:
          flutterRuntimeAttached ?? this.flutterRuntimeAttached,
      nativeAppId: nativeAppId ?? this.nativeAppId,
    );
  }

  factory NativeContext.fromJson(Map<String, Object?> json) {
    return NativeContext(
      providerId: json['providerId'] as String? ?? '',
      platform: json['platform'] as String? ?? '',
      projectPath: json['projectPath'] as String? ?? '',
      workspacePath: json['workspacePath'] as String? ?? '',
      scheme: json['scheme'] as String? ?? '',
      configuration: json['configuration'] as String? ?? '',
      destination: json['destination'] as String? ?? '',
      buildId: json['buildId'] as String? ?? '',
      launchStatus: json['launchStatus'] as String? ?? 'unknown',
      nativeDebuggerAttached:
          json['nativeDebuggerAttached'] as bool? ?? false,
      flutterRuntimeAttached:
          json['flutterRuntimeAttached'] as bool? ?? false,
      nativeAppId: json['nativeAppId'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'providerId': providerId,
      'platform': platform,
      'projectPath': projectPath,
      'workspacePath': workspacePath,
      'scheme': scheme,
      'configuration': configuration,
      'destination': destination,
      'buildId': buildId,
      'launchStatus': launchStatus,
      'nativeDebuggerAttached': nativeDebuggerAttached,
      'flutterRuntimeAttached': flutterRuntimeAttached,
      if (nativeAppId != null) 'nativeAppId': nativeAppId,
    };
  }
}

class SessionRecord {
  const SessionRecord({
    required this.sessionId,
    required this.workspaceRoot,
    required this.ownership,
    required this.platform,
    required this.deviceId,
    required this.target,
    required this.flavor,
    required this.mode,
    required this.state,
    required this.stale,
    required this.pid,
    required this.appId,
    required this.vmServiceAvailable,
    required this.vmServiceMaskedUri,
    required this.dtdAvailable,
    required this.dtdMaskedUri,
    required this.profileActive,
    required this.createdAt,
    required this.lastSeenAt,
    required this.lastExitAt,
    required this.lastExitCode,
    this.nativeContext,
  });

  final String sessionId;
  final String workspaceRoot;
  final SessionOwnership ownership;
  final String? platform;
  final String? deviceId;
  final String target;
  final String? flavor;
  final String mode;
  final SessionState state;
  final bool stale;
  final int? pid;
  final String? appId;
  final bool vmServiceAvailable;
  final String? vmServiceMaskedUri;
  final bool dtdAvailable;
  final String? dtdMaskedUri;
  final bool profileActive;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime? lastExitAt;
  final int? lastExitCode;
  final NativeContext? nativeContext;

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
      ownership: SessionOwnership.context,
      platform: null,
      deviceId: null,
      target: target,
      flavor: flavor,
      mode: mode,
      state: SessionState.created,
      stale: false,
      pid: null,
      appId: null,
      vmServiceAvailable: false,
      vmServiceMaskedUri: null,
      dtdAvailable: false,
      dtdMaskedUri: null,
      profileActive: false,
      createdAt: now,
      lastSeenAt: now,
      lastExitAt: null,
      lastExitCode: null,
    );
  }

  SessionRecord copyWith({
    SessionOwnership? ownership,
    String? workspaceRoot,
    String? platform,
    String? deviceId,
    String? target,
    String? mode,
    String? flavor,
    SessionState? state,
    bool? stale,
    int? pid,
    bool clearPid = false,
    String? appId,
    bool? vmServiceAvailable,
    String? vmServiceMaskedUri,
    bool clearVmServiceMaskedUri = false,
    bool? dtdAvailable,
    String? dtdMaskedUri,
    bool clearDtdMaskedUri = false,
    bool? profileActive,
    DateTime? lastSeenAt,
    DateTime? lastExitAt,
    int? lastExitCode,
    NativeContext? nativeContext,
    bool clearNativeContext = false,
  }) {
    return SessionRecord(
      sessionId: sessionId,
      ownership: ownership ?? this.ownership,
      workspaceRoot: workspaceRoot ?? this.workspaceRoot,
      platform: platform ?? this.platform,
      deviceId: deviceId ?? this.deviceId,
      target: target ?? this.target,
      flavor: flavor ?? this.flavor,
      mode: mode ?? this.mode,
      state: state ?? this.state,
      stale: stale ?? this.stale,
      pid: clearPid ? null : (pid ?? this.pid),
      appId: appId ?? this.appId,
      vmServiceAvailable: vmServiceAvailable ?? this.vmServiceAvailable,
      vmServiceMaskedUri: clearVmServiceMaskedUri
          ? null
          : (vmServiceMaskedUri ?? this.vmServiceMaskedUri),
      dtdAvailable: dtdAvailable ?? this.dtdAvailable,
      dtdMaskedUri: clearDtdMaskedUri
          ? null
          : (dtdMaskedUri ?? this.dtdMaskedUri),
      profileActive: profileActive ?? this.profileActive,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      lastExitAt: lastExitAt ?? this.lastExitAt,
      lastExitCode: lastExitCode ?? this.lastExitCode,
      nativeContext: clearNativeContext
          ? null
          : (nativeContext ?? this.nativeContext),
    );
  }

  factory SessionRecord.fromJson(Map<String, Object?> json) {
    return SessionRecord(
      sessionId: json['sessionId'] as String,
      workspaceRoot: json['workspaceRoot'] as String,
      ownership: SessionOwnership.values.byName(
        json['ownership'] as String? ?? SessionOwnership.context.name,
      ),
      platform: json['platform'] as String?,
      deviceId: json['deviceId'] as String?,
      target: json['target'] as String,
      flavor: json['flavor'] as String?,
      mode: json['mode'] as String,
      state: SessionState.values.byName(json['state'] as String),
      stale: json['stale'] as bool? ?? false,
      pid: json['pid'] as int?,
      appId: json['appId'] as String?,
      vmServiceAvailable:
          (json['vmService'] as Map<Object?, Object?>?)?['available'] == true,
      vmServiceMaskedUri:
          (json['vmService'] as Map<Object?, Object?>?)?['maskedUri'] as String?,
      dtdAvailable:
          (json['dtd'] as Map<Object?, Object?>?)?['available'] == true,
      dtdMaskedUri:
          (json['dtd'] as Map<Object?, Object?>?)?['maskedUri'] as String?,
      profileActive: json['profileActive'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String).toUtc(),
      lastSeenAt: DateTime.parse(json['lastSeenAt'] as String).toUtc(),
      lastExitAt: json['lastExitAt'] is String
          ? DateTime.parse(json['lastExitAt'] as String).toUtc()
          : null,
      lastExitCode: json['lastExitCode'] as int?,
      nativeContext: json['nativeContext'] is Map<Object?, Object?>
          ? NativeContext.fromJson(
              (json['nativeContext'] as Map<Object?, Object?>).map<String, Object?>(
                (Object? key, Object? value) =>
                    MapEntry<String, Object?>(key.toString(), value),
              ),
            )
          : null,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sessionId': sessionId,
      'workspaceRoot': workspaceRoot,
      'ownership': ownership.wireName,
      'platform': platform,
      'deviceId': deviceId,
      'target': target,
      'flavor': flavor,
      'mode': mode,
      'state': state.wireName,
      'stale': stale,
      'pid': pid,
      'appId': appId,
      'vmService': <String, Object?>{
        'available': vmServiceAvailable,
        if (vmServiceMaskedUri != null) 'maskedUri': vmServiceMaskedUri,
      },
      'dtd': <String, Object?>{
        'available': dtdAvailable,
        if (dtdMaskedUri != null) 'maskedUri': dtdMaskedUri,
      },
      'profileActive': profileActive,
      'adapters': <String, Object?>{
        'delegate': 'dart_flutter_mcp',
        'launcher': 'flutter_cli',
        'profiling': 'vm_service',
        'runtimeDriver': null,
        'nativeBuild': nativeContext?.providerId,
      },
      if (nativeContext != null) 'nativeContext': nativeContext!.toJson(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
      'lastExitAt': lastExitAt?.toUtc().toIso8601String(),
      'lastExitCode': lastExitCode,
    };
  }

  Map<String, Object?> toSummaryJson() {
    return <String, Object?>{
      'sessionId': sessionId,
      'workspaceRoot': workspaceRoot,
      'ownership': ownership.wireName,
      'platform': platform,
      'deviceId': deviceId,
      'target': target,
      'flavor': flavor,
      'mode': mode,
      'state': state.wireName,
      'stale': stale,
      'profileActive': profileActive,
      'pid': pid,
      if (nativeContext != null) 'nativeContext': nativeContext!.toJson(),
      'createdAt': createdAt.toUtc().toIso8601String(),
      'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
    };
  }
}
