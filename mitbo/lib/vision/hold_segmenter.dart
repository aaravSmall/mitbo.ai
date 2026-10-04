import 'dart:typed_data';

import 'hold_color.dart';
import 'wall_frame.dart';

/// One hold found by [segmentHolds], in normalized upright coordinates.
class DetectedHold {
  const DetectedHold({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.centerX,
    required this.centerY,
    required this.pixelArea,
    required this.areaFraction,
    required this.fillRatio,
  });

  /// Bounding box, 0–1 (right/bottom are exclusive edges).
  final double left;
  final double top;
  final double right;
  final double bottom;

  /// Centroid of the hold's pixels, 0–1.
  final double centerX;
  final double centerY;

  /// Pixels in the hold, at the [WallFrame]'s resolution.
  final int pixelArea;

  /// [pixelArea] as a fraction of the whole frame.
  final double areaFraction;

  /// [pixelArea] divided by the bounding box area, 0–1.
  final double fillRatio;

  double get width => right - left;
  double get height => bottom - top;

  /// Squared distance from the centroid to normalized point ([x], [y]).
  double distanceSquaredTo(double x, double y) {
    final dx = centerX - x;
    final dy = centerY - y;
    return dx * dx + dy * dy;
  }

  /// Whether normalized point ([x], [y]) is inside the bounding box,
  /// grown by [margin] on every side.
  bool contains(double x, double y, {double margin = 0}) =>
      x >= left - margin &&
      x <= right + margin &&
      y >= top - margin &&
      y <= bottom + margin;

  @override
  String toString() =>
      'DetectedHold(center: (${centerX.toStringAsFixed(3)}, '
      '${centerY.toStringAsFixed(3)}), area: $pixelArea)';
}

/// Tunable thresholds for [segmentHolds].
class SegmentationParams {
  const SegmentationParams({
    this.tolerance = const ColorTolerance(),
    this.minAreaFraction = 0.0002,
    this.maxAreaFraction = 0.05,
    this.minFillRatio = 0.2,
    this.maxAspectRatio = 8,
    this.cleanUp = true,
  });

  final ColorTolerance tolerance;

  /// Blobs smaller than this fraction of the frame are noise.
  final double minAreaFraction;

  /// Blobs larger than this are wall panels or volumes, not holds.
  final double maxAreaFraction;

  /// Blobs filling less of their bounding box than this are streaks
  /// (tape, wall edges, shadows), not holds.
  final double minFillRatio;

  /// Blobs longer than this many times their width are streaks too.
  final double maxAspectRatio;

  /// Apply a 3x3 open (removes speckle) then close (fills chalk/texture
  /// gaps) to the mask before finding blobs.
  final bool cleanUp;

  SegmentationParams copyWith({ColorTolerance? tolerance}) =>
      SegmentationParams(
        tolerance: tolerance ?? this.tolerance,
        minAreaFraction: minAreaFraction,
        maxAreaFraction: maxAreaFraction,
        minFillRatio: minFillRatio,
        maxAspectRatio: maxAspectRatio,
        cleanUp: cleanUp,
      );
}

/// 1 where [frame]'s pixel matches [color], 0 elsewhere (row-major).
Uint8List buildColorMask(
  WallFrame frame,
  HoldColor color, {
  ColorTolerance tolerance = const ColorTolerance(),
}) {
  final mask = Uint8List(frame.width * frame.height);
  final rgb = frame.rgb;
  for (var i = 0, p = 0; i < mask.length; i++, p += 3) {
    final hsv = rgbToHsv(rgb[p], rgb[p + 1], rgb[p + 2]);
    if (color.matches(hsv.h, hsv.s, hsv.v, tolerance)) mask[i] = 1;
  }
  return mask;
}

/// Finds every hold of [color] in [frame], sorted top to bottom.
List<DetectedHold> segmentHolds(
  WallFrame frame,
  HoldColor color, {
  SegmentationParams params = const SegmentationParams(),
}) {
  final w = frame.width;
  final h = frame.height;
  var mask = buildColorMask(frame, color, tolerance: params.tolerance);
  if (params.cleanUp) {
    mask = dilate(erode(mask, w, h), w, h);
    mask = erode(dilate(mask, w, h), w, h);
  }

  final total = w * h;
  final holds = <DetectedHold>[];
  final visited = Uint8List(total);
  final stack = Int32List(total);

  for (var start = 0; start < total; start++) {
    if (mask[start] == 0 || visited[start] == 1) continue;
    // Iterative 8-connected flood fill.
    var top = 0;
    stack[top++] = start;
    visited[start] = 1;
    var area = 0;
    var sumX = 0, sumY = 0;
    var minX = w, minY = h, maxX = -1, maxY = -1;
    while (top > 0) {
      final i = stack[--top];
      final x = i % w;
      final y = i ~/ w;
      area++;
      sumX += x;
      sumY += y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (var ny = y - 1; ny <= y + 1; ny++) {
        if (ny < 0 || ny >= h) continue;
        for (var nx = x - 1; nx <= x + 1; nx++) {
          if (nx < 0 || nx >= w) continue;
          final j = ny * w + nx;
          if (mask[j] == 1 && visited[j] == 0) {
            visited[j] = 1;
            stack[top++] = j;
          }
        }
      }
    }

    final areaFraction = area / total;
    if (areaFraction < params.minAreaFraction ||
        areaFraction > params.maxAreaFraction) {
      continue;
    }
    final boxW = maxX - minX + 1;
    final boxH = maxY - minY + 1;
    final fillRatio = area / (boxW * boxH);
    if (fillRatio < params.minFillRatio) continue;
    final longSide = boxW > boxH ? boxW : boxH;
    final shortSide = boxW > boxH ? boxH : boxW;
    if (longSide / shortSide > params.maxAspectRatio) continue;

    holds.add(
      DetectedHold(
        left: minX / w,
        top: minY / h,
        right: (maxX + 1) / w,
        bottom: (maxY + 1) / h,
        centerX: (sumX / area + 0.5) / w,
        centerY: (sumY / area + 0.5) / h,
        pixelArea: area,
        areaFraction: areaFraction,
        fillRatio: fillRatio,
      ),
    );
  }

  holds.sort((a, b) => a.centerY.compareTo(b.centerY));
  return holds;
}

/// 3x3 binary erosion; pixels outside the frame count as set, so blobs
/// touching the edge aren't eaten from that side.
Uint8List erode(Uint8List mask, int w, int h) =>
    _morph(mask, w, h, erode: true);

/// 3x3 binary dilation.
Uint8List dilate(Uint8List mask, int w, int h) =>
    _morph(mask, w, h, erode: false);

Uint8List _morph(Uint8List mask, int w, int h, {required bool erode}) {
  final out = Uint8List(mask.length);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var result = erode ? 1 : 0;
      search:
      for (var ny = y - 1; ny <= y + 1; ny++) {
        if (ny < 0 || ny >= h) continue;
        for (var nx = x - 1; nx <= x + 1; nx++) {
          if (nx < 0 || nx >= w) continue;
          final set = mask[ny * w + nx] == 1;
          if (erode && !set) {
            result = 0;
            break search;
          }
          if (!erode && set) {
            result = 1;
            break search;
          }
        }
      }
      out[y * w + x] = result;
    }
  }
  return out;
}
