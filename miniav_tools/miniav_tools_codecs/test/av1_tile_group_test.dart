@TestOn('vm')
library;

import 'package:miniav_tools_codecs/src/av1/av1_tile_group.dart';
import 'package:test/test.dart';

void main() {
  group('buildAllSkipTileGroup', () {
    test('64x64 emits 4 symbols (1 SB)', () {
      final tg = buildAllSkipTileGroup(frameWidth: 64, frameHeight: 64);
      expect(tg.symbolsEmitted, 4);
      expect(tg.payload, isNotEmpty);
    });

    test('128x128 emits 16 symbols (2x2 SBs)', () {
      final tg = buildAllSkipTileGroup(frameWidth: 128, frameHeight: 128);
      expect(tg.symbolsEmitted, 16);
    });

    test('256x128 emits 32 symbols (4x2 SBs)', () {
      final tg = buildAllSkipTileGroup(frameWidth: 256, frameHeight: 128);
      expect(tg.symbolsEmitted, 32);
    });

    test('64x256 emits 16 symbols (1x4 SBs)', () {
      final tg = buildAllSkipTileGroup(frameWidth: 64, frameHeight: 256);
      expect(tg.symbolsEmitted, 16);
    });

    test('rejects non-multiple-of-64 dims', () {
      expect(
        () => buildAllSkipTileGroup(frameWidth: 96, frameHeight: 64),
        throwsArgumentError,
      );
      expect(
        () => buildAllSkipTileGroup(frameWidth: 64, frameHeight: 96),
        throwsArgumentError,
      );
    });

    test('payload grows monotonically with SB count', () {
      final p64 = buildAllSkipTileGroup(
        frameWidth: 64,
        frameHeight: 64,
      ).payload.length;
      final p128 = buildAllSkipTileGroup(
        frameWidth: 128,
        frameHeight: 128,
      ).payload.length;
      final p256 = buildAllSkipTileGroup(
        frameWidth: 256,
        frameHeight: 256,
      ).payload.length;
      expect(p128, greaterThan(p64));
      expect(p256, greaterThan(p128));
    });
  });
}
