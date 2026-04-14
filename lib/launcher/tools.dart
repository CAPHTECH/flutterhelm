import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/adapters/registry.dart';
import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/platform_bridge/support.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:flutterhelm/utils/process_runner.dart';
import 'package:path/path.dart' as p;

typedef AppStateSnapshotBuilder =
    Future<Map<String, Object?>> Function(SessionRecord session);

class LauncherToolService {
  LauncherToolService({
    required this.processRunner,
    required this.sessionStore,
    required this.artifactStore,
    required this.flutterExecutable,
    required this.appStateBuilder,
    this.delegateAdapterFactory,
  });

  final ProcessRunner processRunner;
  final SessionStore sessionStore;
  final ArtifactStore artifactStore;
  final String flutterExecutable;
  final AppStateSnapshotBuilder appStateBuilder;
  final Future<DelegateAdapter> Function()? delegateAdapterFactory;

  Future<List<Map<String, Object?>>> listDevices() async {
    final flutterDevices = await _flutterDevices();
    if (!Platform.isMacOS) {
      return flutterDevices;
    }

    final simulators = await _iosSimulators();
    final knownIds = flutterDevices.map((Map<String, Object?> device) => device['deviceId']).toSet();
    for (final simulator in simulators) {
      if (!knownIds.contains(simulator['deviceId'])) {
        flutterDevices.add(simulator);
      }
    }
    flutterDevices.sort((left, right) {
      final leftPlatform = left['platform'] as String? ?? '';
      final rightPlatform = right['platform'] as String? ?? '';
      final platformCompare = leftPlatform.compareTo(rightPlatform);
      if (platformCompare != 0) {
        return platformCompare;
      }
      return (left['name'] as String? ?? '').compareTo(right['name'] as String? ?? '');
    });
    return flutterDevices;
  }

  Future<String> resolveLaunchDeviceId({
    required String platform,
    String? deviceId,
  }) {
    return _resolveLaunchDeviceId(platform: platform, deviceId: deviceId);
  }

  Future<void> ensureIosSimulatorBooted(String deviceId) {
    return _ensureIosSimulatorBooted(deviceId);
  }

