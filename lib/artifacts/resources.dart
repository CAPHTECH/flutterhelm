import 'dart:convert';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:flutterhelm/policies/roots.dart';
import 'package:flutterhelm/server/errors.dart';
import 'package:flutterhelm/sessions/session.dart';

class ResourceDescriptor {
  const ResourceDescriptor({
    required this.uri,
    required this.name,
    required this.title,
    required this.description,
    required this.mimeType,
    required this.lastModified,
    this.size,
  });

  final String uri;
  final String name;
  final String title;
  final String description;
  final String mimeType;
  final DateTime lastModified;
  final int? size;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'uri': uri,
      'name': name,
      'title': title,
      'description': description,
      'mimeType': mimeType,
      if (size != null) 'size': size,
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
    required this.text,
  });

  final String uri;
  final String mimeType;
  final String text;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'contents': <Map<String, Object?>>[
        <String, Object?>{'uri': uri, 'mimeType': mimeType, 'text': text},
      ],
    };
  }
}

class ResourceCatalog {
  const ResourceCatalog({required this.artifactStore});

  final ArtifactStore artifactStore;

  Future<List<ResourceDescriptor>> listResources({
    required FlutterHelmConfig config,
    required ServerState state,
    required RootSnapshot rootSnapshot,
    required Iterable<SessionRecord> sessions,
  }) async {
    final resources = <ResourceDescriptor>[
      _workspaceCurrentDescriptor(state),
      _workspaceDefaultsDescriptor(config),
      ...sessions.map(_sessionSummaryDescriptor),
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
  }) async {
    if (uri == 'config://workspace/current') {
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(<String, Object?>{
          ...rootSnapshot.toJson(),
          'updatedAt': state.updatedAt?.toUtc().toIso8601String(),
        }),
      );
    }

    if (uri == 'config://workspace/defaults') {
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(config.toJson()),
      );
    }

    final sessionMatch = RegExp(r'^session://([^/]+)/summary$').firstMatch(uri);
    if (sessionMatch != null) {
      if (session == null) {
        throw FlutterHelmToolError(
          code: 'SESSION_NOT_FOUND',
          category: 'runtime',
          message: 'Unknown session for resource: ${sessionMatch.group(1)}',
          retryable: false,
        );
      }
      return ResourceReadResult(
        uri: uri,
        mimeType: 'application/json',
        text: jsonEncode(session.toJson()),
      );
    }

    final stored = await artifactStore.readStoredResource(uri);
    if (stored != null) {
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
      lastModified: DateTime.now().toUtc(),
      size: jsonEncode(config.toJson()).length,
    );
  }

  ResourceDescriptor _sessionSummaryDescriptor(SessionRecord session) {
    return ResourceDescriptor(
      uri: 'session://${session.sessionId}/summary',
      name: 'session.summary.${session.sessionId}',
      title: 'Session summary ${session.sessionId}',
      description: 'Persisted session record.',
      mimeType: 'application/json',
      lastModified: session.lastSeenAt,
      size: jsonEncode(session.toJson()).length,
    );
  }
}
