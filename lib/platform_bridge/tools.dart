import 'dart:io';

import 'package:flutterhelm/artifacts/resources.dart';
import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/platform_bridge/support.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/sessions/session_store.dart';
import 'package:path/path.dart' as p;

class NativeBridgeToolService {
  NativeBridgeToolService({
    required this.sessionStore,
    required this.artifactStore,
  });

  final SessionStore sessionStore;
  final ArtifactStore artifactStore;

  Future<Map<String, Object?>> iosDebugContext({
    required String sessionId,
    required int tailLines,
  }) {
    return _nativeDebugContext(
      sessionId: sessionId,
      platform: 'ios',
      tailLines: tailLines,
    );
  }

  Future<Map<String, Object?>> androidDebugContext({
    required String sessionId,
    required int tailLines,
  }) {
    return _nativeDebugContext(
      sessionId: sessionId,
      platform: 'android',
      tailLines: tailLines,
    );
  }

  Future<Map<String, Object?>> nativeHandoffSummary({
    required String sessionId,
    String? platform,
  }) async {
    final session = sessionStore.requireById(sessionId);
    final requestedPlatforms = platform == null || platform.isEmpty
        ? _summaryPlatforms(session)
        : <String>[_validatedPlatform(platform)];

    final bundleSummaries = <Map<String, Object?>>[];
    final resources = <Map<String, Object?>>[];
    for (final selectedPlatform in requestedPlatforms) {
      final bundle = await _ensureBundle(
        session: session,
        platform: selectedPlatform,
        tailLines: 200,
      );
      final resource = _bundleResource(sessionId, selectedPlatform);
      bundleSummaries.add(<String, Object?>{
        'platform': selectedPlatform,
        'status': bundle['status'],
        'summary': bundle['summary'],
      });
      resources.add(resource);
    }

    return <String, Object?>{
      'sessionId': sessionId,
      'platforms': bundleSummaries,
      'summary': <String, Object?>{
        'bundleCount': bundleSummaries.length,
        'availablePlatforms': detectNativeBridgePlatformsSync(session.workspaceRoot),
        'sessionState': session.state.wireName,
      },
      'resources': resources,
    };
  }

  Future<Map<String, Object?>> _nativeDebugContext({
    required String sessionId,
    required String platform,
    required int tailLines,
  }) async {
    final session = sessionStore.requireById(sessionId);
    final bundle = await _ensureBundle(
      session: session,
      platform: platform,
      tailLines: tailLines,
    );
    return <String, Object?>{
      'sessionId': sessionId,
      'platform': platform,
      'status': bundle['status'],
      'summary': bundle['summary'],
      'resource': _bundleResource(sessionId, platform),
    };
  }

  Future<Map<String, Object?>> _ensureBundle({
    required SessionRecord session,
    required String platform,
    required int tailLines,
  }) async {
    final normalizedPlatform = _validatedPlatform(platform);
    final bundle = await _buildBundle(
      session: session,
      platform: normalizedPlatform,
      tailLines: tailLines,
    );
    await artifactStore.writeSessionNativeHandoff(
      sessionId: session.sessionId,
      platform: normalizedPlatform,
      payload: bundle,
    );
    return bundle;
  }

