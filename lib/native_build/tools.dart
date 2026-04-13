import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/platform_bridge/support.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';

typedef NativeBuildFamilyStatusReader =
    Future<Map<String, Object?>> Function(String family);
typedef NativeBuildFamilyInvoker =
    Future<Map<String, Object?>> Function({
      required String family,
      required String operation,
      required Map<String, Object?> input,
    });
typedef NativeBuildAppStateBuilder =
    Future<Map<String, Object?>> Function(SessionRecord session);

class NativeBuildToolService {
  NativeBuildToolService({
    required this.sessionStore,
    required this.artifactStore,
    required this.familyStatus,
    required this.invokeFamily,
    required this.appStateBuilder,
  });

  final SessionStore sessionStore;
  final ArtifactStore artifactStore;
  final NativeBuildFamilyStatusReader familyStatus;
  final NativeBuildFamilyInvoker invokeFamily;
  final NativeBuildAppStateBuilder appStateBuilder;

  Future<Map<String, Object?>> nativeProjectInspect({
    required String workspaceRoot,
    required String platform,
  }) async {
    final status = await _requireNativeBuildProvider();
    final payload = await invokeFamily(
      family: 'nativeBuild',
      operation: 'inspect_project',
      input: <String, Object?>{
        'workspaceRoot': workspaceRoot,
        'platform': platform,
      },
    );
    final openPaths = collectNativeBridgeOpenPathsSync(workspaceRoot, platform)
        .map((NativeBridgePathHint hint) => hint.toJson())
        .toList();
    final fileHints = collectNativeBridgeFileHintsSync(workspaceRoot, platform)
        .map((NativeBridgePathHint hint) => hint.toJson())
        .toList();
    return <String, Object?>{
      'workspaceRoot': workspaceRoot,
      'platform': platform,
      'providerId': status['activeProviderId'],
      'status': payload['status'] ?? 'ready',
      'projectPath': payload['projectPath'] ?? '',
      'workspacePath': payload['workspacePath'] ?? '',
      'schemes': _stringList(payload['schemes']),
      'destinations': _stringList(payload['destinations']),
      'openPaths': openPaths,
      'fileHints': fileHints,
      if (payload['notes'] != null) 'notes': payload['notes'],
    };
  }

  Future<Map<String, Object?>> nativeBuildLaunch({
    required String workspaceRoot,
    required String platform,
    required String target,
    required String mode,
    String? scheme,
    String? configuration,
    String? destination,
    bool attachFlutterRuntime = false,
  }) async {
    final status = await _requireNativeBuildProvider();
    final providerPayload = await invokeFamily(
      family: 'nativeBuild',
      operation: 'build_launch',
      input: <String, Object?>{
        'workspaceRoot': workspaceRoot,
        'platform': platform,
        'target': target,
        'mode': mode,
        if (scheme != null && scheme.isNotEmpty) 'scheme': scheme,
        if (configuration != null && configuration.isNotEmpty)
          'configuration': configuration,
        if (destination != null && destination.isNotEmpty)
          'destination': destination,
      },
    );

    final nativeContext = NativeContext(
      providerId: status['activeProviderId'] as String? ?? '',
      platform: platform,
      projectPath: providerPayload['projectPath'] as String? ?? '',
      workspacePath:
          providerPayload['workspacePath'] as String? ?? workspaceRoot,
      scheme: providerPayload['scheme'] as String? ?? (scheme ?? ''),
      configuration:
          providerPayload['configuration'] as String? ??
          (configuration ?? _defaultConfigurationForMode(mode)),
      destination:
          providerPayload['destination'] as String? ??
          (destination ?? ''),
      buildId: providerPayload['buildId'] as String? ?? _buildId(),
      launchStatus: providerPayload['launchStatus'] as String? ?? 'launched',
      nativeDebuggerAttached:
          providerPayload['nativeDebuggerAttached'] as bool? ?? false,
      flutterRuntimeAttached: false,
      nativeAppId: providerPayload['nativeAppId'] as String?,
    );

    var session = sessionStore.createNativeOwnedSession(
      workspaceRoot: workspaceRoot,
      platform: platform,
      deviceId: providerPayload['deviceId'] as String?,
      target: target,
      mode: mode,
      flavor: null,
      nativeContext: nativeContext,
      pid: providerPayload['pid'] as int?,
    );
    await _writeNativeArtifacts(
      session: session,
      buildLogLines: _lines(payload: providerPayload['buildLogLines']),
      deviceLogLines: _lines(payload: providerPayload['deviceLogLines']),
    );
    await _writeAppState(session);

    Map<String, Object?>? attachResult;
    final debugUrl = providerPayload['debugUrl'] as String?;
    final appId =
        providerPayload['appId'] as String? ??
        providerPayload['nativeAppId'] as String?;
    if (attachFlutterRuntime && debugUrl != null && debugUrl.isNotEmpty) {
      attachResult = await nativeAttachFlutterRuntime(
        sessionId: session.sessionId,
        debugUrl: debugUrl,
        appId: appId,
        deviceId: providerPayload['deviceId'] as String?,
      );
      session = sessionStore.requireById(session.sessionId, touch: false);
    }

    return <String, Object?>{
      'sessionId': session.sessionId,
      'status': attachResult == null ? 'launched' : 'flutter_attached',
      'session': session.toJson(),
      'nativeContext': session.nativeContext?.toJson(),
      'runtimeAttachHints': <String, Object?>{
        if (debugUrl != null) 'debugUrl': debugUrl,
        if (appId != null) 'appId': appId,
        if (providerPayload['deviceId'] != null)
          'deviceId': providerPayload['deviceId'],
      },
      'resources': _sessionResources(session.sessionId),
    };
  }

