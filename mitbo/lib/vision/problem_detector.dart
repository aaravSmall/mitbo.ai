import 'hold_color.dart';
import 'hold_segmenter.dart';
import 'start_detector.dart';
import 'wall_frame.dart';

/// The holds of the problem the climber is on.
class DetectedProblem {
  const DetectedProblem({
    required this.color,
    required this.holds,
    required this.startHoldIndices,
    this.warnings = const [],
  });

  /// The problem's hold color.
  final HoldColor color;

  /// Every hold of [color] in frame, sorted top to bottom.
  final List<DetectedHold> holds;

  /// Indices into [holds] of the start hold(s).
  final List<int> startHoldIndices;

  /// Non-fatal issues worth showing in debug UI.
  final List<String> warnings;

  /// The highest hold in frame (the likely finish), or null if none.
  DetectedHold? get topHold => holds.isEmpty ? null : holds.first;
}

/// Outcome of [detectProblem].
sealed class ProblemResult {
  const ProblemResult();
}

class ProblemFound extends ProblemResult {
  const ProblemFound(this.problem);
  final DetectedProblem problem;
}

class ProblemFailed extends ProblemResult {
  const ProblemFailed(this.reason);

  /// Short, user-facing explanation.
  final String reason;
}

/// Works out the problem from a clean wall [reference] and the climber's
/// [start] position: samples the hold color under the start hands, then
/// finds every hold of that color.
///
/// Pure and synchronous, with sendable inputs and outputs, so it can run
/// in `Isolate.run`.
ProblemResult detectProblem(
  WallFrame reference,
  StartPosition start, {
  SegmentationParams params = const SegmentationParams(),
  double sampleRadius = 0.03,
  double startHoldMargin = 0.02,
  double maxStartHoldDistance = 0.06,
}) {
  final points = start.handPoints;
  final warnings = <String>[];

  final samples = <HoldColor>[];
  for (final (x, y) in points) {
    final color = sampleHoldColor(
      reference,
      x,
      y,
      radius: sampleRadius,
      tolerance: params.tolerance,
    );
    if (color != null) samples.add(color);
  }
  if (samples.isEmpty) {
    return const ProblemFailed("Couldn't read a hold color under your hands");
  }

  var color = samples.first;
  if (samples.length == 2) {
    final other = samples[1];
    if (!_sameColor(color, other, params.tolerance)) {
      // An achromatic reading usually means a hand is over bare wall, so
      // a real color wins; otherwise go with the more confident sample.
      if (color.achromatic != other.achromatic) {
        if (color.achromatic) color = other;
      } else if (other.confidence > color.confidence) {
        color = other;
      }
      warnings.add(
        'Hands are on different colors (${samples[0].name} and '
        '${samples[1].name}); using ${color.name}',
      );
    }
  } else if (points.length == 2) {
    warnings.add('Could only read the color under one hand');
  }

  final holds = segmentHolds(reference, color, params: params);
  if (holds.isEmpty) {
    return ProblemFailed("Couldn't find any ${color.name} holds");
  }

  final startIndices = <int>[];
  for (final (x, y) in points) {
    final index = _startHoldAt(
      holds,
      x,
      y,
      margin: startHoldMargin,
      maxDistance: maxStartHoldDistance,
    );
    if (index == null) {
      warnings.add('No ${color.name} hold found under a start hand');
    } else if (!startIndices.contains(index)) {
      startIndices.add(index);
    }
  }
  if (startIndices.isEmpty) {
    return ProblemFailed(
      'Found ${color.name} holds, but none under your hands',
    );
  }

  return ProblemFound(
    DetectedProblem(
      color: color,
      holds: holds,
      startHoldIndices: startIndices,
      warnings: warnings,
    ),
  );
}

/// Indices into [holds] of the hold(s) under [start]'s hands — for holds
/// that came from somewhere other than [detectProblem] (e.g. marked by
/// hand). Empty if no hold is close enough.
List<int> startHoldIndicesFor(
  List<DetectedHold> holds,
  StartPosition start, {
  double margin = 0.02,
  double maxDistance = 0.06,
}) {
  final indices = <int>[];
  for (final (x, y) in start.handPoints) {
    final index = _startHoldAt(
      holds,
      x,
      y,
      margin: margin,
      maxDistance: maxDistance,
    );
    if (index != null && !indices.contains(index)) indices.add(index);
  }
  return indices;
}

bool _sameColor(HoldColor a, HoldColor b, ColorTolerance tolerance) {
  if (a.achromatic != b.achromatic) return false;
  if (a.achromatic) {
    return (a.value - b.value).abs() <= tolerance.valueTolerance;
  }
  return hueDistance(a.hue, b.hue) <= tolerance.hueTolerance;
}

/// The hold whose box contains ([x], [y]) (grown by [margin]), preferring
/// the nearest centroid; otherwise the nearest hold within [maxDistance].
int? _startHoldAt(
  List<DetectedHold> holds,
  double x,
  double y, {
  required double margin,
  required double maxDistance,
}) {
  int? best;
  var bestDistance = double.infinity;
  var bestContains = false;
  for (var i = 0; i < holds.length; i++) {
    final hold = holds[i];
    final contains = hold.contains(x, y, margin: margin);
    final distance = hold.distanceSquaredTo(x, y);
    if ((contains && !bestContains) ||
        (contains == bestContains && distance < bestDistance)) {
      best = i;
      bestDistance = distance;
      bestContains = contains;
    }
  }
  if (best == null) return null;
  if (!bestContains && bestDistance > maxDistance * maxDistance) return null;
  return best;
}
