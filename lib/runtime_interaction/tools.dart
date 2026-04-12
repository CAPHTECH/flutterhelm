import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/platform_bridge/support.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:path/path.dart' as p;

class RuntimeDriverStatus {
  const RuntimeDriverStatus({
    required this.enabled,
    required this.workflowEnabled,
    required this.configured,
    required this.connected,
    required this.driverName,
    required this.driverVersion,
    required this.supportedPlatforms,
    required this.supportedActions,
    required this.supportedLocatorFields,
    required this.screenshotFormats,
    required this.backend,
    this.error,
  });

  final bool enabled;
  final bool workflowEnabled;
  final bool configured;
  final bool connected;
  final String? driverName;
  final String? driverVersion;
  final List<String> supportedPlatforms;
  final List<String> supportedActions;
  final List<String> supportedLocatorFields;
  final List<String> screenshotFormats;
  final String backend;
  final String? error;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'runtimeDriverEnabled': enabled,
      'runtimeInteractionWorkflowEnabled': workflowEnabled,
      'driverConfigured': configured,
      'driverConnected': connected,
      'driverName': driverName,
      'driverVersion': driverVersion,
      'driverCapabilities': <String, Object?>{
        'backend': backend,
        'supportedPlatforms': supportedPlatforms,
        'supportedActions': supportedActions,
        'screenshotFormats': screenshotFormats,
      },
      'supportedLocatorFields': supportedLocatorFields,
      if (error != null) 'driverError': error,
    };
  }
}

class RuntimeInteractionToolService {
  RuntimeInteractionToolService({
    required this.sessionStore,
    required this.artifactStore,
    required this.workflowEnabled,
    required this.driverEnabled,
    required this.driverCommand,
    required this.driverArgs,
    required this.driverStartupTimeoutMs,
  }) : _driverClient = _StdioRuntimeDriverClient(
         enabled: driverEnabled,
         command: driverCommand,
         args: driverArgs,
         startupTimeout: Duration(milliseconds: driverStartupTimeoutMs),
       );

  final SessionStore sessionStore;
  final ArtifactStore artifactStore;
  final bool workflowEnabled;
  final bool driverEnabled;
  final String driverCommand;
  final List<String> driverArgs;
  final int driverStartupTimeoutMs;
  final _StdioRuntimeDriverClient _driverClient;

  Future<RuntimeDriverStatus> driverStatus({String? platform}) async {
    final baseConfigured =
        driverEnabled && driverCommand.isNotEmpty && driverArgs.isNotEmpty;
    if (!baseConfigured) {
      return RuntimeDriverStatus(
        enabled: driverEnabled,
        workflowEnabled: workflowEnabled,
        configured: false,
        connected: false,
        driverName: null,
        driverVersion: null,
        supportedPlatforms: const <String>[],
        supportedActions: const <String>[],
        supportedLocatorFields: const <String>[],
        screenshotFormats: const <String>[],
        backend: 'external_adapter',
      );
    }

    final snapshot = await _driverClient.health();
    final supportedPlatforms = snapshot.supportedPlatforms;
    final connectedForPlatform =
        snapshot.connected &&
        (platform == null ||
            supportedPlatforms.isEmpty ||
            supportedPlatforms.contains(platform));
    return RuntimeDriverStatus(
      enabled: driverEnabled,
      workflowEnabled: workflowEnabled,
      configured: true,
      connected: connectedForPlatform,
      driverName: snapshot.driverName,
      driverVersion: snapshot.driverVersion,
      supportedPlatforms: snapshot.supportedPlatforms,
      supportedActions: snapshot.supportedActions,
      supportedLocatorFields: snapshot.supportedLocatorFields,
      screenshotFormats: snapshot.screenshotFormats,
      backend: 'external_adapter',
      error: snapshot.error,
    );
  }

