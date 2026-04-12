import 'dart:async';
import 'dart:convert';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/platform_bridge/support.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:flutterhelm/runtime/vm_service_support.dart';

class RuntimeToolService {
  RuntimeToolService({
    required this.sessionStore,
    required this.artifactStore,
  });

  final SessionStore sessionStore;
  final ArtifactStore artifactStore;

  Future<Map<String, Object?>> getLogs({
    required String sessionId,
    required String stream,
    required int tailLines,
  }) async {
    sessionStore.requireById(sessionId);
    final streams = switch (stream) {
      'stdout' => const <String>['stdout'],
      'stderr' => const <String>['stderr'],
      _ => const <String>['stdout', 'stderr'],
    };
    final previews = <String, String>{};
    for (final selectedStream in streams) {
      final resource = await artifactStore.readStoredResource(
        artifactStore.sessionLogUri(sessionId, selectedStream),
      );
      final lines = (resource?.text ?? '').trimRight().split('\n');
      previews[selectedStream] = lines.isEmpty
          ? ''
          : lines.skip(lines.length > tailLines ? lines.length - tailLines : 0).join('\n');
    }
    return <String, Object?>{
      'sessionId': sessionId,
      'stream': stream,
      'tailLines': tailLines,
      'preview': previews,
      'resources': <Map<String, Object?>>[
        for (final selectedStream in streams)
          <String, Object?>{
            'uri': artifactStore.sessionLogUri(sessionId, selectedStream),
            'mimeType': 'text/plain',
            'title': 'Session $selectedStream logs',
          },
      ],
    };
  }

  Future<Map<String, Object?>> getRuntimeErrors({required String sessionId}) async {
    sessionStore.requireById(sessionId);
    final stdout = await artifactStore.readStoredResource(artifactStore.sessionLogUri(sessionId, 'stdout'));
    final stderr = await artifactStore.readStoredResource(artifactStore.sessionLogUri(sessionId, 'stderr'));
    final errors = <Map<String, Object?>>[
      ..._parseErrors(stdout?.text ?? '', 'stdout'),
      ..._parseErrors(stderr?.text ?? '', 'stderr'),
    ];
    final payload = <String, Object?>{
      'sessionId': sessionId,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'errors': errors,
    };
    await artifactStore.writeSessionRuntimeErrors(sessionId: sessionId, payload: payload);
    return <String, Object?>{
      'sessionId': sessionId,
      'count': errors.length,
      'resource': <String, Object?>{
        'uri': artifactStore.sessionRuntimeErrorsUri(sessionId),
        'mimeType': 'application/json',
        'title': 'Runtime errors',
      },
      'errors': errors.take(5).toList(),
    };
  }

  Future<Map<String, Object?>> getAppStateSummary({required String sessionId}) async {
    final session = sessionStore.requireById(sessionId);
    final payload = <String, Object?>{
      'sessionId': session.sessionId,
      'ownership': session.ownership.wireName,
      'state': session.state.wireName,
      'stale': session.stale,
      'platform': session.platform,
      'deviceId': session.deviceId,
      'target': session.target,
      'mode': session.mode,
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
      'profileActive': session.profileActive,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await artifactStore.writeSessionAppState(sessionId: sessionId, payload: payload);
    return <String, Object?>{
      ...payload,
      'resource': <String, Object?>{
        'uri': artifactStore.sessionAppStateUri(sessionId),
        'mimeType': 'application/json',
        'title': 'App state summary',
      },
    };
  }

  Future<Map<String, Object?>> getWidgetTree({
    required String sessionId,
    required int depth,
    required bool includeProperties,
  }) async {
    sessionStore.requireById(sessionId);
    final rawVmServiceUri = sessionStore.liveHandle(sessionId)?.vmServiceUri;
    if (rawVmServiceUri == null || rawVmServiceUri.isEmpty) {
      throw FlutterHelmToolError(
        code: 'WIDGET_TREE_UNAVAILABLE',
        category: 'runtime',
        message: 'Widget tree requires a live VM service connection.',
        retryable: true,
      );
    }

    final vmSession = await VmServiceSession.connect(
      rawVmServiceUri,
      requiredExtension: 'ext.flutter.inspector.getRootWidgetTree',
    );
    try {
      final response = await vmSession.service.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetTree',
        isolateId: vmSession.isolate.id,
        args: <String, String>{
          'groupName': 'flutterhelm-$sessionId',
          'isSummaryTree': 'true',
          'withPreviews': 'false',
          'fullDetails': includeProperties ? 'true' : 'false',
        },
      );
      final rawResult = response.json?['result'];
      final tree = _normalizeJson(rawResult);
      final trimmed = _trimTree(tree, depth);
      final payload = <String, Object?>{
        'sessionId': sessionId,
        'depth': depth,
        'includeProperties': includeProperties,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
        'tree': trimmed,
      };
      await artifactStore.writeSessionWidgetTree(
        sessionId: sessionId,
        depth: depth,
        payload: payload,
      );
      return <String, Object?>{
        'sessionId': sessionId,
        'resource': <String, Object?>{
          'uri': artifactStore.sessionWidgetTreeUri(sessionId, depth),
          'mimeType': 'application/json',
          'title': 'Widget tree snapshot',
        },
        'summary': <String, Object?>{
          'rootWidget': (trimmed['description'] as String?) ?? (trimmed['name'] as String?) ?? 'unknown',
          'captureTime': payload['capturedAt'],
          'depth': depth,
        },
      };
    } finally {
      await vmSession.dispose();
    }
  }

  List<Map<String, Object?>> _parseErrors(String text, String stream) {
    final errors = <Map<String, Object?>>[];
    final lines = text.split('\n');
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trimRight();
      final normalized = line.startsWith('flutter: ')
          ? line.substring('flutter: '.length)
          : line;
      if (normalized.startsWith('A RenderFlex overflowed by')) {
        errors.add(<String, Object?>{
          'kind': 'layout_overflow',
          'summary': normalized,
          'stream': stream,
          'line': index + 1,
        });
      } else if (normalized.contains('EXCEPTION CAUGHT') || normalized.startsWith('Unhandled Exception:')) {
        errors.add(<String, Object?>{
          'kind': 'exception',
          'summary': normalized,
          'stream': stream,
          'line': index + 1,
        });
      }
    }
    return errors;
  }

  Map<String, Object?> _normalizeJson(Object? value) {
    if (value is Map<String, Object?>) {
      return value;
    }
    if (value is Map) {
      return value.map<String, Object?>(
        (Object? key, Object? nested) => MapEntry<String, Object?>(key.toString(), nested),
      );
    }
    if (value is String && value.isNotEmpty) {
      final decoded = jsonDecode(value);
      return _normalizeJson(decoded);
    }
    return <String, Object?>{};
  }

  Map<String, Object?> _trimTree(Map<String, Object?> node, int depth) {
    if (depth <= 1) {
      return <String, Object?>{
        for (final entry in node.entries)
          if (entry.key != 'children' && entry.key != 'properties') entry.key: entry.value,
        'children': const <Object?>[],
      };
    }
    final children = node['children'];
    final trimmedChildren = <Map<String, Object?>>[];
    if (children is List) {
      for (final child in children) {
        trimmedChildren.add(_trimTree(_normalizeJson(child), depth - 1));
      }
    }
    return <String, Object?>{
      for (final entry in node.entries)
        if (entry.key != 'children') entry.key: entry.value,
      'children': trimmedChildren,
    };
  }
}
