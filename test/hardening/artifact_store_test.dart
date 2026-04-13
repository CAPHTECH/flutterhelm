import 'dart:io';

import 'package:flutterhelm/artifacts/store.dart';
import 'package:flutterhelm/config/config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ArtifactStore retention', () {
    test('preserves pinned artifacts while sweeping old files', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-artifacts');
      addTearDown(() => sandbox.delete(recursive: true));

      final store = ArtifactStore(stateDir: sandbox.path);
      final sessionDir = Directory(store.sessionArtifactsDir('sess_1'));
      await sessionDir.create(recursive: true);

      final pinnedFile = File(p.join(sessionDir.path, 'screenshot-shot_1.png'));
      await pinnedFile.writeAsBytes(<int>[1, 2, 3]);
      await pinnedFile.setLastModified(
        DateTime.now().toUtc().subtract(const Duration(days: 10)),
      );

      final staleFile = File(p.join(sessionDir.path, 'runtime-errors-current.json'));
      await staleFile.writeAsString('{"count":1}');
      await staleFile.setLastModified(
        DateTime.now().toUtc().subtract(const Duration(days: 10)),
      );

      final result = await store.sweepRetention(
        retention: const RetentionConfig(
          heavyArtifactsDays: 1,
          metadataDays: 30,
          maxArtifactBytes: 1024,
        ),
        pinnedUris: <String>{store.sessionScreenshotUri('sess_1', 'shot_1', 'png')},
      );

      expect(result['removedCount'], 1);
      expect(await pinnedFile.exists(), isTrue);
      expect(await staleFile.exists(), isFalse);
    });

    test('evicts oldest unpinned artifacts when capacity is exceeded', () async {
      final sandbox = await Directory.systemTemp.createTemp('flutterhelm-artifacts');
      addTearDown(() => sandbox.delete(recursive: true));

      final store = ArtifactStore(stateDir: sandbox.path);
      await store.writeSessionScreenshot(
        sessionId: 'sess_capacity',
        captureId: 'old',
        format: 'png',
        bytes: List<int>.filled(700, 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.writeSessionScreenshot(
        sessionId: 'sess_capacity',
        captureId: 'new',
        format: 'png',
        bytes: List<int>.filled(700, 2),
      );

      final result = await store.sweepRetention(
        retention: const RetentionConfig(
          heavyArtifactsDays: 30,
          metadataDays: 30,
          maxArtifactBytes: 900,
        ),
        pinnedUris: const <String>{},
      );

      expect(result['capacityRemovedCount'], 1);
      expect(
        await store.storedResourceExists(
          store.sessionScreenshotUri('sess_capacity', 'old', 'png'),
        ),
        isFalse,
      );
      expect(
        await store.storedResourceExists(
          store.sessionScreenshotUri('sess_capacity', 'new', 'png'),
        ),
        isTrue,
      );
    });
  });
}
