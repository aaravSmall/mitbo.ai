import 'dart:math' as math;

import '../models/climber_keypoints.dart';
import '../models/climber_profile.dart';
import '../vision/problem_detector.dart';
import '../vision/start_detector.dart';
import 'crux.dart';

/// A climber's limbs.
enum Limb {
  leftHand,
  rightHand,
  leftFoot,
  rightFoot;

  bool get isHand => this == leftHand || this == rightHand;
  bool get isLeft => this == leftHand || this == leftFoot;

  /// "left" or "right".
  String get side => isLeft ? 'left' : 'right';
}

/// A point on the wall in centimeters: x to the right, y up.
class WallPoint {
  const WallPoint(this.x, this.y);

  final double x;
  final double y;

  double distanceTo(WallPoint other) {
    final dx = x - other.x;
    final dy = y - other.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  String toString() =>
      'WallPoint(${x.toStringAsFixed(0)}, ${y.toStringAsFixed(0)})';
}

/// What kind of move a [BetaMove] is.
enum MoveKind {
  /// A hand reaches to a new hold.
  reach,

  /// A hand reach beyond the comfortable range (the planner found nothing
  /// easier). A likely crux.
  bigReach,

  /// The second hand joins the first on the top hold.
  match,

  /// A foot steps up onto a hold.
  footHold,

  /// A foot moves up onto blank wall (no usable foothold).
  smear,
}

/// One step of the beta.
class BetaMove {
  const BetaMove({
    required this.limb,
    required this.kind,
    required this.from,
    required this.to,
    this.toHold,
    this.otherHand,
    this.otherHandHold,
    this.reachRatio = 0,
    this.toTop = false,
    this.footY,
  });

  final Limb limb;
  final MoveKind kind;

  /// Where the limb was and where it goes, in wall centimeters.
  final WallPoint from;
  final WallPoint to;

  /// Index into the problem's holds, or null for a smear.
  final int? toHold;

  /// For hand moves: where the other hand is (and its hold) during the move.
  final WallPoint? otherHand;
  final int? otherHandHold;

  /// For hand moves: hand-to-hand span as a fraction of the climber's
  /// max span (1 = fully stretched).
  final double reachRatio;

  /// The move lands on the top hold.
  final bool toTop;

  /// For hand moves: height of the higher foot during the move, in wall
  /// centimeters. Used to judge how stretched out the climber is.
  final double? footY;

  double get dx => to.x - from.x;
  double get dy => to.y - from.y;
  double get distance => from.distanceTo(to);
}

/// A full move sequence for a problem.
class BetaPlan {
  const BetaPlan({
    required this.holds,
    required this.leftStart,
    required this.rightStart,
    required this.topHold,
    required this.moves,
    required this.cmPerUnit,
    required this.scaleFromBody,
    this.warnings = const [],
    this.difficulties = const [],
    this.cruxMove,
  });

  /// Hold centers in wall centimeters, in the problem's hold order.
  final List<WallPoint> holds;

  /// Start hold of each hand (equal when matched).
  final int leftStart;
  final int rightStart;
  final int topHold;
  final List<BetaMove> moves;

  /// Centimeters per image height: the scale used to measure the wall.
  final double cmPerUnit;

  /// True when the scale came from the climber's torso in frame; false
  /// when it fell back to an assumed wall height.
  final bool scaleFromBody;

  final List<String> warnings;

  /// [moveDifficulty] of each move in [moves] (same length, or empty).
  final List<double> difficulties;

  /// Index into [moves] of the crux, or null when no move stands out as
  /// hard (see [findCrux]).
  final int? cruxMove;

  /// The crux as a 1-based hand move number (as numbered on the overlay
  /// and in cues), or null.
  int? get cruxHandMove {
    final crux = cruxMove;
    return crux == null ? null : handMoveNumber(crux);
  }

  /// 1-based number of the hand move at [moveIndex] among all hand moves,
  /// or null if that move isn't a hand move.
  int? handMoveNumber(int moveIndex) {
    if (moveIndex < 0 || moveIndex >= moves.length) return null;
    if (!moves[moveIndex].limb.isHand) return null;
    var n = 0;
    for (var i = 0; i <= moveIndex; i++) {
      if (moves[i].limb.isHand) n++;
    }
    return n;
  }

