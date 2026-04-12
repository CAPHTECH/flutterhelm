import 'dart:io';

import 'package:path/path.dart' as p;

class NativeBridgePathHint {
  const NativeBridgePathHint({
    required this.path,
    required this.label,
    required this.reason,
  });

  final String path;
  final String label;
  final String reason;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'path': path,
      'label': label,
      'reason': reason,
    };
  }
}

List<String> detectNativeBridgePlatformsSync(String workspaceRoot) {
  final platforms = <String>[];
  if (hasNativeBridgeProjectSync(workspaceRoot, 'ios')) {
    platforms.add('ios');
  }
  if (hasNativeBridgeProjectSync(workspaceRoot, 'android')) {
    platforms.add('android');
  }
  return platforms;
}

bool hasNativeBridgeProjectSync(String workspaceRoot, String platform) {
  switch (platform) {
    case 'ios':
      return collectNativeBridgeOpenPathsSync(workspaceRoot, platform).isNotEmpty;
    case 'android':
      return collectNativeBridgeOpenPathsSync(workspaceRoot, platform).isNotEmpty;
    default:
      return false;
  }
}

List<NativeBridgePathHint> collectNativeBridgeOpenPathsSync(
  String workspaceRoot,
  String platform,
) {
  switch (platform) {
    case 'ios':
      return _existingHints(<NativeBridgePathHint>[
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Runner.xcworkspace'),
          label: 'Xcode workspace',
          reason: 'Open this workspace in Xcode for native debugging and signing context.',
        ),
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Runner.xcodeproj'),
          label: 'Xcode project',
          reason: 'Fallback project entry when the workspace is unavailable.',
        ),
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Runner', 'Info.plist'),
          label: 'Info.plist',
          reason: 'Inspect runtime permissions and iOS app metadata.',
        ),
      ]);
    case 'android':
      return _existingHints(<NativeBridgePathHint>[
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'android'),
          label: 'Android project root',
          reason: 'Open this directory in Android Studio for Gradle and manifest context.',
        ),
        NativeBridgePathHint(
          path: p.join(
            workspaceRoot,
            'android',
            'app',
            'src',
            'main',
            'AndroidManifest.xml',
          ),
          label: 'AndroidManifest.xml',
          reason: 'Inspect permissions, activities, and intent filters.',
        ),
        NativeBridgePathHint(
          path: _firstExistingPath(<String>[
            p.join(workspaceRoot, 'android', 'app', 'build.gradle.kts'),
            p.join(workspaceRoot, 'android', 'app', 'build.gradle'),
          ]),
          label: 'App Gradle build file',
          reason: 'Inspect plugin, SDK, and dependency configuration.',
        ),
      ]);
    default:
      return const <NativeBridgePathHint>[];
  }
}

List<NativeBridgePathHint> collectNativeBridgeFileHintsSync(
  String workspaceRoot,
  String platform,
) {
  switch (platform) {
    case 'ios':
      return _existingHints(<NativeBridgePathHint>[
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Runner', 'Info.plist'),
          label: 'Info.plist',
          reason: 'Check permissions, bundle metadata, and local network related keys.',
        ),
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Runner', 'AppDelegate.swift'),
          label: 'AppDelegate.swift',
          reason: 'Inspect app startup and plugin initialization.',
        ),
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Podfile'),
          label: 'Podfile',
          reason: 'Inspect CocoaPods integration and iOS deployment configuration.',
        ),
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'ios', 'Flutter', 'Generated.xcconfig'),
          label: 'Generated.xcconfig',
          reason: 'Inspect generated build settings passed from Flutter.',
        ),
      ]);
    case 'android':
      return _existingHints(<NativeBridgePathHint>[
        NativeBridgePathHint(
          path: p.join(
            workspaceRoot,
            'android',
            'app',
            'src',
            'main',
            'AndroidManifest.xml',
          ),
          label: 'AndroidManifest.xml',
          reason: 'Check permissions, application config, and exported components.',
        ),
        NativeBridgePathHint(
          path: _firstExistingPath(<String>[
            p.join(workspaceRoot, 'android', 'app', 'build.gradle.kts'),
            p.join(workspaceRoot, 'android', 'app', 'build.gradle'),
          ]),
          label: 'app build.gradle',
          reason: 'Inspect per-app Android build configuration.',
        ),
        NativeBridgePathHint(
          path: _firstExistingPath(<String>[
            p.join(workspaceRoot, 'android', 'settings.gradle.kts'),
            p.join(workspaceRoot, 'android', 'settings.gradle'),
          ]),
          label: 'settings.gradle',
          reason: 'Inspect module inclusion and plugin management.',
        ),
        NativeBridgePathHint(
          path: p.join(workspaceRoot, 'android', 'gradle.properties'),
          label: 'gradle.properties',
          reason: 'Inspect Gradle flags that may affect native builds or runtime behavior.',
        ),
      ]);
    default:
      return const <NativeBridgePathHint>[];
  }
}

List<NativeBridgePathHint> _existingHints(List<NativeBridgePathHint> candidates) {
  return candidates
      .where((NativeBridgePathHint hint) => hint.path.isNotEmpty)
      .where((NativeBridgePathHint hint) {
        final type = FileSystemEntity.typeSync(hint.path, followLinks: true);
        return type != FileSystemEntityType.notFound;
      })
      .toList();
}

String _firstExistingPath(List<String> candidates) {
  for (final candidate in candidates) {
    final type = FileSystemEntity.typeSync(candidate, followLinks: true);
    if (type != FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return candidates.first;
}
