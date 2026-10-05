import 'dart:math' as math;
import 'dart:ui';

import '../vision/hold_color.dart';
import '../vision/hold_segmenter.dart';
import '../vision/problem_detector.dart';
import 'hold.dart';
import 'problem.dart';

// Conversions between the detection pipeline's types (boxes, HSV colors)
// and the editable circle-based [Hold]/[Problem] used for marking.
//
// Both use normalized upright coordinates, so only the frame's aspect ratio
// matters, not its resolution: a hold's radius is a fraction of the frame's
// shorter side, while box edges are fractions of each axis.

/// A circle around a detected hold: centered on its centroid, with a
/// radius that covers the larger side of its box.
Hold holdFromDetected(
  DetectedHold detected, {
  required String id,
  required Size frameSize,
  HoldSource source = HoldSource.auto,
  Color? color,
}) {
  final widthPx = detected.width * frameSize.width;
  final heightPx = detected.height * frameSize.height;
  return Hold(
    id: id,
    center: Offset(detected.centerX, detected.centerY),
    radius: math.max(widthPx, heightPx) / 2 / frameSize.shortestSide,
    source: source,
    color: color,
  );
}

/// The box (and area estimates) of a circular [hold], for the beta engine.
DetectedHold detectedFromHold(Hold hold, Size frameSize) {
  final radiusPx = hold.radius * frameSize.shortestSide;
  final halfWidth = radiusPx / frameSize.width;
  final halfHeight = radiusPx / frameSize.height;
  final areaPx = math.pi * radiusPx * radiusPx;
  return DetectedHold(
    left: (hold.center.dx - halfWidth).clamp(0.0, 1.0),
    top: (hold.center.dy - halfHeight).clamp(0.0, 1.0),
    right: (hold.center.dx + halfWidth).clamp(0.0, 1.0),
    bottom: (hold.center.dy + halfHeight).clamp(0.0, 1.0),
    centerX: hold.center.dx,
    centerY: hold.center.dy,
    pixelArea: areaPx.round(),
    areaFraction: areaPx / (frameSize.width * frameSize.height),
    fillRatio: math.pi / 4,
  );
}

/// The detected [problem] as editable holds, ids `auto-0`, `auto-1`, …
/// in the problem's (top-to-bottom) order.
Problem problemFromDetected(DetectedProblem problem, Size frameSize) {
  final color = colorFromHoldColor(problem.color);
  return Problem(
    holds: [
      for (var i = 0; i < problem.holds.length; i++)
        holdFromDetected(
          problem.holds[i],
          id: 'auto-$i',
          frameSize: frameSize,
          color: color,
        ),
    ],
    color: color,
    frameSize: frameSize,
  );
}

/// The [HoldColor] a display [color] corresponds to; achromatic when it's
/// too unsaturated (or dark) to have a reliable hue.
HoldColor holdColorFromColor(
  Color color, {
  ColorTolerance tolerance = const ColorTolerance(),
}) {
  final argb = color.toARGB32();
  final hsv = rgbToHsv((argb >> 16) & 0xff, (argb >> 8) & 0xff, argb & 0xff);
  return HoldColor(
    hue: hsv.h,
    saturation: hsv.s,
    value: hsv.v,
    achromatic: hsv.s < tolerance.minSaturation || hsv.v < tolerance.minValue,
  );
}

/// A display color for [color].
Color colorFromHoldColor(HoldColor color) {
  final s = color.achromatic ? 0.0 : color.saturation;
  final v = color.value;
  final c = v * s;
  final h = (color.hue % 360) / 60;
  final x = c * (1 - ((h % 2) - 1).abs());
  final (r, g, b) = switch (h.floor()) {
    0 => (c, x, 0.0),
    1 => (x, c, 0.0),
    2 => (0.0, c, x),
    3 => (0.0, x, c),
    4 => (x, 0.0, c),
    _ => (c, 0.0, x),
  };
  final m = v - c;
  int channel(double value) => ((value + m) * 255).round().clamp(0, 255);
  return Color.fromARGB(255, channel(r), channel(g), channel(b));
}