  Future<Map<String, Object?>> nativeAttachFlutterRuntime({
    required String sessionId,
    String? debugUrl,
    String? appId,
    String? deviceId,
  }) async {
    final session = sessionStore.requireById(sessionId);
    final nativeContext = session.nativeContext;
    if (nativeContext == null) {
      throw FlutterHelmToolError(
        code: 'NATIVE_PROJECT_UNAVAILABLE',
        category: 'runtime',
        message: 'native_attach_flutter_runtime requires a native-launched session.',
        retryable: false,
      );
    }
    final rawVmServiceUri = debugUrl;
    if (rawVmServiceUri == null || rawVmServiceUri.isEmpty) {
      throw FlutterHelmToolError(
        code: 'NATIVE_FLUTTER_ATTACH_FAILED',
        category: 'runtime',
        message:
            'native_attach_flutter_runtime requires debugUrl when no live Flutter runtime is already associated with the session.',
        retryable: true,
      );
    }

    await sessionStore.detachLiveHandle(sessionId);
    sessionStore.attachLiveHandle(
      sessionId,
      LiveSessionHandle(
        process: null,
        stdoutPath: '',
        stderrPath: '',
        machinePath: '',
        managedAppProcess: false,
        supportsHotOperations: false,
        vmServiceUri: rawVmServiceUri,
      ),
    );
    final updated = sessionStore.attachFlutterRuntimeToSession(
      sessionId: sessionId,
      platform: session.platform ?? nativeContext.platform,
      deviceId: deviceId ?? session.deviceId,
      pid: session.pid,
      appId: appId ?? nativeContext.nativeAppId,
      vmServiceAvailable: true,
      vmServiceMaskedUri: _maskUri(rawVmServiceUri),
      dtdAvailable: false,
      dtdMaskedUri: null,
    );
    await _writeAppState(updated);
    await _writeNativeSummary(updated);
    return <String, Object?>{
      'sessionId': updated.sessionId,
      'status': 'flutter_attached',
      'session': updated.toJson(),
      'resource': _resourceLink(
        'session://${updated.sessionId}/summary',
        'application/json',
        'Session summary',
      ),
      'resources': _sessionResources(updated.sessionId),
    };
  }

  Future<Map<String, Object?>> nativeStop({required String sessionId}) async {
    final session = sessionStore.requireById(sessionId);
    if (session.stale) {
      throw FlutterHelmToolError(
        code: 'SESSION_STALE',
        category: 'runtime',
        message: 'The target session is stale and cannot be mutated.',
        retryable: true,
      );
    }
    if (session.ownership != SessionOwnership.owned ||
        session.nativeContext == null) {
      throw FlutterHelmToolError(
        code: 'NATIVE_SESSION_STOP_FORBIDDEN',
        category: 'runtime',
        message: 'native_stop is only allowed for owned native-build sessions.',
        retryable: false,
      );
    }

    final payload = await invokeFamily(
      family: 'nativeBuild',
      operation: 'stop',
      input: <String, Object?>{
        'sessionId': session.sessionId,
        'platform': session.nativeContext!.platform,
        'buildId': session.nativeContext!.buildId,
        'projectPath': session.nativeContext!.projectPath,
        'workspacePath': session.nativeContext!.workspacePath,
      },
    );
    final updated = sessionStore.replace(
      session.copyWith(
        state: SessionState.stopped,
        stale: false,
        profileActive: false,
        nativeContext: session.nativeContext!.copyWith(
          launchStatus: 'stopped',
          flutterRuntimeAttached: false,
        ),
        lastSeenAt: DateTime.now().toUtc(),
        lastExitAt: DateTime.now().toUtc(),
        lastExitCode: 0,
      ),
    );
    await _writeNativeArtifacts(
      session: updated,
      buildLogLines: _lines(payload: payload['buildLogLines']),
      deviceLogLines: _lines(payload: payload['deviceLogLines']),
    );
    await sessionStore.detachLiveHandle(sessionId);
    await _writeAppState(updated);
    return <String, Object?>{
      'sessionId': updated.sessionId,
      'status': 'stopped',
      'session': updated.toJson(),
      'resources': _sessionResources(updated.sessionId),
    };
  }

