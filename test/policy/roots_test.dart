import 'dart:io';

import 'package:flutterhelm/flutterhelm.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('RootPolicy', () {
    test('accepts workspace roots inside client roots', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-roots',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final workspace = Directory(p.join(tempDir.path, 'app'));
      await workspace.create(recursive: true);
      await File(
        p.join(workspace.path, 'pubspec.yaml'),
      ).writeAsString('name: app');

      final policy = RootPolicy(allowRootFallback: false);
      final validated = await policy.validateWorkspaceRoot(
        requestedRoot: workspace.path,
        clientRoots: <String>[tempDir.path],
      );

      expect(validated, await workspace.resolveSymbolicLinks());
    });

    test('rejects roots outside client boundaries', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-roots',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final outside = Directory(p.join(tempDir.path, 'outside'));
      await outside.create(recursive: true);
      await File(
        p.join(outside.path, 'pubspec.yaml'),
      ).writeAsString('name: outside');

      final policy = RootPolicy(allowRootFallback: false);
      await expectLater(
        () => policy.validateWorkspaceRoot(
          requestedRoot: outside.path,
          clientRoots: <String>[p.join(tempDir.path, 'allowed')],
        ),
        throwsA(isA<FlutterHelmToolError>()),
      );
    });

    test('requires explicit fallback when client roots are missing', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'flutterhelm-roots',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final workspace = Directory(p.join(tempDir.path, 'app'));
      await workspace.create(recursive: true);
      await File(
        p.join(workspace.path, 'pubspec.yaml'),
      ).writeAsString('name: app');

      final policy = RootPolicy(allowRootFallback: false);
      await expectLater(
        () => policy.validateWorkspaceRoot(
          requestedRoot: workspace.path,
          clientRoots: const <String>[],
        ),
        throwsA(isA<FlutterHelmToolError>()),
      );
    });
  });
}
