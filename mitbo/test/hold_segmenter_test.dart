import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/wall_frame.dart';

import 'support/synthetic_wall.dart';

const _w = 320;
const _h = 400;

/// Red hold centers, in pixels.
const _redHolds = [(60, 50), (200, 90), (110, 170), (250, 260), (80, 340)];

_Wall _mixedWall() {
  final wall = SyntheticWall(_w, _h);
  for (final (x, y) in _redHolds) {
    wall.disc(x, y, 8, wallRed);
  }
  wall
    ..disc(150, 40, 8, wallBlue)
    ..disc(40, 220, 9, wallBlue)
    ..disc(280, 150, 7, wallYellow)
    ..disc(180, 330, 10, wallYellow);
  return wall;
}

double _nx(int x) => (x + 0.5) / _w;
double _ny(int y) => (y + 0.5) / _h;

void main() {
  group('rgbToHsv', () {
    test('converts primaries and grays', () {
      expect(rgbToHsv(255, 0, 0), (h: 0.0, s: 1.0, v: 1.0));
      expect(rgbToHsv(0, 255, 0).h, 120);
      expect(rgbToHsv(0, 0, 255).h, 240);
      final gray = rgbToHsv(128, 128, 128);
      expect(gray.s, 0);
      expect(gray.v, closeTo(0.502, 0.001));
      // Red with more blue than green wraps to just under 360°.
      expect(rgbToHsv(230, 30, 50).h, closeTo(354, 0.01));
    });
  });

  test('hueDistance wraps around the color wheel', () {
    expect(hueDistance(355, 5), 10);
    expect(hueDistance(5, 355), 10);
    expect(hueDistance(90, 270), 180);
    expect(hueDistance(10, 40), 30);
  });

  group('sampleHoldColor', () {
    test('reads a red hold at its center', () {
      final frame = _mixedWall().frame;
      final color = sampleHoldColor(frame, _nx(60), _ny(50))!;
      expect(color.achromatic, isFalse);
      expect(hueDistance(color.hue, 0), lessThan(5));
      expect(color.name, 'red');
    });

    test('reads a hold that only covers part of the disc', () {
      final wall = SyntheticWall(_w, _h)..disc(100, 100, 5, wallBlue);
      final color = sampleHoldColor(wall.frame, _nx(103), _ny(102))!;
      expect(color.name, 'blue');
    });

    test('handles hues on both sides of 0°', () {
      final wall = SyntheticWall(_w, _h)..disc(100, 100, 8, (230, 30, 50));
      final color = sampleHoldColor(wall.frame, _nx(100), _ny(100))!;
      expect(hueDistance(color.hue, 354), lessThan(3));
      // A pixel at 4.5° is the same color.
      final other = rgbToHsv(230, 45, 30);
      expect(
        color.matches(other.h, other.s, other.v, const ColorTolerance()),
        isTrue,
      );
    });

    test('reads white holds as achromatic', () {
      final wall = SyntheticWall(_w, _h)..disc(100, 100, 9, wallWhite);
      final color = sampleHoldColor(wall.frame, _nx(100), _ny(100))!;
      expect(color.achromatic, isTrue);
      expect(color.value, greaterThan(0.85));
      expect(color.name, 'white');
    });

    test('returns null for a patch with no coherent color', () {
      final wall = SyntheticWall(_w, _h);
      // Every pixel a different saturated hue.
      for (var y = 80; y < 120; y++) {
        for (var x = 80; x < 120; x++) {
          final hue = ((x * 37 + y * 101) % 360).toDouble();
          wall.set(x, y, saturatedHue(hue));
        }
      }
      expect(sampleHoldColor(wall.frame, _nx(100), _ny(100)), isNull);
    });
  });

  group('segmentHolds', () {
    test('finds exactly the holds of the sampled color', () {
      final frame = _mixedWall().frame;
      final color = sampleHoldColor(frame, _nx(60), _ny(50))!;
      final holds = segmentHolds(frame, color);
      expect(holds, hasLength(_redHolds.length));
      // Sorted top to bottom, centroids on the painted discs.
      final expected = [..._redHolds]..sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < holds.length; i++) {
        expect(holds[i].centerX, closeTo(_nx(expected[i].$1), 0.01));
        expect(holds[i].centerY, closeTo(_ny(expected[i].$2), 0.01));
        expect(holds[i].contains(_nx(expected[i].$1), _ny(expected[i].$2)),
            isTrue);
      }
    });

    test('finds holds on both sides of 0° hue', () {
      final wall = SyntheticWall(_w, _h)
        ..disc(60, 60, 8, (230, 30, 50)) // ~354°
        ..disc(200, 200, 8, (230, 45, 30)); // ~4.5°
      final frame = wall.frame;
      final color = sampleHoldColor(frame, _nx(60), _ny(60))!;
      expect(segmentHolds(frame, color), hasLength(2));
    });

    test('rejects wall panels and streaks of the same color', () {
      final wall = _mixedWall()
        // Big red panel: ~9% of the frame.
        ..rect(150, 180, 270, 280, wallRed)
        // Thin diagonal red streak (tape).
        ..diagonal(100, 240, 150, 4, wallRed);
      final frame = wall.frame;
      final color = sampleHoldColor(frame, _nx(60), _ny(50))!;
      final holds = segmentHolds(frame, color);
      // The hold inside the panel merges into it and is lost with it.
      expect(holds, hasLength(_redHolds.length - 1));
      for (final hold in holds) {
        expect(hold.areaFraction, lessThan(0.05));
        expect(hold.fillRatio, greaterThanOrEqualTo(0.2));
      }
    });

    test('ignores single-pixel speckle of the target color', () {
      final wall = SyntheticWall(_w, _h);
      for (var y = 0; y < _h; y += 7) {
        for (var x = 0; x < _w; x += 7) {
          wall.set(x, y, wallRed);
        }
      }
      const color = HoldColor(hue: 0, saturation: 0.8, value: 0.86);
      expect(segmentHolds(wall.frame, color), isEmpty);
    });

    test('finds white holds without picking up the gray wall', () {
      final wall = SyntheticWall(_w, _h)
        ..disc(70, 70, 9, wallWhite)
        ..disc(220, 150, 9, wallWhite)
        ..disc(120, 300, 9, wallWhite);
      final frame = wall.frame;
      final color = sampleHoldColor(frame, _nx(70), _ny(70))!;
      expect(color.achromatic, isTrue);
      expect(segmentHolds(frame, color), hasLength(3));
    });

    test('finds nothing when sampling bare wall', () {
      final frame = _mixedWall().frame;
      final color = sampleHoldColor(frame, _nx(160), _ny(220))!;
      // Gray wall reads as achromatic gray: one huge blob, rejected.
      expect(color.achromatic, isTrue);
      expect(segmentHolds(frame, color), isEmpty);
    });

    test('is fast enough to run on a phone', () {
      final frame = _mixedWall().frame;
      final big = WallFrame(
        320,
        568,
        Uint8List(320 * 568 * 3)..setRange(0, frame.rgb.length, frame.rgb),
      );
      const color = HoldColor(hue: 0, saturation: 0.8, value: 0.86);
      final watch = Stopwatch()..start();
      segmentHolds(big, color);
      watch.stop();
      // ignore: avoid_print
      print('segmentHolds 320x568: ${watch.elapsedMilliseconds} ms');
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('morphology', () {
    test('open removes isolated pixels but keeps a 3x3 block', () {
      const w = 7, h = 7;
      final mask = Uint8List(w * h);
      mask[0 * w + 6] = 1; // lone pixel
      for (var y = 2; y < 5; y++) {
        for (var x = 2; x < 5; x++) {
          mask[y * w + x] = 1;
        }
      }
      final opened = dilate(erode(mask, w, h), w, h);
      expect(opened[0 * w + 6], 0);
      expect(opened[3 * w + 3], 1);
      expect(opened.where((v) => v == 1).length, 9);
    });
  });

  test('HoldColor.name covers the wheel', () {
    String name(double hue) =>
        HoldColor(hue: hue, saturation: 1, value: 1).name;
    expect(name(0), 'red');
    expect(name(350), 'red');
    expect(name(25), 'orange');
    expect(name(55), 'yellow');
    expect(name(120), 'green');
    expect(name(175), 'teal');
    expect(name(220), 'blue');
    expect(name(270), 'purple');
    expect(name(320), 'pink');
    expect(
      const HoldColor(hue: 0, saturation: 0, value: 0.1, achromatic: true).name,
      'black',
    );
  });
}