  Future<Map<String, Object?>> appStateForSession(SessionRecord session) async {
    final status = await driverStatus(platform: session.platform);
    return <String, Object?>{
      'sessionId': session.sessionId,
      'ownership': session.ownership.wireName,
      'state': session.state.wireName,
      'stale': session.stale,
      'platform': session.platform,
      'deviceId': session.deviceId,
      'target': session.target,
      'mode': session.mode,
      'pid': session.pid,
      'profileActive': session.profileActive,
      'nativeBridgeAvailablePlatforms': detectNativeBridgePlatformsSync(
        session.workspaceRoot,
      ),
      'vmService': <String, Object?>{
        'available': session.vmServiceAvailable,
        'maskedUri': session.vmServiceMaskedUri,
      },
      'dtd': <String, Object?>{
        'available': session.dtdAvailable,
        'maskedUri': session.dtdMaskedUri,
      },
      ...status.toJson(),
      'hotReloadAvailable': _hotOpAvailable(session),
      'hotRestartAvailable': _hotOpAvailable(session),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<Map<String, Object?>> healthForSession(SessionRecord session) async {
    final status = await driverStatus(platform: session.platform);
    final issues = <String>[];
    final guidance = <String>[];

    if (session.stale) {
      issues.add('session is stale');
      guidance.add(
        'Re-run or re-attach the app before using runtime, profiling, or interaction tools.',
      );
    }
    if (session.ownership != SessionOwnership.owned) {
      issues.add('profiling requires an owned session');
      guidance.add('Use run_app to create an owned session instead of attach_app.');
    }
    if (session.state != SessionState.running) {
      issues.add('session is not running');
      guidance.add('Profiling and runtime interaction tools require a live running session.');
    }
    if (!session.vmServiceAvailable) {
      issues.add('vm service is unavailable');
      guidance.add('Profiling requires a live VM service connection.');
    }
    if (session.mode == 'release') {
      issues.add('release mode is unsupported for profiling');
      guidance.add(
        'Use run_app with mode=profile for more reliable performance diagnostics.',
      );
    } else if (session.mode != 'profile') {
      guidance.add('Profile mode is recommended for performance measurements.');
    }
    if (!session.dtdAvailable) {
      guidance.add('DTD is not available; FlutterHelm will use vm_service-backed profiling.');
    }
    if (!workflowEnabled) {
      guidance.add('runtime_interaction workflow is disabled; UI actions are intentionally opt-in.');
    }
    if (driverEnabled && status.configured && !status.connected) {
      guidance.add('Runtime driver is configured but not connected; UI actions will fail until it is reachable.');
    } else if (!driverEnabled) {
      guidance.add('Runtime driver is disabled; screenshot fallback may still work on iOS simulator.');
    }

    return <String, Object?>{
      'sessionId': session.sessionId,
      'ready': issues.isEmpty,
      'issues': issues,
      'guidance': guidance,
      'ownership': session.ownership.wireName,
      'stale': session.stale,
      'state': session.state.wireName,
      'currentMode': session.mode,
      'recommendedMode': 'profile',
      'vmServiceAvailable': session.vmServiceAvailable,
      'dtdAvailable': session.dtdAvailable,
      'backend': 'vm_service',
      'profileActive': session.profileActive,
      ...status.toJson(),
      'hotReloadAvailable': _hotOpAvailable(session),
      'hotRestartAvailable': _hotOpAvailable(session),
    };
  }

  Future<Map<String, Object?>> captureScreenshot({
    required String sessionId,
    required String format,
  }) async {
    final session = _requireLiveSession(sessionId);
    final normalizedFormat = _normalizeScreenshotFormat(format);
    final captureId = _captureId('shot');
    final uri = artifactStore.sessionScreenshotUri(
      session.sessionId,
      captureId,
      normalizedFormat,
    );
    final targetPath = p.join(
      artifactStore.sessionArtifactsDir(session.sessionId),
      'screenshot-$captureId.$normalizedFormat',
    );

    var backend = 'external_adapter';
    try {
      final runtimeDriver = await _driverClient.health();
      if (runtimeDriver.connected) {
        final deviceId = _requireDevice(session);
        await _driverClient.callTool(
          'mobile_save_screenshot',
          <String, Object?>{
            'device': deviceId,
            'saveTo': targetPath,
          },
        );
        final artifactReady = await _waitForScreenshotArtifact(
          targetPath,
          timeout: const Duration(seconds: 5),
        );
        if (!artifactReady) {
          backend = 'ios_simctl';
          await _captureScreenshotViaFallback(
            session: session,
            targetPath: targetPath,
            format: normalizedFormat,
          );
          await _requireScreenshotArtifact(
            targetPath,
            timeout: const Duration(seconds: 5),
          );
        }
      } else {
        backend = 'ios_simctl';
        await _captureScreenshotViaFallback(
          session: session,
          targetPath: targetPath,
          format: normalizedFormat,
        );
        await _requireScreenshotArtifact(
          targetPath,
          timeout: const Duration(seconds: 5),
        );
      }
    } catch (_) {
      backend = 'ios_simctl';
      await _captureScreenshotViaFallback(
        session: session,
        targetPath: targetPath,
        format: normalizedFormat,
      );
      await _requireScreenshotArtifact(
        targetPath,
        timeout: const Duration(seconds: 5),
      );
    }

    return <String, Object?>{
      'sessionId': session.sessionId,
      'status': 'completed',
      'format': normalizedFormat,
      'backend': backend,
      'resource': <String, Object?>{
        'uri': uri,
        'mimeType': 'image/${normalizedFormat == 'jpg' ? 'jpeg' : normalizedFormat}',
        'title': 'Session screenshot',
      },
    };
  }

  Future<Map<String, Object?>> tapWidget({
    required String sessionId,
    required Map<String, Object?> locator,
    int timeoutMs = 3000,
  }) async {
    final session = _requireInteractiveSession(sessionId);
    final driver = await _requireConnectedDriver(session);
    final match = await _resolveLocator(session: session, locator: locator, driver: driver);
    final deviceId = _requireDevice(session);
    await _driverClient.callTool(
      'mobile_click_on_screen_at_coordinates',
      <String, Object?>{
        'device': deviceId,
        'x': match.x.round(),
        'y': match.y.round(),
      },
    );
    if (timeoutMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: timeoutMs.clamp(100, 1000)));
    }
    return <String, Object?>{
      'sessionId': session.sessionId,
      'status': 'completed',
      'match': match.toJson(),
    };
  }

