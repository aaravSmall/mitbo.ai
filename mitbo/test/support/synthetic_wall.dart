import 'dart:typed_data';

import 'package:mitbo/vision/wall_frame.dart';

typedef Rgb = (int, int, int);

const wallRed = (220, 40, 40);
const wallBlue = (40, 60, 220);
const wallYellow = (230, 210, 40);
const wallWhite = (235, 235, 235);

/// Deterministic per-pixel noise in [-10, 10].
int _noise(int x, int y) => ((x * 73856093) ^ (y * 19349663)) % 21 - 10;

/// A synthetic test wall: noisy mid-gray, with holds painted on.
class SyntheticWall {
  SyntheticWall(this.width, this.height) : rgb = Uint8List(width * height * 3) {
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

  void set(int x, int y, Rgb c) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    final i = (y * width + x) * 3;
    rgb[i] = c.$1;
    rgb[i + 1] = c.$2;
    rgb[i + 2] = c.$3;
  }

  void disc(int cx, int cy, int r, Rgb c) {
    for (var y = cy - r; y <= cy + r; y++) {
      for (var x = cx - r; x <= cx + r; x++) {
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r) set(x, y, c);
      }
    }
  }

  void rect(int x0, int y0, int x1, int y1, Rgb c) {
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        set(x, y, c);
      }
    }
  }

  /// A 45° streak, [thickness] pixels across, from ([x0], [y0]).
  void diagonal(int x0, int y0, int length, int thickness, Rgb c) {
    for (var i = 0; i < length; i++) {
      for (var t = 0; t < thickness; t++) {
        set(x0 + i + t, y0 + i, c);
      }
    }
  }

  WallFrame get frame => WallFrame(width, height, rgb);
}


/// A fully saturated color of [hue] degrees (value 220/255).
Rgb saturatedHue(double hue) {
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
