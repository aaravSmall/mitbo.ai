import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/vision/wall_frame.dart';

typedef _Rgb = (int, int, int);
typedef _ColorAt = _Rgb Function(int x, int y);

int _byte(double v) => v.round().clamp(0, 255);

/// Encodes an image as NV21 (BT.601 full range), with optional row padding
/// filled with [padByte]. Chroma for each 2x2 block comes from its
/// top-left pixel.
Uint8List _nv21(int w, int h, _ColorAt color, {int? stride, int padByte = 0}) {
  final s = stride ?? w;
  final bytes = Uint8List(s * h + s * ((h + 1) ~/ 2))
    ..fillRange(0, s * h + s * ((h + 1) ~/ 2), padByte);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b) = color(x, y);
      bytes[y * s + x] = _byte(0.299 * r + 0.587 * g + 0.114 * b);
    }
  }
  for (var y = 0; y < h; y += 2) {
    for (var x = 0; x < w; x += 2) {
      final (r, g, b) = color(x, y);
      final i = s * h + (y >> 1) * s + x;
      bytes[i] = _byte(0.5 * r - 0.418688 * g - 0.081312 * b + 128);
      bytes[i + 1] = _byte(-0.168736 * r - 0.331264 * g + 0.5 * b + 128);
    }
  }
  return bytes;
}

Uint8List _bgra(int w, int h, _ColorAt color, {int? stride}) {
  final s = stride ?? w * 4;
  final bytes = Uint8List(s * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b) = color(x, y);
      final i = y * s + x * 4;
      bytes[i] = b;
      bytes[i + 1] = g;
      bytes[i + 2] = r;
      bytes[i + 3] = 255;
    }
  }
  return bytes;
}

void _expectColor(_Rgb actual, _Rgb expected, {int tolerance = 6}) {
  final (r, g, b) = actual;
  final (er, eg, eb) = expected;
  expect(
    (r - er).abs() <= tolerance &&
        (g - eg).abs() <= tolerance &&
        (b - eb).abs() <= tolerance,
    isTrue,
    reason: 'expected ~$expected, got $actual',
  );
}

bool _isRed(_Rgb c) => c.$1 > 200 && c.$3 < 60;
bool _isBlue(_Rgb c) => c.$3 > 200 && c.$1 < 60;

