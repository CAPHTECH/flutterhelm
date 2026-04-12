import 'dart:io';

import 'package:flutterhelm/server/errors.dart';
import 'package:path/path.dart' as p;

enum RootsMode { rootsAware, fallback, unconfigured }

extension RootsModeWireName on RootsMode {
  String get wireName {
    switch (this) {
      case RootsMode.rootsAware:
        return 'roots-aware';
      case RootsMode.fallback:
        return 'fallback';
      case RootsMode.unconfigured:
        return 'unconfigured';
    }
  }
}

class RootSnapshot {
  const RootSnapshot({
    required this.mode,
    required this.clientRoots,
    required this.configuredRoots,
    required this.activeRoot,
    required this.allowRootFallback,
  });

  final RootsMode mode;
  final List<String> clientRoots;
  final List<String> configuredRoots;
  final String? activeRoot;
  final bool allowRootFallback;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'rootsMode': mode.wireName,
      'clientRoots': clientRoots,
      'configuredRoots': configuredRoots,
      'activeRoot': activeRoot,
      'allowRootFallback': allowRootFallback,
    };
  }
}

class RootPolicy {
  RootPolicy({required this.allowRootFallback});

  final bool allowRootFallback;

  Future<RootSnapshot> buildSnapshot({
    required List<String> clientRoots,
    required List<String> configuredRoots,
    required String? activeRoot,
  }) async {
    return RootSnapshot(
      mode: resolveMode(clientRoots),
      clientRoots: await canonicalizeDirectories(clientRoots),
      configuredRoots: await canonicalizeDirectories(configuredRoots),
      activeRoot: activeRoot,
      allowRootFallback: allowRootFallback,
    );
  }

  RootsMode resolveMode(List<String> clientRoots) {
    if (clientRoots.isNotEmpty) {
      return RootsMode.rootsAware;
    }
    if (allowRootFallback) {
      return RootsMode.fallback;
    }
    return RootsMode.unconfigured;
  }

  Future<List<String>> canonicalizeDirectories(List<String> roots) async {
    final canonicalRoots = <String>{};
    for (final root in roots) {
      final absoluteRoot = p.normalize(
        p.isAbsolute(root) ? root : p.absolute(root),
      );
      final directory = Directory(absoluteRoot);
      if (await directory.exists()) {
        canonicalRoots.add(await directory.resolveSymbolicLinks());
      } else {
        canonicalRoots.add(absoluteRoot);
      }
    }
    return canonicalRoots.toList()..sort();
  }

  Future<String> validateWorkspaceRoot({
    required String requestedRoot,
    required List<String> clientRoots,
  }) async {
    if (requestedRoot.trim().isEmpty) {
      throw FlutterHelmToolError(
        code: 'WORKSPACE_ROOT_REQUIRED',
        category: 'workspace',
        message: 'workspaceRoot is required.',
        retryable: true,
      );
    }

    final candidate = p.normalize(
      p.isAbsolute(requestedRoot) ? requestedRoot : p.absolute(requestedRoot),
    );
    final directory = Directory(candidate);
    if (!await directory.exists()) {
      throw FlutterHelmToolError(
        code: 'WORKSPACE_ROOT_NOT_FOUND',
        category: 'workspace',
        message: 'Workspace root does not exist: $candidate',
        retryable: false,
      );
    }

    final canonicalRoot = await directory.resolveSymbolicLinks();
    final pubspecFile = File(p.join(canonicalRoot, 'pubspec.yaml'));
    if (!await pubspecFile.exists()) {
      throw FlutterHelmToolError(
        code: 'INVALID_WORKSPACE_ROOT',
        category: 'workspace',
        message: 'Workspace root must contain pubspec.yaml: $canonicalRoot',
        retryable: false,
      );
    }

    final canonicalClientRoots = await canonicalizeDirectories(clientRoots);
    if (canonicalClientRoots.isEmpty && !allowRootFallback) {
      throw FlutterHelmToolError(
        code: 'WORKSPACE_ROOT_REQUIRED',
        category: 'roots',
        message:
            'Client roots are unavailable. Restart with --allow-root-fallback to set a root manually.',
        retryable: false,
      );
    }

    if (canonicalClientRoots.isNotEmpty &&
        !canonicalClientRoots.any(
          (String clientRoot) => _isWithin(clientRoot, canonicalRoot),
        )) {
      throw FlutterHelmToolError(
        code: 'ROOTS_MISMATCH',
        category: 'roots',
        message:
            'Requested workspace root is outside the client-provided roots boundary.',
        retryable: false,
      );
    }

    return canonicalRoot;
  }

  bool _isWithin(String root, String candidate) {
    if (candidate == root) {
      return true;
    }
    return p.isWithin(root, candidate);
  }
}