  bool get startMatched => leftStart == rightStart;

  int get handMoveCount => moves.where((m) => m.limb.isHand).length;

  /// True when the climber finishes matched on the top hold.
  bool get sends =>
      moves.isNotEmpty &&
      moves.last.kind == MoveKind.match &&
      moves.last.toHold == topHold;
}

/// Reach limits derived from a climber's height and wingspan.
class ReachModel {
  ReachModel(ClimberProfile profile)
    : height = profile.heightCm,
      wingspan = profile.wingspanCm;

  final double height;
  final double wingspan;

  /// Shoulder to fingertip.
  double get armLength => math.max(wingspan / 2 - 0.1 * height, 0.3 * height);

  /// Furthest the hands can be apart while both hold on.
  double get maxSpan => 0.9 * wingspan;

  /// Highest a hand can reach above the higher foot: shoulder height plus
  /// an arm, plus a little for standing on toes.
  double get maxReachAboveFoot => 0.87 * height + armLength;

  /// The most natural height gain per hand move.
  double get idealGain => 0.35 * wingspan;

  /// Feet closer than this below the lower hand leave the climber balled
  /// up, so feet don't step higher than this.
  double get minHandAboveFoot => 0.45 * height;

  /// The biggest high-step a foot makes in one move.
  double get maxStep => 0.6 * height;
}

/// Torso (shoulder center to hip center) as a fraction of height.
const torsoFraction = 0.29;

/// Assumed visible wall height when the climber's torso isn't in frame.
const fallbackFrameHeightCm = 350.0;

/// Plans a beta for [problem] from the climber's [start] position.
///
/// Pure geometry (no LLM): a [ReachModel] built from [profile] plus hold
/// positions measured in centimeters. Hold coordinates are normalized to a
/// frame [aspect] (width / height) wide. Scale comes from the climber's
/// torso length at the start when visible.
///
/// The sequence greedily moves the lower hand to the best reachable hold
/// above it (closest to an ideal gain above the other hand, without
/// crossing or overstretching); steps a foot up when the hands run out of
/// reach; and finishes matched on the top hold.
BetaPlan planBeta(
  DetectedProblem problem,
  StartPosition start, {
  required ClimberProfile profile,
  required double aspect,
  int maxMoves = 40,
}) {
  final warnings = <String>[];
  final reach = ReachModel(profile);

  // Scale: cm per image height.
  var cmPerUnit = fallbackFrameHeightCm;
  var scaleFromBody = false;
  final shoulders = start.shoulderCenter;
  final hips = start.hipCenter;
  if (shoulders != null && hips != null) {
    final dx = (shoulders.x - hips.x) * aspect;
    final dy = shoulders.y - hips.y;
    final torso = math.sqrt(dx * dx + dy * dy);
    final estimate = torso > 0 ? torsoFraction * reach.height / torso : 0.0;
    // A frame showing between 1.5 m and 8 m of wall is plausible.
    if (estimate >= 150 && estimate <= 800) {
      cmPerUnit = estimate;
      scaleFromBody = true;
    }
  }
  if (!scaleFromBody) {
    warnings.add(
      "Couldn't measure your torso; assuming the frame shows "
      '${(fallbackFrameHeightCm / 100).toStringAsFixed(1)} m of wall',
    );
  }

  WallPoint toWall(double nx, double ny) =>
      WallPoint(nx * aspect * cmPerUnit, (1 - ny) * cmPerUnit);
  WallPoint? keypointToWall(Keypoint? k) => k == null ? null : toWall(k.x, k.y);

  final holds = [for (final h in problem.holds) toWall(h.centerX, h.centerY)];
  if (holds.isEmpty) {
    return BetaPlan(
      holds: holds,
      leftStart: 0,
      rightStart: 0,
      topHold: 0,
      moves: const [],
      cmPerUnit: cmPerUnit,
      scaleFromBody: scaleFromBody,
      warnings: [...warnings, 'No holds to plan on'],
    );
  }
  final top = _highest(holds);

  // Each hand starts on the nearest start hold.
  final startIndices = problem.startHoldIndices.isEmpty
      ? [_nearest(holds, keypointToWall(start.leftHand)!)]
      : problem.startHoldIndices;
  int nearestStart(WallPoint p) {
    var best = startIndices.first;
    for (final i in startIndices) {
      if (holds[i].distanceTo(p) < holds[best].distanceTo(p)) best = i;
    }
    return best;
  }

  final leftHandStart = keypointToWall(start.leftHand)!;
  final rightHandStart = keypointToWall(start.rightHand)!;
  var left = nearestStart(leftHandStart);
  var right = start.matched || startIndices.length == 1
      ? left
      : nearestStart(rightHandStart);
  if (left == right && startIndices.length > 1 && !start.matched) {
    // Both hands mapped to one hold: give the right hand the other one.
    right = startIndices.firstWhere((i) => i != left);
  }
  final leftStart = left;
  final rightStart = right;

  // Feet: on the nearest suitable hold if visible, else estimated.
  final lowerHandY = math.min(holds[left].y, holds[right].y);
  WallPoint placeFoot(Keypoint? keypoint, WallPoint hand) {
    final seen = keypointToWall(keypoint);
    final guess =
        seen ?? WallPoint(hand.x, lowerHandY - 0.9 * reach.height);
    int? best;
    for (var i = 0; i < holds.length; i++) {
      if (i == left || i == right) continue;
      if (holds[i].y > lowerHandY - reach.minHandAboveFoot) continue;
      if (holds[i].distanceTo(guess) > 0.2 * reach.height) continue;
      if (best == null ||
          holds[i].distanceTo(guess) < holds[best].distanceTo(guess)) {
        best = i;
      }
    }
    return best == null ? guess : holds[best];
  }

  var leftFoot = placeFoot(start.leftFoot, holds[left]);
  var rightFoot = placeFoot(start.rightFoot, holds[right]);

  final moves = <BetaMove>[];
  bool done() => left == top && right == top;

  BetaMove handMove(Limb limb, int target, MoveKind kind) {
    final moving = limb == Limb.leftHand ? left : right;
    final other = limb == Limb.leftHand ? right : left;
    return BetaMove(
      limb: limb,
      kind: kind,
      from: holds[moving],
      to: holds[target],
      toHold: target,
      otherHand: holds[other],
      otherHandHold: other,
      reachRatio: holds[target].distanceTo(holds[other]) / reach.maxSpan,
      toTop: target == top,
      footY: math.max(leftFoot.y, rightFoot.y),
    );
  }

  void applyHand(BetaMove move) {
    moves.add(move);
    if (move.limb == Limb.leftHand) {
      left = move.toHold!;
    } else {
      right = move.toHold!;
    }
  }

  /// Best reachable hold for [limb] above where it is now, or null.
  int? bestTarget(Limb limb) {
    final moving = limb == Limb.leftHand ? left : right;
    final other = limb == Limb.leftHand ? right : left;
    final from = holds[moving];
    final anchor = holds[other];
    final footY = math.max(leftFoot.y, rightFoot.y);
    int? best;
    var bestScore = double.negativeInfinity;
    for (var i = 0; i < holds.length; i++) {
      if (i == moving) continue;
      if (i == other && i != top) continue;
      final p = holds[i];
      if (p.y <= from.y + 5) continue;
      if (p.distanceTo(anchor) > reach.maxSpan) continue;
      if (p.y - footY > reach.maxReachAboveFoot) continue;
      if (i == top) return i;
      final gain = p.y - anchor.y;
      var score = -(gain - reach.idealGain).abs() / reach.idealGain;
      // Crossing over the other hand is awkward, and so is stacking right
      // above it (the next move then has to cross).
      final crossing = limb == Limb.leftHand
          ? p.x - anchor.x
          : anchor.x - p.x;
      if (crossing > -5) {
        score -= 0.5 + math.max(crossing, 0) / reach.wingspan;
      }
      // So is stretching close to the limit.
      final stretch = p.distanceTo(anchor) / reach.maxSpan;
      if (stretch > 0.8) score -= (stretch - 0.8) * 3;
      if (score > bestScore) {
        bestScore = score;
        best = i;
      }
    }
    return best;
  }

  /// Steps the lower foot up, onto a hold if there is one. Returns false
  /// if the feet can't usefully go higher.
  bool stepFootUp() {
    final moveLeft = leftFoot.y <= rightFoot.y;
    final foot = moveLeft ? leftFoot : rightFoot;
    final limb = moveLeft ? Limb.leftFoot : Limb.rightFoot;
    final handsLow = math.min(holds[left].y, holds[right].y);
    final ceiling = handsLow - reach.minHandAboveFoot;
    final hipX = (holds[left].x + holds[right].x) / 2;
    final sideX = hipX + (moveLeft ? -1 : 1) * 0.15 * reach.height;

    int? best;
    for (var i = 0; i < holds.length; i++) {
      if (i == left || i == right) continue;
      final p = holds[i];
      if (p.y > ceiling || p.y < foot.y + 15) continue;
      if (p.y > foot.y + reach.maxStep) continue;
      if ((p.x - sideX).abs() > 0.5 * reach.height) continue;
      if (best == null || p.y > holds[best].y) best = i;
    }

    WallPoint to;
    MoveKind kind;
    if (best != null) {
      to = holds[best];
      kind = MoveKind.footHold;
    } else {
      final y = math.min(foot.y + 0.5 * reach.height, ceiling);
      if (y < foot.y + 15) return false;
      to = WallPoint(sideX, y);
      kind = MoveKind.smear;
    }
    moves.add(
      BetaMove(limb: limb, kind: kind, from: foot, to: to, toHold: best),
    );
    if (moveLeft) {
      leftFoot = to;
    } else {
      rightFoot = to;
    }
    return true;
  }

  while (!done() && moves.length < maxMoves) {
    // One hand on top: match it.
    if (left == top || right == top) {
      final limb = left == top ? Limb.rightHand : Limb.leftHand;
      final moving = limb == Limb.leftHand ? left : right;
      final footY = math.max(leftFoot.y, rightFoot.y);
      if (holds[top].y - footY > reach.maxReachAboveFoot && stepFootUp()) {
        continue;
      }
      applyHand(
        BetaMove(
          limb: limb,
          kind: MoveKind.match,
          from: holds[moving],
          to: holds[top],
          toHold: top,
          otherHand: holds[top],
          otherHandHold: top,
          toTop: true,
          footY: footY,
        ),
      );
      continue;
    }

    final lower = holds[left].y <= holds[right].y
        ? Limb.leftHand
        : Limb.rightHand;
    final upper = lower == Limb.leftHand ? Limb.rightHand : Limb.leftHand;

    final lowerTarget = bestTarget(lower);
    if (lowerTarget != null) {
      applyHand(handMove(lower, lowerTarget, MoveKind.reach));
      continue;
    }
    if (stepFootUp()) continue;
    final upperTarget = bestTarget(upper);
    if (upperTarget != null) {
      applyHand(handMove(upper, upperTarget, MoveKind.reach));
      continue;
    }

    // Nothing in comfortable reach: go for the nearest hold above.
    final from = holds[lower == Limb.leftHand ? left : right];
    int? nearest;
    for (var i = 0; i < holds.length; i++) {
      if (holds[i].y <= from.y + 5) continue;
      if (i == left || i == right) continue;
      if (nearest == null ||
          holds[i].distanceTo(from) < holds[nearest].distanceTo(from)) {
        nearest = i;
      }
    }
    if (nearest == null) {
      warnings.add("Couldn't find a way to the top hold");
      break;
    }
    applyHand(handMove(lower, nearest, MoveKind.bigReach));
  }
  if (!done() && moves.length >= maxMoves) {
    warnings.add('Stopped planning after $maxMoves moves');
  }
  final difficulties = [for (final m in moves) moveDifficulty(m, reach)];
  return BetaPlan(
    holds: holds,
    leftStart: leftStart,
    rightStart: rightStart,
    topHold: top,
    moves: moves,
    cmPerUnit: cmPerUnit,
    scaleFromBody: scaleFromBody,
    warnings: warnings,
    difficulties: difficulties,
    cruxMove: findCrux(difficulties),
  );
}

int _highest(List<WallPoint> points) {
  var best = 0;
  for (var i = 1; i < points.length; i++) {
    if (points[i].y > points[best].y) best = i;
  }
  return best;
}

int _nearest(List<WallPoint> points, WallPoint p) {
  var best = 0;
  for (var i = 1; i < points.length; i++) {
    if (points[i].distanceTo(p) < points[best].distanceTo(p)) best = i;
  }
  return best;
}
