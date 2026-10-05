import 'dart:math' as math;
import 'dart:ui';

import '../vision/wall_frame.dart';
import 'hold.dart';

/// Hold radius in upright frame pixels.
double holdRadiusPixels(double radius, Size frameSize) =>
    radius * frameSize.shortestSide;

/// The hold a tap at [tap] (normalized) selects, or null for empty space.
///
/// A tap counts when it lands within a hold's circle or [slop] of its edge
/// ([slop] is in the same shorter-side units as [Hold.radius]). Where holds
/// overlap, the one whose center is closest relative to its size wins, so a
/// small hold drawn inside a big one can still be selected.
Hold? hitTestHolds(
  List<Hold> holds,
  Offset tap, {
  required Size frameSize,
  double slop = 0.015,
}) {
  final side = frameSize.shortestSide;
  Hold? best;
  var bestScore = double.infinity;
  for (final hold in holds) {
    final dx = (tap.dx - hold.center.dx) * frameSize.width;
    final dy = (tap.dy - hold.center.dy) * frameSize.height;
    final distance = math.sqrt(dx * dx + dy * dy);
    final radius = hold.radius * side;
    if (distance > radius + slop * side) continue;
    final score = distance / radius;
    if (score < bestScore) {
      best = hold;
      bestScore = score;
    }
  }
  return best;
}

/// Average color of the pixels inside a circle at [center] (normalized)
/// with [radius] (shorter-side units), or null if it covers no pixels.
Color? averageColorInCircle(WallFrame frame, Offset center, double radius) {
  final cx = center.dx * frame.width;
  final cy = center.dy * frame.height;
  final r = radius * math.min(frame.width, frame.height);
  final minX = math.max(0, (cx - r).floor());
  final maxX = math.min(frame.width - 1, (cx + r).ceil());
  final minY = math.max(0, (cy - r).floor());
  final maxY = math.min(frame.height - 1, (cy + r).ceil());

  var red = 0, green = 0, blue = 0, count = 0;
  for (var y = minY; y <= maxY; y++) {
    for (var x = minX; x <= maxX; x++) {
      // Sample at pixel centers.
      final dx = x + 0.5 - cx;
      final dy = y + 0.5 - cy;
      if (dx * dx + dy * dy > r * r) continue;
      final i = (y * frame.width + x) * 3;
      red += frame.rgb[i];
      green += frame.rgb[i + 1];
      blue += frame.rgb[i + 2];
      count++;
    }
  }
  if (count == 0) return null;
  return Color.fromARGB(
    255,
    (red / count).round(),
    (green / count).round(),
    (blue / count).round(),
  );
}
