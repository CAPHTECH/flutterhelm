import 'dart:convert';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/observability/store.dart';
import 'package:flutterhelm/policies/roots.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';
import 'package:flutterhelm/server/support_levels.dart';

typedef SessionHealthPayloadBuilder =
    Future<Map<String, Object?>> Function(SessionRecord session);
typedef SessionAppStatePayloadBuilder =
    Future<Map<String, Object?>> Function(SessionRecord session);
typedef JsonResourcePayloadBuilder = Future<Map<String, Object?>> Function();
typedef CompatibilityPayloadBuilder =
    Future<Map<String, Object?>> Function(
      FlutterHelmConfig config,
      ServerState state,
      String transportMode,
    );
typedef AdaptersPayloadBuilder = Future<Map<String, Object?>> Function();
typedef ArtifactStatusPayloadBuilder =
    Future<Map<String, Object?>> Function(FlutterHelmConfig config);
typedef ObservabilityPayloadBuilder = Future<Map<String, Object?>> Function();

class ResourceDescriptor {
  const ResourceDescriptor({
    required this.uri,
    required this.name,
    required this.title,
    required this.description,
    required this.mimeType,
    required this.createdAt,
    required this.lastModified,
    this.size,
    this.sessionId,
  });

  final String uri;
  final String name;
  final String title;
  final String description;
  final String mimeType;
  final DateTime createdAt;
  final DateTime lastModified;
  final int? size;
  final String? sessionId;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'uri': uri,
      'name': name,
      'title': title,
      'description': description,
      'mimeType': mimeType,
      if (size != null) 'size': size,
      if (size != null) 'sizeBytes': size,
      'createdAt': createdAt.toUtc().toIso8601String(),
      if (sessionId != null) 'sessionId': sessionId,
      'annotations': <String, Object?>{
        'audience': const <String>['user', 'assistant'],
        'priority': 0.8,
        'lastModified': lastModified.toUtc().toIso8601String(),
      },
    };
  }

  Map<String, Object?> toResourceLink() {
    return <String, Object?>{
      'type': 'resource_link',
      'uri': uri,
      'name': name,
      'description': description,
      'mimeType': mimeType,
      'annotations': <String, Object?>{
        'audience': const <String>['assistant'],
        'priority': 0.8,
        'lastModified': lastModified.toUtc().toIso8601String(),
      },
    };
  }
}

class ResourceReadResult {
  const ResourceReadResult({
    required this.uri,
    required this.mimeType,
    this.text,
    this.blob,
  });

  final String uri;
  final String mimeType;
  final String? text;
  final String? blob;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'contents': <Map<String, Object?>>[
        <String, Object?>{
          'uri': uri,
          'mimeType': mimeType,
          if (text != null) 'text': text,
          if (blob != null) 'blob': blob,
        },
      ],
    };
  }
}

class ResourceCatalog {
  const ResourceCatalog({
    required this.artifactStore,
    required this.sessionHealthBuilder,
    required this.sessionAppStateBuilder,
    required this.pinsIndexBuilder,
    required this.compatibilityBuilder,
    required this.adaptersBuilder,
    required this.artifactStatusBuilder,
    required this.observabilityBuilder,
    required this.observability,
  });

  final ArtifactStore artifactStore;
  final SessionHealthPayloadBuilder sessionHealthBuilder;
  final SessionAppStatePayloadBuilder sessionAppStateBuilder;
  final JsonResourcePayloadBuilder pinsIndexBuilder;
  final CompatibilityPayloadBuilder compatibilityBuilder;
  final AdaptersPayloadBuilder adaptersBuilder;
  final ArtifactStatusPayloadBuilder artifactStatusBuilder;
  final ObservabilityPayloadBuilder observabilityBuilder;
  final ObservabilityStore observability;

