import 'dart:math' as math;

import 'wall_frame.dart';

/// Hue in degrees [0, 360), saturation and value in [0, 1].
typedef Hsv = ({double h, double s, double v});

/// Converts 8-bit RGB to HSV.
Hsv rgbToHsv(int r, int g, int b) {
  final max = math.max(r, math.max(g, b));
  final min = math.min(r, math.min(g, b));
  final delta = max - min;
  final v = max / 255;
  final s = max == 0 ? 0.0 : delta / max;
  double h;
  if (delta == 0) {
    h = 0;
  } else if (max == r) {
    // Dart's % is always non-negative, so this wraps negatives correctly.
    h = 60 * (((g - b) / delta) % 6);
  } else if (max == g) {
    h = 60 * ((b - r) / delta + 2);
  } else {
    h = 60 * ((r - g) / delta + 4);
  }
  return (h: h, s: s, v: v);
}

/// Shortest distance between two hues around the color wheel, 0–180.
double hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

/// How close a pixel has to be to a [HoldColor] to count as that color.
class ColorTolerance {
  const ColorTolerance({
    this.hueTolerance = 18,
    this.minSaturation = 0.25,
    this.minValue = 0.15,
    this.valueTolerance = 0.2,
  });

  /// Max hue distance, in degrees, for chromatic colors.
  final double hueTolerance;

  /// Below this saturation a pixel has no reliable hue: chromatic colors
  /// ignore it, achromatic colors (white/gray/black) require it.
  final double minSaturation;

  /// Chromatic pixels darker than this are ignored (hue is noise there).
  final double minValue;

  /// Max brightness difference for achromatic colors.
  final double valueTolerance;

  ColorTolerance copyWith({double? hueTolerance, double? minSaturation}) =>
      ColorTolerance(
        hueTolerance: hueTolerance ?? this.hueTolerance,
        minSaturation: minSaturation ?? this.minSaturation,
        minValue: minValue,
        valueTolerance: valueTolerance,
      );
}

/// The color of a problem's holds.
class HoldColor {
  const HoldColor({
    required this.hue,
    required this.saturation,
    required this.value,
    this.achromatic = false,
    this.confidence = 1,
  });

  /// A placeholder for holds whose color was never read (e.g. marked by
  /// hand without picking a color). Named generically rather than "gray".
  static const unknown = HoldColor(
    hue: 0,
    saturation: 0,
    value: 0.5,
    achromatic: true,
    confidence: 0,
  );

  /// Degrees, [0, 360). Meaningless when [achromatic].
  final double hue;
  final double saturation;
  final double value;

  /// White, gray or black: matched by brightness instead of hue.
  final bool achromatic;

  /// How much of the sampled area agreed on this color, 0–1.
  final double confidence;

  /// Whether a pixel with this HSV counts as this color.
  bool matches(double h, double s, double v, ColorTolerance tolerance) {
    if (achromatic) {
      return s < tolerance.minSaturation &&
          (v - value).abs() <= tolerance.valueTolerance;
    }
    return s >= tolerance.minSaturation &&
        v >= tolerance.minValue &&
        hueDistance(h, hue) <= tolerance.hueTolerance;
  }

  /// Rough everyday name for the color, for UI ("Red problem").
  String get name {
    if (achromatic) {
      if (value >= 0.75) return 'white';
      if (value <= 0.25) return 'black';
      return 'gray';
    }
    final h = hue;
    if (h < 15 || h >= 345) return 'red';
    if (h < 40) return 'orange';
    if (h < 70) return 'yellow';
    if (h < 160) return 'green';
    if (h < 190) return 'teal';
    if (h < 250) return 'blue';
    if (h < 290) return 'purple';
    return 'pink';
  }

  @override
  String toString() => achromatic
      ? 'HoldColor($name, v: ${value.toStringAsFixed(2)})'
      : 'HoldColor($name, h: ${hue.toStringAsFixed(0)}, '
            's: ${saturation.toStringAsFixed(2)}, '
            'v: ${value.toStringAsFixed(2)})';
}

const _hueBins = 36;