  Future<Map<String, Object?>> _requireNativeBuildProvider() async {
    final status = await familyStatus('nativeBuild');
    final activeProviderId = status['activeProviderId'] as String?;
    if (activeProviderId == null || activeProviderId.isEmpty) {
      throw FlutterHelmToolError(
        code: 'NATIVE_BUILD_PROVIDER_UNAVAILABLE',
        category: 'runtime',
        message: 'No nativeBuild provider is configured.',
        retryable: false,
        detailsResource: _resourceLink(
          'config://adapters/current',
          'application/json',
          'Current adapter registry state',
        ),
      );
    }
    if (status['healthy'] != true) {
      throw FlutterHelmToolError(
        code: 'NATIVE_BUILD_PROVIDER_UNAVAILABLE',
        category: 'runtime',
        message:
            (status['reason'] as String?) ??
            'The active nativeBuild provider is unhealthy.',
        retryable: true,
        detailsResource: _resourceLink(
          'config://adapters/current',
          'application/json',
          'Current adapter registry state',
        ),
      );
    }
    return status;
  }

  Future<void> _writeNativeArtifacts({
    required SessionRecord session,
    required List<String> buildLogLines,
    required List<String> deviceLogLines,
  }) async {
    for (final line in buildLogLines) {
      await artifactStore.appendSessionNativeLog(
        sessionId: session.sessionId,
        stream: 'native-build',
        line: line,
      );
    }
    for (final line in deviceLogLines) {
      await artifactStore.appendSessionNativeLog(
        sessionId: session.sessionId,
        stream: 'native-device',
        line: line,
      );
    }
    await _writeNativeSummary(session);
  }

  Future<void> _writeNativeSummary(SessionRecord session) async {
    await artifactStore.writeSessionNativeSummary(
      sessionId: session.sessionId,
      payload: <String, Object?>{
        'sessionId': session.sessionId,
        'workspaceRoot': session.workspaceRoot,
        'state': session.state.wireName,
        'ownership': session.ownership.wireName,
        'stale': session.stale,
        'nativeContext': session.nativeContext?.toJson(),
        'resources': _sessionResources(session.sessionId),
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  Future<void> _writeAppState(SessionRecord session) async {
    final payload = await appStateBuilder(session);
    await artifactStore.writeSessionAppState(
      sessionId: session.sessionId,
      payload: payload,
    );
  }

  List<Map<String, Object?>> _sessionResources(String sessionId) {
    return <Map<String, Object?>>[
      _resourceLink(
        'session://$sessionId/summary',
        'application/json',
        'Session summary',
      ),
      _resourceLink(
        artifactStore.sessionNativeSummaryUri(sessionId),
        'application/json',
        'Native session summary',
      ),
      _resourceLink(
        artifactStore.sessionNativeLogUri(sessionId, 'native-build'),
        'text/plain',
        'Native build log',
      ),
      _resourceLink(
        artifactStore.sessionNativeLogUri(sessionId, 'native-device'),
        'text/plain',
        'Native device log',
      ),
    ];
  }

  List<String> _lines({required Object? payload}) {
    if (payload is List) {
      return payload
          .whereType<Object?>()
          .map((Object? line) => line?.toString() ?? '')
          .where((String line) => line.isNotEmpty)
          .toList();
    }
    if (payload is String && payload.trim().isNotEmpty) {
      return payload
          .split('\n')
          .map((String line) => line.trimRight())
          .where((String line) => line.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  String _defaultConfigurationForMode(String mode) {
    return switch (mode) {
      'release' => 'Release',
      'profile' => 'Profile',
      _ => 'Debug',
    };
  }

  String _buildId() {
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'native_${micros.toRadixString(36)}';
  }

  String? _maskUri(String? uri) {
    if (uri == null || uri.isEmpty) {
      return null;
    }
    final parsed = Uri.tryParse(uri);
    if (parsed == null) {
      return uri;
    }
    final host = parsed.host.isEmpty ? 'localhost' : parsed.host;
    final port = parsed.hasPort ? ':${parsed.port}' : '';
    final path = parsed.path.isEmpty ? '' : parsed.path;
    return '${parsed.scheme}://$host$port$path';
  }

  Map<String, Object?> _resourceLink(
    String uri,
    String mimeType,
    String title,
  ) {
    return <String, Object?>{
      'uri': uri,
      'mimeType': mimeType,
      'title': title,
    };
  }

  List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .whereType<String>()
          .where((String item) => item.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }
}