  Future<Map<String, Object?>> enterText({
    required String sessionId,
    required Map<String, Object?> locator,
    required String text,
    required bool replaceExisting,
    required bool submit,
    int timeoutMs = 3000,
  }) async {
    final session = _requireInteractiveSession(sessionId);
    final driver = await _requireConnectedDriver(session);
    final match = await _resolveLocator(session: session, locator: locator, driver: driver);
    final deviceId = _requireDevice(session);
    await _driverClient.callTool(
      'mobile_click_on_screen_at_coordinates',
      <String, Object?>{
        'device': deviceId,
        'x': match.x.round(),
        'y': match.y.round(),
      },
    );
    await _driverClient.callTool(
      'mobile_type_keys',
      <String, Object?>{
        'device': deviceId,
        'text': text,
        'submit': submit,
      },
    );
    if (timeoutMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: timeoutMs.clamp(100, 1000)));
    }
    return <String, Object?>{
      'sessionId': session.sessionId,
      'status': 'completed',
      'match': match.toJson(),
      'textLength': text.length,
      'replaceExisting': replaceExisting,
      'submitted': submit,
    };
  }

  Future<Map<String, Object?>> scrollUntilVisible({
    required String sessionId,
    required Map<String, Object?> locator,
    required String direction,
    required int maxScrolls,
    int? stepPixels,
    int timeoutMs = 3000,
  }) async {
    final session = _requireInteractiveSession(sessionId);
    final driver = await _requireConnectedDriver(session);
    final deviceId = _requireDevice(session);
    final adjustedLocator = Map<String, Object?>.from(locator);
    adjustedLocator.putIfAbsent('visibleOnly', () => true);

    for (var attempt = 0; attempt <= maxScrolls; attempt++) {
      final elements = await _listElements(session, driver);
      final match = _matchLocator(elements, adjustedLocator, driver.supportedLocatorFields);
      if (match != null) {
        var settledMatch = match;
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          final settledElements = await _listElements(session, driver);
          settledMatch =
              _matchLocator(
                settledElements,
                adjustedLocator,
                driver.supportedLocatorFields,
              ) ??
              match;
        }
        return <String, Object?>{
          'sessionId': session.sessionId,
          'status': 'completed',
          'scrollsUsed': attempt,
          'match': settledMatch.toJson(),
        };
      }
      if (attempt == maxScrolls) {
        break;
      }
      await _driverClient.callTool(
        'mobile_swipe_on_screen',
        <String, Object?>{
          'device': deviceId,
          'direction': _driverSwipeDirection(direction),
          if (stepPixels != null) 'distance': stepPixels,
        },
      );
      if (timeoutMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: timeoutMs.clamp(100, 600)));
      }
    }

    throw FlutterHelmToolError(
      code: 'SEMANTIC_LOCATOR_NOT_FOUND',
      category: 'runtime',
      message: 'No visible widget matched the provided locator after scrolling.',
      retryable: true,
      detailsResource: _healthResource(session.sessionId),
    );
  }

  bool _hotOpAvailable(SessionRecord session) {
    final handle = sessionStore.liveHandle(session.sessionId);
    return session.ownership == SessionOwnership.owned &&
        !session.stale &&
        session.state == SessionState.running &&
        session.appId != null &&
        handle?.process != null;
  }

  SessionRecord _requireLiveSession(String sessionId) {
    final session = sessionStore.requireById(sessionId);
    if (session.stale) {
      throw FlutterHelmToolError(
        code: 'SESSION_STALE',
        category: 'runtime',
        message: 'The target session is stale and cannot be used for runtime interaction.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    if (session.state != SessionState.running &&
        session.state != SessionState.attached) {
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

  SessionRecord _requireInteractiveSession(String sessionId) {
    final session = _requireLiveSession(sessionId);
    if (!workflowEnabled) {
      throw FlutterHelmToolError(
        code: 'RUNTIME_DRIVER_UNAVAILABLE',
        category: 'runtime',
        message: 'runtime_interaction workflow is disabled.',
        retryable: false,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    return session;
  }

  Future<_DriverHealthSnapshot> _requireConnectedDriver(SessionRecord session) async {
    final status = await _driverClient.health();
    if (!status.connected) {
      throw FlutterHelmToolError(
        code: 'RUNTIME_DRIVER_NOT_CONNECTED',
        category: 'runtime',
        message: 'Runtime driver is not connected.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    if (session.platform != null &&
        status.supportedPlatforms.isNotEmpty &&
        !status.supportedPlatforms.contains(session.platform)) {
      throw FlutterHelmToolError(
        code: 'RUNTIME_DRIVER_UNAVAILABLE',
        category: 'runtime',
        message: 'Runtime driver does not support platform ${session.platform}.',
        retryable: false,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    return status;
  }

  Future<List<_ScreenElement>> _listElements(
    SessionRecord session,
    _DriverHealthSnapshot driver,
  ) async {
    final deviceId = _requireDevice(session);
    final raw = await _driverClient.callTool(
      'mobile_list_elements_on_screen',
      <String, Object?>{'device': deviceId},
    );
    final elements = _extractElements(raw);
    final normalized = elements
        .map((Map<String, Object?> element) => _ScreenElement.fromMap(element))
        .whereType<_ScreenElement>()
        .toList();
    final deduped = <String, _ScreenElement>{};
    for (final element in normalized) {
      final key =
          '${element.type}|${element.text}|${element.label}|${element.x}|${element.y}|${element.visible}';
      deduped[key] = element;
    }
    return deduped.values.toList();
  }

  Future<_ScreenElement> _resolveLocator({
    required SessionRecord session,
    required Map<String, Object?> locator,
    required _DriverHealthSnapshot driver,
  }) async {
    final elements = await _listElements(session, driver);
    final match = _matchLocator(elements, locator, driver.supportedLocatorFields);
    if (match == null) {
      throw FlutterHelmToolError(
        code: 'SEMANTIC_LOCATOR_NOT_FOUND',
        category: 'runtime',
        message: 'No widget matched the provided locator.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    return match;
  }

  _ScreenElement? _matchLocator(
    List<_ScreenElement> elements,
    Map<String, Object?> locator,
    List<String> supportedLocatorFields,
  ) {
    final unsupported = locator.keys.where((String key) {
      if (key == 'index' || key == 'visibleOnly') {
        return false;
      }
      return !supportedLocatorFields.contains(key);
    }).toList();
    if (unsupported.isNotEmpty) {
      throw FlutterHelmToolError(
        code: 'SEMANTIC_LOCATOR_UNSUPPORTED',
        category: 'runtime',
        message: 'Unsupported locator fields: ${unsupported.join(', ')}.',
        retryable: false,
      );
    }

    final visibleOnly = locator['visibleOnly'] as bool? ?? true;
    final filtered = elements.where((element) {
      if (visibleOnly && !element.visible) {
        return false;
      }
      return _matchesLocatorField(element.text, locator['text']) &&
          _matchesContainsField(element.text, locator['textContains']) &&
          _matchesLocatorField(element.label, locator['label']) &&
          _matchesContainsField(element.label, locator['labelContains']) &&
          _matchesLocatorField(element.valueKey, locator['valueKey']) &&
          _matchesLocatorField(element.type, locator['type']);
    }).toList();

    if (filtered.isEmpty) {
      return null;
    }

    final index = locator['index'] as int?;
    if (index != null) {
      if (index < 0 || index >= filtered.length) {
        throw FlutterHelmToolError(
          code: 'SEMANTIC_LOCATOR_NOT_FOUND',
          category: 'runtime',
          message: 'Locator index $index is out of range for ${filtered.length} matches.',
          retryable: true,
        );
      }
      return filtered[index];
    }

    if (filtered.length > 1) {
      throw FlutterHelmToolError(
        code: 'SEMANTIC_LOCATOR_AMBIGUOUS',
        category: 'runtime',
        message: 'Locator matched ${filtered.length} widgets; provide index or refine the locator.',
        retryable: true,
      );
    }

    return filtered.single;
  }

  bool _matchesLocatorField(String? candidate, Object? expected) {
    if (expected == null) {
      return true;
    }
    if (expected is! String || expected.isEmpty) {
      return true;
    }
    return candidate == expected;
  }

  bool _matchesContainsField(String? candidate, Object? expected) {
    if (expected == null) {
      return true;
    }
    if (expected is! String || expected.isEmpty) {
      return true;
    }
    return (candidate ?? '').contains(expected);
  }

  Future<void> _captureScreenshotViaFallback({
    required SessionRecord session,
    required String targetPath,
    required String format,
  }) async {
    if (session.platform != 'ios') {
      throw FlutterHelmToolError(
        code: 'SCREENSHOT_CAPTURE_UNAVAILABLE',
        category: 'runtime',
        message: 'Screenshot capture requires a connected runtime driver or iOS simulator fallback.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    if (format != 'png') {
      throw FlutterHelmToolError(
        code: 'SCREENSHOT_CAPTURE_UNAVAILABLE',
        category: 'runtime',
        message: 'iOS simulator fallback only supports png screenshots.',
        retryable: false,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    final deviceId = _requireDevice(session);
    final result = await Process.run('xcrun', <String>[
      'simctl',
      'io',
      deviceId,
      'screenshot',
      targetPath,
    ]);
    if (result.exitCode != 0) {
      throw FlutterHelmToolError(
        code: 'SCREENSHOT_CAPTURE_UNAVAILABLE',
        category: 'runtime',
        message: 'Failed to capture screenshot via iOS simulator fallback.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
  }

  Future<void> _requireScreenshotArtifact(
    String targetPath, {
    required Duration timeout,
  }) async {
    if (await _waitForScreenshotArtifact(targetPath, timeout: timeout)) {
      return;
    }
    throw FlutterHelmToolError(
      code: 'SCREENSHOT_CAPTURE_UNAVAILABLE',
      category: 'runtime',
      message: 'Screenshot artifact was not written to $targetPath in time.',
      retryable: true,
    );
  }

  Future<bool> _waitForScreenshotArtifact(
    String targetPath, {
    required Duration timeout,
  }) async {
    final file = File(targetPath);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await file.exists()) {
        final length = await file.length();
        if (length > 0) {
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  List<Map<String, Object?>> _extractElements(Object? raw) {
    if (raw is String) {
      final decoded = _decodeEmbeddedJson(raw);
      return _extractElements(decoded);
    }
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map(
            (Map element) => element.map<String, Object?>(
              (Object? key, Object? value) =>
                  MapEntry<String, Object?>(key.toString(), value),
            ),
          )
          .toList();
    }
    if (raw is Map) {
      final rawElements = raw['elements'];
      if (rawElements is List) {
        return _extractElements(rawElements);
      }
    }
    return const <Map<String, Object?>>[];
  }

  String _requireDevice(SessionRecord session) {
    final deviceId = session.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw FlutterHelmToolError(
        code: 'DEVICE_NOT_FOUND',
        category: 'runtime',
        message: 'Runtime interaction requires a resolved device id.',
        retryable: true,
        detailsResource: _healthResource(session.sessionId),
      );
    }
    return deviceId;
  }

  String _normalizeScreenshotFormat(String format) {
    final normalized = format.toLowerCase();
    return switch (normalized) {
      'png' => 'png',
      'jpg' || 'jpeg' => 'jpg',
      _ => throw FlutterHelmToolError(
        code: 'SCREENSHOT_CAPTURE_UNAVAILABLE',
        category: 'validation',
        message: 'format must be png, jpg, or jpeg.',
        retryable: false,
      ),
    };
  }

  String _captureId(String prefix) {
    final now = DateTime.now().toUtc();
    return '${prefix}_${now.microsecondsSinceEpoch.toRadixString(36)}';
  }

  String _driverSwipeDirection(String direction) {
    return switch (direction) {
      'down' => 'up',
      'up' => 'down',
      'left' => 'right',
      'right' => 'left',
      _ => 'up',
    };
  }

  Map<String, Object?> _healthResource(String sessionId) {
    return <String, Object?>{
      'uri': artifactStore.sessionHealthUri(sessionId),
      'mimeType': 'application/json',
    };
  }
}

class _ScreenElement {
  const _ScreenElement({
    required this.x,
    required this.y,
    required this.visible,
    this.text,
    this.label,
    this.valueKey,
    this.type,
  });

  final double x;
  final double y;
  final bool visible;
  final String? text;
  final String? label;
  final String? valueKey;
  final String? type;

  factory _ScreenElement.fromMap(Map<String, Object?> map) {
    final coordinates = _coerceMap(map['coordinates']);
    final x = _coerceDouble(
      map['x'] ??
          map['centerX'] ??
          map['midX'] ??
          map['left'] ??
          coordinates['x'],
    );
    final y = _coerceDouble(
      map['y'] ??
          map['centerY'] ??
          map['midY'] ??
          map['top'] ??
          coordinates['y'],
    );
    final width = _coerceDouble(map['width'] ?? coordinates['width']);
    final height = _coerceDouble(map['height'] ?? coordinates['height']);
    final resolvedX = coordinates.isNotEmpty && x != null && width != null
        ? x + (width / 2)
        : x;
    final resolvedY = coordinates.isNotEmpty && y != null && height != null
        ? y + (height / 2)
        : y;
    if (resolvedX == null || resolvedY == null) {
      throw const FormatException('Screen element is missing coordinates.');
    }
    return _ScreenElement(
      x: resolvedX,
      y: resolvedY,
      visible: _coerceBool(map['visible'] ?? map['isVisible']) ?? true,
      text: _coerceString(
        map['text'] ??
            map['displayText'] ??
            map['value'] ??
            map['title'] ??
            map['label'] ??
            map['name'],
      ),
      label: _coerceString(
        map['label'] ??
            map['accessibilityLabel'] ??
            map['name'] ??
            map['text'],
      ),
      valueKey: _coerceString(
        map['valueKey'] ?? map['key'] ?? map['identifier'],
      ),
      type: _coerceString(map['type'] ?? map['widgetType'] ?? map['role']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'x': x,
      'y': y,
      'visible': visible,
      if (text != null) 'text': text,
      if (label != null) 'label': label,
      if (valueKey != null) 'valueKey': valueKey,
      if (type != null) 'type': type,
    };
  }
}

class _DriverHealthSnapshot {
  const _DriverHealthSnapshot({
    required this.connected,
    required this.driverName,
    required this.driverVersion,
    required this.supportedPlatforms,
    required this.supportedActions,
    required this.supportedLocatorFields,
    required this.screenshotFormats,
    this.error,
  });

  final bool connected;
  final String? driverName;
  final String? driverVersion;
  final List<String> supportedPlatforms;
  final List<String> supportedActions;
  final List<String> supportedLocatorFields;
  final List<String> screenshotFormats;
  final String? error;
}

class _StdioRuntimeDriverClient {
  _StdioRuntimeDriverClient({
    required this.enabled,
    required this.command,
    required this.args,
    required this.startupTimeout,
  });

  final bool enabled;
  final String command;
  final List<String> args;
  final Duration startupTimeout;
  _McpConnection? _connection;
  _DriverHealthSnapshot? _cachedHealth;

  Future<_DriverHealthSnapshot> health() async {
    if (!enabled) {
      return const _DriverHealthSnapshot(
        connected: false,
        driverName: null,
        driverVersion: null,
        supportedPlatforms: <String>[],
        supportedActions: <String>[],
        supportedLocatorFields: <String>[],
        screenshotFormats: <String>[],
      );
    }
    if (_cachedHealth != null) {
      return _cachedHealth!;
    }
    try {
      final connection = await _ensureConnection();
      final supportedActions = <String>[
        if (connection.toolNames.contains('mobile_click_on_screen_at_coordinates')) 'tap_widget',
        if (connection.toolNames.contains('mobile_type_keys')) 'enter_text',
        if (connection.toolNames.contains('mobile_swipe_on_screen') &&
            connection.toolNames.contains('mobile_list_elements_on_screen'))
          'scroll_until_visible',
        if (connection.toolNames.contains('mobile_save_screenshot') ||
            connection.toolNames.contains('mobile_take_screenshot'))
          'capture_screenshot',
      ];
      final driverName = connection.serverName;
      final locatorFields = driverName == 'mobile-mcp'
          ? const <String>[
              'text',
              'textContains',
              'label',
              'labelContains',
              'index',
              'visibleOnly',
            ]
          : const <String>[
              'text',
              'textContains',
              'label',
              'labelContains',
              'valueKey',
              'type',
              'index',
              'visibleOnly',
            ];
      final screenshotFormats = <String>[
        if (connection.toolNames.contains('mobile_save_screenshot')) 'png',
        if (connection.toolNames.contains('mobile_save_screenshot')) 'jpg',
        if (connection.toolNames.contains('mobile_save_screenshot')) 'jpeg',
      ];
      final platforms = driverName == 'mobile-mcp'
          ? const <String>['ios', 'android']
          : const <String>['ios'];
      final snapshot = _DriverHealthSnapshot(
        connected: true,
        driverName: driverName,
        driverVersion: connection.serverVersion,
        supportedPlatforms: platforms,
        supportedActions: supportedActions,
        supportedLocatorFields: locatorFields,
        screenshotFormats: screenshotFormats,
      );
      _cachedHealth = snapshot;
      return snapshot;
    } catch (error) {
      final snapshot = _DriverHealthSnapshot(
        connected: false,
        driverName: null,
        driverVersion: null,
        supportedPlatforms: const <String>[],
        supportedActions: const <String>[],
        supportedLocatorFields: const <String>[],
        screenshotFormats: const <String>[],
        error: error.toString(),
      );
      _cachedHealth = snapshot;
      return snapshot;
    }
  }

  Future<Object?> callTool(String name, Map<String, Object?> arguments) async {
    final connection = await _ensureConnection();
    final result = await connection.request('tools/call', <String, Object?>{
      'name': name,
      'arguments': arguments,
    });
    return _decodeToolPayload(result);
  }

  Future<_McpConnection> _ensureConnection() async {
    final existing = _connection;
    if (existing != null && existing.connected) {
      return existing;
    }
    final connection = await _McpConnection.start(
      command: command,
      args: args,
      startupTimeout: startupTimeout,
    );
    _connection = connection;
    _cachedHealth = null;
    return connection;
  }
}

class _McpConnection {
  _McpConnection._({
    required this.process,
    required this.startupTimeout,
  }) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_handleStdoutLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((_) {});
    process.exitCode.then((_) {
      _connected = false;
      final pending = Map<String, Completer<Map<String, Object?>>>.from(
        _pendingRequests,
      );
      _pendingRequests.clear();
      for (final completer in pending.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Runtime driver exited.'));
        }
      }
    });
  }

  final Process process;
  final Duration startupTimeout;
  String serverName = 'runtime-driver';
  String? serverVersion;
  Set<String> toolNames = <String>{};
  final Map<String, Completer<Map<String, Object?>>> _pendingRequests =
      <String, Completer<Map<String, Object?>>>{};
  int _nextRequestId = 1;
  bool _connected = true;

  bool get connected => _connected;

  static Future<_McpConnection> start({
    required String command,
    required List<String> args,
    required Duration startupTimeout,
  }) async {
    final process = await Process.start(command, args);
    final connection = _McpConnection._(
      process: process,
      startupTimeout: startupTimeout,
    );
    final initialize = await connection.request(
      'initialize',
      <String, Object?>{
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': <String, Object?>{
          'name': 'flutterhelm-runtime-driver',
          'version': '0.1.0',
        },
      },
    );
    final toolsList = await connection.request(
      'tools/list',
      <String, Object?>{},
    );
    final serverInfo =
        initialize['serverInfo'] as Map<Object?, Object?>? ??
        const <Object?, Object?>{};
    final tools =
        toolsList['tools'] as List<Object?>? ?? const <Object?>[];
    final toolNames = tools
        .whereType<Map>()
        .map((Map tool) => tool['name']?.toString() ?? '')
        .where((String name) => name.isNotEmpty)
        .toSet();
    connection.serverName = serverInfo['name'] as String? ?? 'runtime-driver';
    connection.serverVersion = serverInfo['version'] as String?;
    connection.toolNames = toolNames;
    return connection;
  }

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> params,
  ) {
    final id = (_nextRequestId++).toString();
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[id] = completer;
    process.stdin.writeln(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return completer.future.timeout(startupTimeout);
  }

  void _handleStdoutLine(String line) {
    final message = _tryParseJson(line);
    if (message == null) {
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
    if (message['error'] != null) {
      completer.completeError(StateError(jsonEncode(message['error'])));
      return;
    }
    completer.complete(_coerceMap(message['result']));
  }
}

Object? _decodeToolPayload(Map<String, Object?> result) {
  final content = result['content'];
  if (content is! List) {
    return result;
  }
  final texts = <String>[];
  for (final item in content) {
    if (item is! Map) {
      continue;
    }
    final text = item['text'];
    if (text is String && text.isNotEmpty) {
      texts.add(text);
    }
  }
  if (texts.isEmpty) {
    return result;
  }
  final joined = texts.join('\n').trim();
  try {
    return jsonDecode(joined);
  } catch (_) {
    return joined;
  }
}

Object? _decodeEmbeddedJson(String text) {
  final firstArray = text.indexOf('[');
  final firstObject = text.indexOf('{');
  final indexes = <int>[
    if (firstArray >= 0) firstArray,
    if (firstObject >= 0) firstObject,
  ]..sort();
  if (indexes.isEmpty) {
    return text;
  }
  final candidate = text.substring(indexes.first).trim();
  try {
    return jsonDecode(candidate);
  } catch (_) {
    return text;
  }
}

Map<String, Object?>? _tryParseJson(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
    return null;
  }
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, Object?>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map<String, Object?>(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key.toString(), value),
      );
    }
  } catch (_) {
    return null;
  }
  return null;
}

Map<String, Object?> _coerceMap(Object? value) {
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return value.map<String, Object?>(
      (Object? key, Object? nested) =>
          MapEntry<String, Object?>(key.toString(), nested),
    );
  }
  return <String, Object?>{};
}

String? _coerceString(Object? value) {
  if (value is String && value.isNotEmpty) {
    return value;
  }
  return null;
}

double? _coerceDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

bool? _coerceBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is String) {
    if (value == 'true') {
      return true;
    }
    if (value == 'false') {
      return false;
    }
  }
  return null;
}