  Future<List<ResourceDescriptor>> listResources({
    required FlutterHelmConfig config,
    required ServerState state,
    required RootSnapshot rootSnapshot,
    required Iterable<SessionRecord> sessions,
  }) async {
    final resources = <ResourceDescriptor>[
      _workspaceCurrentDescriptor(state),
      _workspaceDefaultsDescriptor(config),
      _adaptersDescriptor(),
      _artifactPinsDescriptor(),
      _artifactStatusDescriptor(),
      _observabilityDescriptor(),
      _compatibilityDescriptor(),
      ...sessions.map(_sessionSummaryDescriptor),
      ...sessions.map(_sessionHealthDescriptor),
    ];

    for (final session in sessions) {
      resources.addAll(await artifactStore.listSessionResources(session.sessionId));
    }
    resources.addAll(await artifactStore.listTestRunResources());
    resources.addAll(await artifactStore.listMutationResources());
    resources.sort((left, right) => left.uri.compareTo(right.uri));
    return resources;
  }

  Future<ResourceReadResult> readResource({
    required String uri,
    required FlutterHelmConfig config,
    required ServerState state,
    required RootSnapshot rootSnapshot,
    required SessionRecord? session,
    required String transportMode,
    required bool rootsTransportSupported,
  }) async {
    if (uri == 'config://workspace/current') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(<String, Object?>{
          ...rootSnapshot.toJson(),
          'releaseChannel': flutterHelmReleaseChannel,
          'activeProfile': config.activeProfile,
          'availableProfiles': config.availableProfiles,
          'transportMode': transportMode,
          'httpPreview': transportMode == 'http',
          'rootsTransportSupport': rootsTransportSupported
              ? 'supported'
              : 'unsupported',
          'supportLevels': <String, Object?>{
            'transport': <String, Object?>{
              'stdio': supportLevelMetadata(
                supportLevel: SupportLevel.stable,
                includedInStableLane: true,
              ),
              'http': supportLevelMetadata(
                supportLevel: SupportLevel.preview,
                includedInStableLane: false,
              ),
            },
          },
          'adaptersResource': 'config://adapters/current',
          'compatibilityResource': 'config://compatibility/current',
          'artifactsStatusResource': 'config://artifacts/status',
          'observabilityResource': 'config://observability/current',
          'stableHarnessTags': flutterHelmStableHarnessTags,
          'updatedAt': state.updatedAt?.toUtc().toIso8601String(),
        }),
      );
    }

    if (uri == 'config://workspace/defaults') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(config.toJson()),
      );
    }

    if (uri == 'config://artifacts/pins') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(await pinsIndexBuilder()),
      );
    }

    if (uri == 'config://artifacts/status') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(await artifactStatusBuilder(config)),
      );
    }

    if (uri == 'config://adapters/current') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(await adaptersBuilder()),
      );
    }

    if (uri == 'config://compatibility/current') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(
          await compatibilityBuilder(config, state, transportMode),
        ),
      );
    }

    if (uri == 'config://observability/current') {
      observability.recordResourceRead(uri);
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(await observabilityBuilder()),
      );
    }

    final sessionSummaryMatch = RegExp(r'^session://([^/]+)/summary$').firstMatch(uri);
    if (sessionSummaryMatch != null) {
      if (session == null) {
        throw FlutterHelmToolError(
          code: 'SESSION_NOT_FOUND',
          category: 'runtime',
          message: 'Unknown session for resource: ${sessionSummaryMatch.group(1)}',
          retryable: false,
        );
      }
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(session.toJson()),
      );
    }

    final sessionHealthMatch = RegExp(r'^session://([^/]+)/health$').firstMatch(uri);
    if (sessionHealthMatch != null) {
      if (session == null) {
        throw FlutterHelmToolError(
          code: 'SESSION_NOT_FOUND',
          category: 'runtime',
          message: 'Unknown session for resource: ${sessionHealthMatch.group(1)}',
          retryable: false,
        );
      }
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(await sessionHealthBuilder(session)),
      );
    }

    final appStateMatch = RegExp(r'^app-state://([^/]+)/summary$').firstMatch(uri);
    if (appStateMatch != null) {
      if (session == null) {
        throw FlutterHelmToolError(
          code: 'SESSION_NOT_FOUND',
          category: 'runtime',
          message: 'Unknown session for resource: ${appStateMatch.group(1)}',
          retryable: false,
        );
      }
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(await sessionAppStateBuilder(session)),
      );
    }

    final stored = await artifactStore.readStoredResource(uri);
    if (stored != null) {
      observability.recordResourceRead(uri);
      return stored;
    }

    throw FlutterHelmToolError(
      code: 'RESOURCE_NOT_FOUND',
      category: 'workspace',
      message: 'Unknown resource: $uri',
      retryable: false,
    );
  }

  ResourceDescriptor _workspaceCurrentDescriptor(ServerState state) {
    return ResourceDescriptor(
      uri: 'config://workspace/current',
      name: 'workspace.current',
      title: 'Current workspace configuration',
      description: 'Active root and client roots state.',
      mimeType: 'application/json',
      createdAt: state.updatedAt ?? DateTime.now().toUtc(),
      lastModified: state.updatedAt ?? DateTime.now().toUtc(),
    );
  }

  ResourceDescriptor _workspaceDefaultsDescriptor(FlutterHelmConfig config) {
    return ResourceDescriptor(
      uri: 'config://workspace/defaults',
      name: 'workspace.defaults',
      title: 'Workspace defaults',
      description: 'Resolved config defaults and workflow enablement.',
      mimeType: 'application/json',
      createdAt: DateTime.now().toUtc(),
      lastModified: DateTime.now().toUtc(),
      size: jsonEncode(config.toJson()).length,
    );
  }

  ResourceDescriptor _artifactPinsDescriptor() {
    final now = DateTime.now().toUtc();
    return ResourceDescriptor(
      uri: 'config://artifacts/pins',
      name: 'artifacts.pins',
      title: 'Pinned artifacts index',
      description: 'Pinned file-backed artifact resources.',
      mimeType: 'application/json',
      createdAt: now,
      lastModified: now,
    );
  }

  ResourceDescriptor _artifactStatusDescriptor() {
    final now = DateTime.now().toUtc();
    return ResourceDescriptor(
      uri: 'config://artifacts/status',
      name: 'artifacts.status',
      title: 'Artifact storage status',
      description: 'Current artifact usage, retention, and capacity status.',
      mimeType: 'application/json',
      createdAt: now,
      lastModified: now,
    );
  }

  ResourceDescriptor _adaptersDescriptor() {
    final now = DateTime.now().toUtc();
    return ResourceDescriptor(
      uri: 'config://adapters/current',
      name: 'adapters.current',
      title: 'Current adapter registry state',
      description: 'Active provider selection and provider health by family.',
      mimeType: 'application/json',
      createdAt: now,
      lastModified: now,
    );
  }

  ResourceDescriptor _observabilityDescriptor() {
    final now = DateTime.now().toUtc();
    return ResourceDescriptor(
      uri: 'config://observability/current',
      name: 'observability.current',
      title: 'Current observability snapshot',
      description: 'Runtime counters and timing aggregates for the current process.',
      mimeType: 'application/json',
      createdAt: now,
      lastModified: now,
    );
  }

  ResourceDescriptor _compatibilityDescriptor() {
    final now = DateTime.now().toUtc();
    return ResourceDescriptor(
      uri: 'config://compatibility/current',
      name: 'compatibility.current',
      title: 'Current compatibility matrix',
      description: 'Resolved environment compatibility and workflow support.',
      mimeType: 'application/json',
      createdAt: now,
      lastModified: now,
    );
  }

  ResourceDescriptor _sessionSummaryDescriptor(SessionRecord session) {
    return ResourceDescriptor(
      uri: 'session://${session.sessionId}/summary',
      name: 'session.summary.${session.sessionId}',
      title: 'Session summary ${session.sessionId}',
      description: 'Persisted session record.',
      mimeType: 'application/json',
      createdAt: session.createdAt,
      lastModified: session.lastSeenAt,
      size: jsonEncode(session.toJson()).length,
      sessionId: session.sessionId,
    );
  }

  ResourceDescriptor _sessionHealthDescriptor(SessionRecord session) {
    return ResourceDescriptor(
      uri: 'session://${session.sessionId}/health',
      name: 'session.health.${session.sessionId}',
      title: 'Session health ${session.sessionId}',
      description: 'Profiling and runtime capability guidance for this session.',
      mimeType: 'application/json',
      createdAt: session.createdAt,
      lastModified: session.lastSeenAt,
      sessionId: session.sessionId,
    );
  }
}