  Future<SessionRecord> runApp({
    required String workspaceRoot,
    required String target,
    required String platform,
    required String mode,
    required String? flavor,
    required List<String> dartDefines,
    String? deviceId,
    String? sessionId,
  }) async {
    final selectedDeviceId = await _resolveLaunchDeviceId(platform: platform, deviceId: deviceId);
    if (platform == 'ios') {
      await _ensureIosSimulatorBooted(selectedDeviceId);
    }

    SessionRecord record;
    if (sessionId != null) {
      final current = sessionStore.requireById(sessionId);
      record = sessionStore.updateState(current.sessionId, SessionState.starting);
    } else {
      record = sessionStore.createContextSession(
        workspaceRoot: workspaceRoot,
        target: target,
        mode: mode,
        flavor: flavor,
      );
      record = sessionStore.updateState(record.sessionId, SessionState.starting);
    }

    final pidFile = p.join(artifactStore.sessionArtifactsDir(record.sessionId), 'flutter.pid');
    await Directory(artifactStore.sessionArtifactsDir(record.sessionId)).create(recursive: true);

    final arguments = <String>[
      'run',
      '--machine',
      '--project-root',
      workspaceRoot,
      '--target',
      target,
      '-d',
      selectedDeviceId,
      '--pid-file',
      pidFile,
      '--track-widget-creation',
      '--dart-define=flutter.inspector.structuredErrors=true',
      for (final define in dartDefines) '--dart-define=$define',
      if (flavor != null && flavor.isNotEmpty) '--flavor=$flavor',
      switch (mode) {
        'debug' => '--debug',
        'profile' => '--profile',
        'release' => '--release',
        _ => '--debug',
      },
    ];

    final process = await Process.start(
      flutterExecutable,
      arguments,
      workingDirectory: workspaceRoot,
    );
    final handle = LiveSessionHandle(
      process: process,
      stdoutPath: p.join(artifactStore.sessionArtifactsDir(record.sessionId), 'stdout.log'),
      stderrPath: p.join(artifactStore.sessionArtifactsDir(record.sessionId), 'stderr.log'),
      machinePath: p.join(artifactStore.sessionArtifactsDir(record.sessionId), 'machine.jsonl'),
    );
    sessionStore.attachLiveHandle(record.sessionId, handle);

    final tracker = _LaunchTracker(sessionId: record.sessionId, artifactStore: artifactStore);
    handle.stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) async {
          final message = _tryParseMachineMessage(line);
          if (message == null) {
            tracker.handleRawLine(line);
            await artifactStore.appendSessionLog(
              sessionId: record.sessionId,
              stream: 'stdout',
              line: line,
            );
            return;
          }
          await artifactStore.appendSessionMachineEvent(
            sessionId: record.sessionId,
            event: message,
          );
          if (message['event'] == null) {
            handle.completeMachineResponse(message);
            return;
          }
          tracker.handleEvent(message);
          final appLog = _extractAppLog(message);
          if (appLog != null && appLog.message.isNotEmpty) {
            await artifactStore.appendSessionLog(
              sessionId: record.sessionId,
              stream: appLog.error ? 'stderr' : 'stdout',
              line: appLog.message,
            );
          }
        });
    handle.stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) async {
          await artifactStore.appendSessionLog(
            sessionId: record.sessionId,
            stream: 'stderr',
            line: line,
          );
        });

    unawaited(
      process.exitCode.then((int exitCode) async {
        final current = sessionStore.getById(record.sessionId, touch: false);
        if (current == null) {
          return;
        }
        if (current.state == SessionState.stopped || current.state == SessionState.failed) {
          await sessionStore.detachLiveHandle(record.sessionId);
          return;
        }
        sessionStore.updateState(
          record.sessionId,
          exitCode == 0 ? SessionState.stopped : SessionState.failed,
          stale: false,
          lastExitCode: exitCode,
          lastExitAt: DateTime.now().toUtc(),
        );
        await sessionStore.detachLiveHandle(record.sessionId);
      }),
    );

    final launchTimeout = platform == 'ios'
        ? const Duration(minutes: 8)
        : const Duration(minutes: 3);
    await tracker.started.future.timeout(
      launchTimeout,
      onTimeout: () {
        throw FlutterHelmToolError(
          code: 'RUN_APP_TIMEOUT',
          category: 'runtime',
          message: 'Timed out waiting for flutter run to reach app.started.',
          retryable: true,
          detailsResource: <String, Object?>{
            'uri': artifactStore.sessionLogUri(record.sessionId, 'stderr'),
            'mimeType': 'text/plain',
          },
        );
      },
    );

    final pid = await _readPidFile(pidFile) ?? tracker.daemonPid;
    handle.vmServiceUri = tracker.vmServiceWsUri;
    handle.dtdUri = tracker.dtdUri;

    final updated = sessionStore.transitionContextToOwned(
      sessionId: record.sessionId,
      platform: platform,
      deviceId: selectedDeviceId,
      pid: pid,
      appId: tracker.appId,
      vmServiceMaskedUri: _maskUri(tracker.vmServiceWsUri),
      dtdMaskedUri: _maskUri(tracker.dtdUri),
      vmServiceAvailable: tracker.vmServiceWsUri != null,
      dtdAvailable: tracker.dtdUri != null,
    );
    await _writeAppState(updated);
    return updated;
  }

  Future<SessionRecord> attachApp({
    required String workspaceRoot,
    required String platform,
    required String target,
    required String mode,
    required String? flavor,
    String? deviceId,
    String? sessionId,
    String? debugUrl,
    String? appId,
  }) async {
    String? rawVmServiceUri = debugUrl;
    String? rawDtdUri;
    int? pid;
    if (sessionId != null) {
      final source = sessionStore.requireById(sessionId);
      final handle = sessionStore.liveHandle(sessionId);
      rawVmServiceUri = debugUrl ?? handle?.vmServiceUri;
      rawDtdUri = handle?.dtdUri;
      pid = source.pid;
      appId ??= source.appId;
      deviceId ??= source.deviceId;
    }
    if (rawVmServiceUri == null || rawVmServiceUri.isEmpty) {
      throw FlutterHelmToolError(
        code: 'ATTACH_TARGET_REQUIRED',
        category: 'validation',
        message: 'attach_app requires sessionId with a live VM service or debugUrl.',
        retryable: true,
      );
    }

    final attached = sessionStore.createAttachedSession(
      workspaceRoot: workspaceRoot,
      platform: platform,
      deviceId: deviceId,
      target: target,
      mode: mode,
      flavor: flavor,
      pid: pid,
      appId: appId,
      vmServiceAvailable: true,
      vmServiceMaskedUri: _maskUri(rawVmServiceUri),
      dtdAvailable: rawDtdUri != null,
      dtdMaskedUri: _maskUri(rawDtdUri),
    );
    sessionStore.attachLiveHandle(
      attached.sessionId,
      LiveSessionHandle(
        process: null,
        stdoutPath: '',
        stderrPath: '',
        machinePath: '',
        managedAppProcess: false,
        supportsHotOperations: false,
        vmServiceUri: rawVmServiceUri,
        dtdUri: rawDtdUri,
      ),
    );
    await _writeAppState(attached);
    return attached;
  }

  Future<SessionRecord> stopApp({required String sessionId}) async {
    final session = sessionStore.requireById(sessionId);
    if (session.stale) {
      throw FlutterHelmToolError(
        code: 'SESSION_STALE',
        category: 'runtime',
        message: 'The target session is stale and cannot be mutated.',
        retryable: true,
      );
    }
    if (session.ownership != SessionOwnership.owned) {
      throw FlutterHelmToolError(
        code: 'ATTACHED_SESSION_STOP_FORBIDDEN',
        category: 'runtime',
        message: 'stop_app is only allowed for owned sessions.',
        retryable: false,
      );
    }
    final handle = sessionStore.liveHandle(sessionId);
    if (handle == null) {
      throw FlutterHelmToolError(
        code: 'SESSION_NOT_RUNNING',
        category: 'runtime',
        message: 'The target session is not attached to a live process.',
        retryable: false,
      );
    }
    final process = handle.process;
    if (process == null || !handle.managedAppProcess) {
      throw FlutterHelmToolError(
        code: 'SESSION_NOT_RUNNING',
        category: 'runtime',
        message: 'The target session does not have a managed process.',
        retryable: false,
      );
    }
    process.kill(ProcessSignal.sigterm);
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return 137;
      },
    );
    final updated = sessionStore.updateState(
      sessionId,
      exitCode == 0 ? SessionState.stopped : SessionState.failed,
      stale: false,
      lastExitCode: exitCode,
      lastExitAt: DateTime.now().toUtc(),
    );
    await _writeAppState(updated);
    await sessionStore.detachLiveHandle(sessionId);
    return updated;
  }

  Future<Map<String, Object?>> hotReload({required String sessionId}) async {
    final session = ensureHotReloadAvailable(sessionId: sessionId);
    await _sendHotOperationRequest(
      session: session,
      fullRestart: false,
      action: 'hot_reload',
      reason: 'flutterhelm.hot_reload',
    );
    final refreshed = sessionStore.replace(
      session.copyWith(lastSeenAt: DateTime.now().toUtc()),
    );
    await _writeAppState(refreshed);
    return <String, Object?>{
      'sessionId': refreshed.sessionId,
      'status': 'completed',
      'operation': 'hot_reload',
      'resource': _resourceLink(
        artifactStore.sessionAppStateUri(refreshed.sessionId),
        'application/json',
        'App state summary',
      ),
    };
  }

  Future<Map<String, Object?>> hotRestart({required String sessionId}) async {
    final session = ensureHotRestartAvailable(sessionId: sessionId);
    await _sendHotOperationRequest(
      session: session,
      fullRestart: true,
      action: 'hot_restart',
      reason: 'flutterhelm.hot_restart',
    );
    final refreshed = sessionStore.replace(
      session.copyWith(lastSeenAt: DateTime.now().toUtc()),
    );
    await _writeAppState(refreshed);
    return <String, Object?>{
      'sessionId': refreshed.sessionId,
      'status': 'completed',
      'operation': 'hot_restart',
      'resource': _resourceLink(
        artifactStore.sessionAppStateUri(refreshed.sessionId),
        'application/json',
        'App state summary',
      ),
    };
  }

  SessionRecord ensureHotReloadAvailable({required String sessionId}) {
    return _ensureHotOperationAvailable(
      sessionId: sessionId,
      code: 'HOT_RELOAD_UNAVAILABLE',
      action: 'hot reload',
    );
  }

  SessionRecord ensureHotRestartAvailable({required String sessionId}) {
    return _ensureHotOperationAvailable(
      sessionId: sessionId,
      code: 'HOT_RESTART_UNAVAILABLE',
      action: 'hot restart',
    );
  }

  SessionRecord _ensureHotOperationAvailable({
    required String sessionId,
    required String code,
    required String action,
  }) {
    final session = _requireOwnedRunningSession(
      sessionId,
      code: code,
      action: action,
    );
    final handle = sessionStore.liveHandle(sessionId);
    if (handle == null ||
        handle.process == null ||
        !handle.supportsHotOperations ||
        session.appId == null) {
      throw FlutterHelmToolError(
        code: code,
        category: 'runtime',
        message:
            '${action[0].toUpperCase()}${action.substring(1)} requires an owned session with a managed flutter run process.',
        retryable: true,
        detailsResource: _healthResource(sessionId),
      );
    }
    return session;
  }

  Future<void> _sendHotOperationRequest({
    required SessionRecord session,
    required bool fullRestart,
    required String action,
    required String reason,
  }) async {
    final handle = sessionStore.liveHandle(session.sessionId);
    if (handle == null ||
        handle.process == null ||
        !handle.supportsHotOperations ||
        session.appId == null) {
      throw FlutterHelmToolError(
        code: action == 'hot_reload' ? 'HOT_RELOAD_UNAVAILABLE' : 'HOT_RESTART_UNAVAILABLE',
        category: 'runtime',
        message:
            '$action requires an owned session with a managed flutter run process.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    final delegateApplied = await _tryOfficialHotOperation(
      dtdUri: handle.dtdUri,
      fullRestart: fullRestart,
    );
    if (delegateApplied) {
      return;
    }
    await handle.sendMachineRequest('app.restart', <String, Object?>{
      'appId': session.appId,
      'fullRestart': fullRestart,
      'pause': false,
      'debounce': true,
      'reason': reason,
    });
  }

  Future<bool> _tryOfficialHotOperation({
    required String? dtdUri,
    required bool fullRestart,
  }) async {
    final factory = delegateAdapterFactory;
    if (factory == null || dtdUri == null || dtdUri.isEmpty) {
      return false;
    }
    try {
      final adapter = await factory();
      final health = await adapter.health();
      if (!health.connected) {
        return false;
      }
      if (fullRestart) {
        await adapter.hotRestart(dtdUri: dtdUri);
      } else {
        await adapter.hotReload(dtdUri: dtdUri);
      }
      return true;
    } on Object {
      return false;
    }
  }

  Future<List<Map<String, Object?>>> _flutterDevices() async {
    final result = await processRunner.run(
      flutterExecutable,
      const <String>['devices', '--machine'],
      timeout: const Duration(seconds: 30),
    );
    if (result.exitCode != 0) {
      throw FlutterHelmToolError(
        code: 'DEVICE_DISCOVERY_FAILED',
        category: 'runtime',
        message: result.stderr.isEmpty ? 'flutter devices failed.' : result.stderr.trim(),
        retryable: true,
      );
    }
    final decoded = jsonDecode(result.stdout);
    if (decoded is! List) {
      return const <Map<String, Object?>>[];
    }
    return decoded.cast<Map<Object?, Object?>>().map((Map<Object?, Object?> rawDevice) {
      final targetPlatform = rawDevice['targetPlatform'] as String? ?? '';
      final platform = switch (targetPlatform) {
        'darwin' => 'macos',
        'ios' => 'ios',
        'android-arm' || 'android-arm64' || 'android-x64' || 'android' => 'android',
        'web-javascript' => 'web',
        'linux-x64' || 'linux' => 'linux',
        'windows-x64' || 'windows' => 'windows',
        _ => targetPlatform,
      };
      return <String, Object?>{
        'deviceId': rawDevice['id'] as String?,
        'name': rawDevice['name'] as String?,
        'platform': platform,
        'kind': platform == 'web'
            ? 'browser'
            : (platform == 'macos' || platform == 'linux' || platform == 'windows')
                ? 'desktop'
                : (rawDevice['emulator'] == true ? 'simulator' : 'device'),
        'availability': (rawDevice['isSupported'] == true) ? 'available' : 'unsupported',
        'bootState': (rawDevice['emulator'] == true) ? 'booted' : 'connected',
        'capabilities': rawDevice['capabilities'],
      };
    }).toList();
  }

  Future<List<Map<String, Object?>>> _iosSimulators() async {
    final result = await processRunner.run(
      'xcrun',
      const <String>['simctl', 'list', 'devices', 'available'],
      timeout: const Duration(seconds: 20),
    );
    if (result.exitCode != 0) {
      return const <Map<String, Object?>>[];
    }
    final devices = <Map<String, Object?>>[];
    for (final line in result.stdout.split('\n')) {
      final match =
          RegExp(r'^\s+(.+?) \(([0-9A-F-]+)\) \((Shutdown|Booted)\)\s*$').firstMatch(line.trimRight());
      if (match == null) {
        continue;
      }
      devices.add(<String, Object?>{
        'deviceId': match.group(2),
        'name': match.group(1),
        'platform': 'ios',
        'kind': 'simulator',
        'availability': 'available',
        'bootState': match.group(3)?.toLowerCase(),
        'capabilities': const <String, Object?>{
          'hotReload': true,
          'hotRestart': true,
          'flutterExit': true,
        },
      });
    }
    return devices;
  }

  Future<String> _resolveLaunchDeviceId({
    required String platform,
    String? deviceId,
  }) async {
    if (deviceId != null && deviceId.isNotEmpty) {
      return deviceId;
    }
    final devices = await listDevices();
    final matching = devices.where((Map<String, Object?> device) {
      if (device['platform'] != platform) {
        return false;
      }
      if (platform == 'ios') {
        return device['kind'] == 'simulator';
      }
      return device['availability'] == 'available';
    }).toList();
    if (matching.isEmpty) {
      throw FlutterHelmToolError(
        code: 'DEVICE_NOT_FOUND',
        category: 'runtime',
        message: 'No launchable device found for platform $platform.',
        retryable: true,
      );
    }
    if (platform == 'ios') {
      matching.sort((Map<String, Object?> left, Map<String, Object?> right) {
        final scoreCompare = _iosLaunchPriority(right).compareTo(
          _iosLaunchPriority(left),
        );
        if (scoreCompare != 0) {
          return scoreCompare;
        }
        return (left['name'] as String? ?? '').compareTo(
          right['name'] as String? ?? '',
        );
      });
    }
    return matching.first['deviceId'] as String;
  }

  int _iosLaunchPriority(Map<String, Object?> device) {
    final name = (device['name'] as String? ?? '').toLowerCase();
    final bootState = (device['bootState'] as String? ?? '').toLowerCase();
    final isIphone = name.contains('iphone');
    final isBooted = bootState == 'booted';
    if (isIphone && isBooted) {
      return 4;
    }
    if (isIphone) {
      return 3;
    }
    if (isBooted) {
      return 2;
    }
    return 1;
  }

  Future<void> _ensureIosSimulatorBooted(String deviceId) async {
    final boot = await processRunner.run(
      'xcrun',
      <String>['simctl', 'boot', deviceId],
      timeout: const Duration(seconds: 30),
    );
    if (boot.exitCode != 0 &&
        !boot.stderr.contains('Unable to boot device in current state: Booted')) {
      throw FlutterHelmToolError(
        code: 'SIMULATOR_BOOT_FAILED',
        category: 'runtime',
        message: boot.stderr.isEmpty ? 'Failed to boot iOS simulator.' : boot.stderr.trim(),
        retryable: true,
      );
    }
    await processRunner.run(
      'xcrun',
      <String>['simctl', 'bootstatus', deviceId, '-b'],
      timeout: const Duration(minutes: 2),
    );
    await processRunner.run(
      'open',
      <String>['-a', 'Simulator', '--args', '-CurrentDeviceUDID', deviceId],
      timeout: const Duration(seconds: 20),
    );
  }

  Future<int?> _readPidFile(String pidFilePath) async {
    final file = File(pidFilePath);
    if (!await file.exists()) {
      return null;
    }
    return int.tryParse((await file.readAsString()).trim());
  }

  Map<String, Object?>? _tryParseMachineMessage(String line) {
    try {
      final decoded = jsonDecode(line);
      Object? candidate = decoded;
      if (decoded is List && decoded.isNotEmpty) {
        candidate = decoded.first;
      }
      if (candidate is Map<String, Object?>) {
        return candidate;
      }
      if (candidate is Map) {
        return candidate.map<String, Object?>(
          (Object? key, Object? value) => MapEntry<String, Object?>(key.toString(), value),
        );
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  _AppLogLine? _extractAppLog(Map<String, Object?> event) {
    if (event['event'] != 'app.log') {
      return null;
    }
    final params = event['params'] as Map<Object?, Object?>? ?? const <Object?, Object?>{};
    final message = params['log'] as String? ?? params['message'] as String? ?? '';
    final isError =
        params['error'] == true || params['stream'] == 'stderr' || params['level'] == 'error';
    return _AppLogLine(message: message, error: isError);
  }

  String? _maskUri(String? rawUri) {
    if (rawUri == null || rawUri.isEmpty) {
      return null;
    }
    final uri = Uri.parse(rawUri);
    final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    return '${uri.scheme}://$authority/...';
  }

  Future<void> _writeAppState(SessionRecord session) async {
    final payload = await appStateBuilder(session);
    payload['nativeBridgeAvailablePlatforms'] = detectNativeBridgePlatformsSync(
      session.workspaceRoot,
    );
    await artifactStore.writeSessionAppState(
      sessionId: session.sessionId,
      payload: payload,
    );
  }

  SessionRecord _requireOwnedRunningSession(
    String sessionId, {
    required String code,
    required String action,
  }) {
    final session = sessionStore.requireById(sessionId);
    if (session.stale) {
      throw FlutterHelmToolError(
        code: 'SESSION_STALE',
        category: 'runtime',
        message: 'The target session is stale and cannot perform $action.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    if (session.ownership != SessionOwnership.owned) {
      throw FlutterHelmToolError(
        code: code,
        category: 'runtime',
        message: '$action is only allowed for owned sessions.',
        retryable: false,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    if (session.state != SessionState.running) {
      throw FlutterHelmToolError(
        code: 'SESSION_NOT_RUNNING',
        category: 'runtime',
        message: 'The target session is not attached to a live Flutter process.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    return session;
  }

  Map<String, Object?> _healthResource(String sessionId) {
    return <String, Object?>{
      'uri': artifactStore.sessionHealthUri(sessionId),
      'mimeType': 'application/json',
    };
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
}

class _LaunchTracker {
  _LaunchTracker({required this.sessionId, required this.artifactStore});

  final String sessionId;
  final ArtifactStore artifactStore;
  final Completer<void> started = Completer<void>();
  int? daemonPid;
  String? vmServiceWsUri;
  String? dtdUri;
  String? appId;

  void handleEvent(Map<String, Object?> event) {
    final name = event['event'] as String?;
    final params = event['params'] as Map<Object?, Object?>? ?? const <Object?, Object?>{};
    switch (name) {
      case 'daemon.connected':
        daemonPid = params['pid'] as int?;
      case 'app.start':
        appId = params['appId'] as String? ?? params['applicationId'] as String?;
      case 'app.debugPort':
        vmServiceWsUri = params['wsUri'] as String? ?? params['vmServiceUri'] as String?;
      case 'app.dtd':
        dtdUri = params['uri'] as String?;
      case 'app.started':
        if (!started.isCompleted) {
          started.complete();
        }
    }
  }

  void handleRawLine(String line) {
    final vmServiceMatch = RegExp(r'(ws://127\.0\.0\.1:[^"\s]+/ws)').firstMatch(line);
    if (vmServiceMatch != null) {
      vmServiceWsUri ??= vmServiceMatch.group(1);
    }
  }
}

class _AppLogLine {
  const _AppLogLine({required this.message, required this.error});

  final String message;
  final bool error;
}