void main() {
  group('wallFrameFromNv21', () {
    for (final color in const [
      (255, 0, 0),
      (0, 255, 0),
      (0, 0, 255),
      (255, 255, 255),
      (0, 0, 0),
      (200, 120, 40),
    ]) {
      test('round-trips solid $color', () {
        final bytes = _nv21(8, 4, (_, _) => color);
        final frame = wallFrameFromNv21(bytes, 8, 4, 8, 0);
        expect(frame.width, 8);
        expect(frame.height, 4);
        for (var y = 0; y < frame.height; y++) {
          for (var x = 0; x < frame.width; x++) {
            _expectColor(frame.pixel(x, y), color);
          }
        }
      });
    }

    // A red 2x2 square in the raw top-left corner of an 8x4 blue frame.
    _Rgb squareInTopLeft(int x, int y) =>
        x < 2 && y < 2 ? (255, 0, 0) : (0, 0, 255);

    final expectations = {
      // rotation: (upright width, upright height, red corner, blue corner)
      0: (8, 4, (0, 0), (7, 3)),
      90: (4, 8, (3, 0), (0, 7)),
      180: (8, 4, (7, 3), (0, 0)),
      270: (4, 8, (0, 7), (3, 0)),
    };
    for (final MapEntry(key: rotation, value: e) in expectations.entries) {
      final (w, h, red, blue) = e;
      test('rotates $rotation° clockwise to upright', () {
        final bytes = _nv21(8, 4, squareInTopLeft);
        final frame = wallFrameFromNv21(bytes, 8, 4, 8, rotation);
        expect((frame.width, frame.height), (w, h));
        expect(_isRed(frame.pixel(red.$1, red.$2)), isTrue);
        expect(_isBlue(frame.pixel(blue.$1, blue.$2)), isTrue);
        // Exactly the 2x2 square is red.
        var redCount = 0;
        for (var y = 0; y < h; y++) {
          for (var x = 0; x < w; x++) {
            if (_isRed(frame.pixel(x, y))) redCount++;
          }
        }
        expect(redCount, 4);
      });
    }

    test('downsamples to the target width of the upright image', () {
      final bytes = _nv21(640, 480, (_, _) => (90, 90, 90));
      final landscape = wallFrameFromNv21(bytes, 640, 480, 640, 0);
      expect((landscape.width, landscape.height), (320, 240));
      final portrait = wallFrameFromNv21(bytes, 640, 480, 640, 90);
      expect((portrait.width, portrait.height), (320, 427));
    });

    test('never upscales', () {
      final bytes = _nv21(8, 4, (_, _) => (90, 90, 90));
      final frame = wallFrameFromNv21(bytes, 8, 4, 8, 0, targetWidth: 100);
      expect((frame.width, frame.height), (8, 4));
    });

    test('skips row padding', () {
      final bytes = _nv21(
        8,
        4,
        (_, _) => (128, 128, 128),
        stride: 12,
        padByte: 0,
      );
      final frame = wallFrameFromNv21(bytes, 8, 4, 12, 0);
      for (var y = 0; y < frame.height; y++) {
        for (var x = 0; x < frame.width; x++) {
          _expectColor(frame.pixel(x, y), (128, 128, 128));
        }
      }
    });

    test('reads a short buffer as gray instead of throwing', () {
      final frame = wallFrameFromNv21(Uint8List(4), 8, 4, 8, 0);
      expect(frame.width, 8);
    });
  });

  group('wallFrameFromBgra', () {
    test('keeps channel order', () {
      final bytes = _bgra(4, 2, (_, _) => (10, 20, 30));
      final frame = wallFrameFromBgra(bytes, 4, 2, 16, 0);
      expect(frame.pixel(0, 0), (10, 20, 30));
      expect(frame.pixel(3, 1), (10, 20, 30));
    });

    test('rotates and skips row padding', () {
      final bytes = _bgra(
        8,
        4,
        (x, y) => x < 2 && y < 2 ? (255, 0, 0) : (0, 0, 255),
        stride: 40,
      );
      final frame = wallFrameFromBgra(bytes, 8, 4, 40, 90);
      expect((frame.width, frame.height), (4, 8));
      expect(frame.pixel(3, 0), (255, 0, 0));
      expect(frame.pixel(0, 7), (0, 0, 255));
    });
  });

  group('WallFrame', () {
    test('samples normalized coordinates, clamped to the frame', () {
      final rgb = Uint8List(4 * 2 * 3);
      // Mark the bottom-right pixel.
      rgb.setAll((1 * 4 + 3) * 3, [1, 2, 3]);
      final frame = WallFrame(4, 2, rgb);
      expect(frame.sampleNormalized(0.99, 0.99), (1, 2, 3));
      expect(frame.sampleNormalized(1.5, 2), (1, 2, 3));
      expect(frame.sampleNormalized(-1, -1), (0, 0, 0));
      expect(frame.columnAt(0.5), 2);
      expect(frame.rowAt(0.5), 1);
    });
  });

  group('rawPixelFor', () {
    test('inverts each clockwise rotation', () {
      // Rotating raw (x, y) clockwise by 90° in an 8x4 image lands on
      // upright (4 - 1 - y, x).
      expect(rawPixelFor(3, 0, 8, 4, 90), (0, 0));
      expect(rawPixelFor(0, 7, 8, 4, 90), (7, 3));
      expect(rawPixelFor(0, 0, 8, 4, 180), (7, 3));
      expect(rawPixelFor(0, 7, 8, 4, 270), (0, 0));
      expect(rawPixelFor(2, 1, 8, 4, 0), (2, 1));
    });
  });

  test('RawFrame.toWallFrame dispatches on format', () {
    final raw = RawFrame(
      format: RawFrameFormat.bgra8888,
      bytes: _bgra(4, 2, (_, _) => (7, 8, 9)),
      width: 4,
      height: 2,
      bytesPerRow: 16,
      rotationDegrees: 0,
    );
    expect(raw.toWallFrame().pixel(0, 0), (7, 8, 9));
  });
}