/// Reads the dominant hold color in a disc of [radius] (a fraction of the
/// frame width) around normalized point ([nx], [ny]).
///
/// Pixels nearer the center count more. Saturated pixels vote on hue; if
/// enough of the disc agrees on one hue (at least [minShare] of the
/// weight), that's the color. Otherwise, if the disc is mostly unsaturated,
/// the result is an achromatic color from the dominant brightness. Returns
/// null if there's no coherent color.
HoldColor? sampleHoldColor(
  WallFrame frame,
  double nx,
  double ny, {
  double radius = 0.03,
  double minShare = 0.12,
  ColorTolerance tolerance = const ColorTolerance(),
}) {
  final cx = frame.columnAt(nx);
  final cy = frame.rowAt(ny);
  final r = math.max(1, (radius * frame.width).round());

  final binWeight = List<double>.filled(_hueBins, 0);
  final binCos = List<double>.filled(_hueBins, 0);
  final binSin = List<double>.filled(_hueBins, 0);
  final binSat = List<double>.filled(_hueBins, 0);
  final binVal = List<double>.filled(_hueBins, 0);
  const valueBins = 10;
  final grayWeight = List<double>.filled(valueBins, 0);
  final grayVal = List<double>.filled(valueBins, 0);
  var total = 0.0;
  var unsaturated = 0.0;

  for (
    var y = math.max(0, cy - r);
    y <= math.min(frame.height - 1, cy + r);
    y++
  ) {
    for (
      var x = math.max(0, cx - r);
      x <= math.min(frame.width - 1, cx + r);
      x++
    ) {
      final dx = x - cx;
      final dy = y - cy;
      final d = math.sqrt(dx * dx + dy * dy);
      if (d > r) continue;
      final w = 1 - d / (r + 1);
      total += w;
      final (pr, pg, pb) = frame.pixel(x, y);
      final hsv = rgbToHsv(pr, pg, pb);
      if (hsv.s < tolerance.minSaturation) {
        unsaturated += w;
        final bin = math.min(valueBins - 1, (hsv.v * valueBins).floor());
        grayWeight[bin] += w;
        grayVal[bin] += w * hsv.v;
        continue;
      }
      if (hsv.v < tolerance.minValue) continue;
      final bin = (hsv.h / (360 / _hueBins)).floor() % _hueBins;
      final rad = hsv.h * math.pi / 180;
      binWeight[bin] += w;
      binCos[bin] += w * math.cos(rad);
      binSin[bin] += w * math.sin(rad);
      binSat[bin] += w * hsv.s;
      binVal[bin] += w * hsv.v;
    }
  }
  if (total == 0) return null;

  // Best window of three adjacent hue bins, so a color straddling a bin
  // edge isn't split in two.
  var best = -1;
  var bestWeight = 0.0;
  for (var i = 0; i < _hueBins; i++) {
    final weight =
        binWeight[(i + _hueBins - 1) % _hueBins] +
        binWeight[i] +
        binWeight[(i + 1) % _hueBins];
    if (weight > bestWeight) {
      bestWeight = weight;
      best = i;
    }
  }

  if (best >= 0 && bestWeight / total >= minShare) {
    var c = 0.0, s = 0.0, sat = 0.0, val = 0.0;
    for (final i in [
      (best + _hueBins - 1) % _hueBins,
      best,
      (best + 1) % _hueBins,
    ]) {
      c += binCos[i];
      s += binSin[i];
      sat += binSat[i];
      val += binVal[i];
    }
    final hue = (math.atan2(s, c) * 180 / math.pi + 360) % 360;
    return HoldColor(
      hue: hue,
      saturation: sat / bestWeight,
      value: val / bestWeight,
      confidence: (bestWeight / total).clamp(0.0, 1.0),
    );
  }

  if (unsaturated / total < 0.5) return null;
  var bestGray = 0;
  for (var i = 1; i < valueBins; i++) {
    if (grayWeight[i] > grayWeight[bestGray]) bestGray = i;
  }
  // Include the neighbouring brightness bins, like the hue window.
  var weight = 0.0, val = 0.0;
  for (var i = bestGray - 1; i <= bestGray + 1; i++) {
    if (i < 0 || i >= valueBins) continue;
    weight += grayWeight[i];
    val += grayVal[i];
  }
  if (weight / total < minShare) return null;
  return HoldColor(
    hue: 0,
    saturation: 0,
    value: val / weight,
    achromatic: true,
    confidence: (weight / total).clamp(0.0, 1.0),
  );
}