  Future<Map<String, Object?>> _buildBundle({
    required SessionRecord session,
    required String platform,
    required int tailLines,
  }) async {
    final workspaceRoot = session.workspaceRoot;
    final availablePlatforms = detectNativeBridgePlatformsSync(workspaceRoot);
    final openPaths = collectNativeBridgeOpenPathsSync(workspaceRoot, platform);
    final fileHints = collectNativeBridgeFileHintsSync(workspaceRoot, platform);
    final logPreview = await _logPreview(session.sessionId, tailLines);
    final evidenceResources = await _evidenceResources(session.sessionId);
    final hypotheses = await _hypotheses(
      session: session,
      platform: platform,
      availablePlatforms: availablePlatforms,
      logPreview: logPreview,
      fileHints: fileHints,
    );
    final status = !availablePlatforms.contains(platform)
        ? 'unavailable'
        : evidenceResources.isEmpty
            ? 'partial'
            : 'ready';

    return <String, Object?>{
      'sessionId': session.sessionId,
      'platform': platform,
      'status': status,
      'workspaceRoot': workspaceRoot,
      'session': session.toSummaryJson(),
      'summary': <String, Object?>{
        'sessionState': session.state.wireName,
        'ownership': session.ownership.wireName,
        'stale': session.stale,
        'availablePlatforms': availablePlatforms,
        'openPathCount': openPaths.length,
        'evidenceCount': evidenceResources.length,
        'hypothesisCount': hypotheses.length,
      },
      'openPaths': openPaths
          .map((NativeBridgePathHint hint) => hint.toJson())
          .toList(),
      'evidenceResources': evidenceResources,
      'fileHints': fileHints
          .map((NativeBridgePathHint hint) => hint.toJson())
          .toList(),
      'hypotheses': hypotheses,
      'nextSteps': _nextSteps(
        platform: platform,
        status: status,
        openPaths: openPaths,
      ),
      'limitations': _limitations(platform),
      'recentLogPreview': logPreview,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<List<Map<String, Object?>>> _evidenceResources(String sessionId) async {
    final descriptors = await artifactStore.listSessionResources(sessionId);
    final evidence = <Map<String, Object?>>[
      <String, Object?>{
        'uri': artifactStore.sessionSummaryUri(sessionId),
        'mimeType': 'application/json',
        'title': 'Session summary',
      },
      <String, Object?>{
        'uri': artifactStore.sessionHealthUri(sessionId),
        'mimeType': 'application/json',
        'title': 'Session health',
      },
    ];
    final sortedDescriptors = descriptors
        .where((ResourceDescriptor descriptor) => !descriptor.uri.startsWith('native-handoff://'))
        .toList()
      ..sort((left, right) => _resourcePriority(left.uri).compareTo(_resourcePriority(right.uri)));
    evidence.addAll(
      sortedDescriptors.map((ResourceDescriptor descriptor) {
        return <String, Object?>{
          'uri': descriptor.uri,
          'mimeType': descriptor.mimeType,
          'title': descriptor.title,
        };
      }),
    );
    return evidence;
  }

  Future<Map<String, Object?>> _logPreview(String sessionId, int tailLines) async {
    final stdout = await artifactStore.readStoredResource(
      artifactStore.sessionLogUri(sessionId, 'stdout'),
    );
    final stderr = await artifactStore.readStoredResource(
      artifactStore.sessionLogUri(sessionId, 'stderr'),
    );
    final stdoutText = stdout?.text ?? '';
    final stderrText = stderr?.text ?? '';
    return <String, Object?>{
      if (stdoutText.trim().isNotEmpty) 'stdout': _tailLines(stdoutText, tailLines),
      if (stderrText.trim().isNotEmpty) 'stderr': _tailLines(stderrText, tailLines),
    };
  }

  Future<List<String>> _hypotheses({
    required SessionRecord session,
    required String platform,
    required List<String> availablePlatforms,
    required Map<String, Object?> logPreview,
    required List<NativeBridgePathHint> fileHints,
  }) async {
    final hypotheses = <String>[];

    if (!availablePlatforms.contains(platform)) {
      hypotheses.add(
        'No $platform native project was detected under ${session.workspaceRoot}; inspect generated platform folders before escalating to a native IDE.',
      );
      return hypotheses;
    }

    if (session.state == SessionState.failed) {
      hypotheses.add(
        'The Flutter session failed before or during runtime; inspect startup stderr and machine logs before debugging natively.',
      );
    }
    if (session.stale) {
      hypotheses.add(
        'The session is stale; reproduce once more if you need fresh runtime evidence before handing off to a native debugger.',
      );
    }

    if (platform == 'ios') {
      final infoPlistPath = p.join(session.workspaceRoot, 'ios', 'Runner', 'Info.plist');
      final infoPlist = await _readFileIfExists(infoPlistPath);
      final hasLocalNetworkUsageDescription =
          infoPlist.contains('<key>NSLocalNetworkUsageDescription</key>');
      final hasBonjourServices =
          infoPlist.contains('<key>NSBonjourServices</key>');
      final previewText = logPreview.values.join('\n').toLowerCase();

      if (!session.vmServiceAvailable) {
        hypotheses.add(
          'VM service was unavailable for this iOS session; on iOS 14+ verify that the Local Network permission prompt was allowed and retry the attach/debug flow.',
        );
      }
      if (!hasLocalNetworkUsageDescription || !hasBonjourServices) {
        hypotheses.add(
          'Info.plist does not show explicit local-network related keys; if attach, hot reload, or DevTools connectivity fails on device, verify Local Network permission and Bonjour-related configuration.',
        );
      }
      if (previewText.contains('local network') ||
          previewText.contains('bonjour') ||
          previewText.contains('permission')) {
        hypotheses.add(
          'Recent logs mention network or permission signals; inspect Info.plist and the device permission state before assuming a Flutter-side failure.',
        );
      }
    }

    if (platform == 'android' && fileHints.isNotEmpty) {
      hypotheses.add(
        'Review AndroidManifest and Gradle configuration first; native-side startup or permission issues often surface there before Flutter logs become conclusive.',
      );
    }

    return hypotheses;
  }

  List<String> _nextSteps({
    required String platform,
    required String status,
    required List<NativeBridgePathHint> openPaths,
  }) {
    if (status == 'unavailable') {
      return <String>[
        'Generate or restore the native project for this platform, then rerun the handoff tool.',
        'Review the Flutter workspace root and platform-specific folders before escalating.',
      ];
    }

    final steps = <String>[
      if (openPaths.isNotEmpty)
        'Open ${openPaths.first.path} in ${platform == 'ios' ? 'Xcode' : 'Android Studio'}.',
      'Review linked session, health, and log resources before reproducing in the native IDE.',
    ];
    if (platform == 'ios') {
      steps.add(
        'If attach, hot reload, or DevTools connectivity fails on iOS 14+, re-check the Local Network permission prompt and Info.plist configuration.',
      );
    }
    return steps;
  }

  List<String> _limitations(String platform) {
    return <String>[
      'FlutterHelm does not automate ${platform == 'ios' ? 'Xcode' : 'Android Studio'} in this workflow.',
      'This bundle is a handoff aid, not a native debugger replacement.',
      'Hypotheses are heuristic and should be validated in native tooling before concluding root cause.',
    ];
  }

  Map<String, Object?> _bundleResource(String sessionId, String platform) {
    return <String, Object?>{
      'uri': artifactStore.sessionNativeHandoffUri(sessionId, platform),
      'mimeType': 'application/json',
      'title': '${platform == 'ios' ? 'iOS' : 'Android'} native handoff bundle',
    };
  }

  List<String> _summaryPlatforms(SessionRecord session) {
    final availablePlatforms = detectNativeBridgePlatformsSync(session.workspaceRoot);
    if (availablePlatforms.isNotEmpty) {
      return availablePlatforms;
    }
    if (session.platform == 'ios' || session.platform == 'android') {
      return <String>[session.platform!];
    }
    return const <String>[];
  }

  String _validatedPlatform(String platform) {
    if (platform == 'ios' || platform == 'android') {
      return platform;
    }
    throw FlutterHelmToolError(
      code: 'INVALID_PLATFORM',
      category: 'validation',
      message: 'Unsupported native bridge platform: $platform',
      retryable: false,
    );
  }

  int _resourcePriority(String uri) {
    if (uri.startsWith('session://')) {
      return 0;
    }
    if (uri.startsWith('runtime-errors://')) {
      return 1;
    }
    if (uri.startsWith('app-state://')) {
      return 2;
    }
    if (uri.startsWith('log://')) {
      return 3;
    }
    if (uri.startsWith('widget-tree://')) {
      return 4;
    }
    if (uri.startsWith('cpu://') ||
        uri.startsWith('timeline://') ||
        uri.startsWith('memory://')) {
      return 5;
    }
    return 10;
  }

  String _tailLines(String text, int maxLines) {
    final lines = text.trimRight().split('\n');
    if (lines.isEmpty) {
      return '';
    }
    final start = lines.length > maxLines ? lines.length - maxLines : 0;
    return lines.skip(start).join('\n');
  }

  Future<String> _readFileIfExists(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return '';
    }
    return file.readAsString();
  }
}
