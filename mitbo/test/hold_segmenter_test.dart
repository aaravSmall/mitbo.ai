import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/wall_frame.dart';

typedef _Rgb = (int, int, int);

const _red = (220, 40, 40);
const _blue = (40, 60, 220);
const _yellow = (230, 210, 40);
const _white = (235, 235, 235);

/// Deterministic per-pixel noise in [-10, 10].
int _noise(int x, int y) => ((x * 73856093) ^ (y * 19349663)) % 21 - 10;

/// A synthetic wall: noisy mid-gray, painted on with [paint].
class _Wall {
  _Wall(this.width, this.height) : rgb = Uint8List(width * height * 3) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final g = 128 + _noise(x, y);
        set(x, y, (g, g, g));
      }
    }
  }

  final int width;
  final int height;
  final Uint8List rgb;

  void set(int x, int y, _Rgb c) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = (y * width + x) * 3;
    rgb[i] = c.$1;
    rgb[i + 1] = c.$2;
    rgb[i + 2] = c.$3;
  }

  void disc(int cx, int cy, int r, _Rgb c) {
    for (var y = cy - r; y <= cy + r; y++) {
      for (var x = cx - r; x <= cx + r; x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) set(x, y, c);
      }
    }
  }

  void rect(int x0, int y0, int x1, int y1, _Rgb c) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        set(x, y, c);
      }
    }
  }

  /// A 45° streak, [thickness] pixels across, from ([x0], [y0]).
  void diagonal(int x0, int y0, int length, int thickness, _Rgb c) {
    for (var i = 0; i < length; i++) {
      for (var t = 0; t < thickness; t++) {
        set(x0 + i + t, y0 + i, c);
      }
    }
  }

  WallFrame get frame => WallFrame(width, height, rgb);
}

const _w = 320;
const _h = 400;

/// Red hold centers, in pixels.
const _redHolds = [(60, 50), (200, 90), (110, 170), (250, 260), (80, 340)];

_Wall _mixedWall() {
  final wall = _Wall(_w, _h);
  for (final (x, y) in _redHolds) {
    wall.disc(x, y, 8, _red);
  }
  wall
    ..disc(150, 40, 8, _blue)
    ..disc(40, 220, 9, _blue)
    ..disc(280, 150, 7, _yellow)
    ..disc(180, 330, 10, _yellow);
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
      final wall = _Wall(_w, _h)..disc(100, 100, 5, _blue);
      final color = sampleHoldColor(wall.frame, _nx(103), _ny(102))!;
      expect(color.name, 'blue');
    });

    test('handles hues on both sides of 0°', () {
      final wall = _Wall(_w, _h)..disc(100, 100, 8, (230, 30, 50));
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
      final wall = _Wall(_w, _h)..disc(100, 100, 9, _white);
      final color = sampleHoldColor(wall.frame, _nx(100), _ny(100))!;
      expect(color.achromatic, isTrue);
      expect(color.value, greaterThan(0.85));
      expect(color.name, 'white');
    });

    test('returns null for a patch with no coherent color', () {
      final wall = _Wall(_w, _h);
      // Every pixel a different saturated hue.
      for (var y = 80; y < 120; y++) {
        for (var x = 80; x < 120; x++) {
          final hue = ((x * 37 + y * 101) % 360).toDouble();
          wall.set(x, y, _hsvToRgb(hue));
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
      final wall = _Wall(_w, _h)
        ..disc(60, 60, 8, (230, 30, 50)) // ~354°
        ..disc(200, 200, 8, (230, 45, 30)); // ~4.5°
      final frame = wall.frame;
      final color = sampleHoldColor(frame, _nx(60), _ny(60))!;
      expect(segmentHolds(frame, color), hasLength(2));
    });

    test('rejects wall panels and streaks of the same color', () {
      final wall = _mixedWall()
        // Big red panel: ~9% of the frame.
        ..rect(150, 180, 270, 280, _red)
        // Thin diagonal red streak (tape).
        ..diagonal(100, 240, 150, 4, _red);
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
      final wall = _Wall(_w, _h);
      for (var y = 0; y < _h; y += 7) {
        for (var x = 0; x < _w; x += 7) {
          wall.set(x, y, _red);
        }
      }
      const color = HoldColor(hue: 0, saturation: 0.8, value: 0.86);
      expect(segmentHolds(wall.frame, color), isEmpty);
    });

    test('finds white holds without picking up the gray wall', () {
      final wall = _Wall(_w, _h)
        ..disc(70, 70, 9, _white)
        ..disc(220, 150, 9, _white)
        ..disc(120, 300, 9, _white);
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

_Rgb _hsvToRgb(double hue) {
  const c = 1.0;
  final x = c * (1 - ((hue / 60) % 2 - 1).abs());
  final (r, g, b) = switch (hue ~/ 60) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  int byte(double v) => (v * 220).round();
  return (byte(r), byte(g), byte(b));
}
