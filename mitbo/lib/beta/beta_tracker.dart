import 'dart:math' as math;

import '../models/climber_keypoints.dart';
import '../vision/problem_detector.dart';
import 'beta_planner.dart';

/// One cue's worth of beta: any foot moves, then the hand move the
/// tracker waits on.
///
/// Feet are tracked poorly on a wall (small, often hidden, often smearing),
/// so foot moves never block progress: they're cued together with the hand
/// move they set up, and the step completes when that hand lands.
class BetaStep {
  const BetaStep({required this.moveIndices, required this.handMoveIndex});

  /// Indices into [BetaPlan.moves], in order, ending with [handMoveIndex].
  final List<int> moveIndices;

  /// Index into [BetaPlan.moves] of the hand move that completes the step.
  final int handMoveIndex;
}

/// Groups [plan]'s moves into [BetaStep]s, one per hand move. Foot moves
/// after the last hand move (there shouldn't be any) are dropped.
List<BetaStep> betaSteps(BetaPlan plan) {
  final steps = <BetaStep>[];
  var pending = <int>[];
  for (var i = 0; i < plan.moves.length; i++) {
    pending.add(i);
    if (plan.moves[i].limb.isHand) {
      steps.add(
        BetaStep(moveIndices: List.unmodifiable(pending), handMoveIndex: i),
      );
      pending = <int>[];
    }
  }
  return steps;
}

/// Where the climber is in the climb, as far as the tracker can tell.
enum ClimbState {
  /// On the wall, working through the steps.
  climbing,

  /// Went off-beta; waiting for [BetaTracker.replan].
  replanning,

  /// Finished matched on the top hold.
  sent,

  /// Came off the wall (fell, stepped off, or topped out of frame);
  /// waiting for the climber to get back on the start holds.
  offWall,
}

/// Something that happened on the wall, reported by [BetaTracker.onPose].
sealed class ClimbEvent {
  const ClimbEvent();
}

/// The climber finished [step] (index into [BetaTracker.steps]); the next
/// step is `step + 1`. [skipped] earlier steps were never seen completing
/// and were assumed done (a missed detection, or the climber skipped a
/// hold).
class StepCompleted extends ClimbEvent {
  const StepCompleted(this.step, {this.skipped = 0});

  final int step;
  final int skipped;
}

/// The last step is done: matched on the top hold.
class ClimbSent extends ClimbEvent {
  const ClimbSent();
}

/// A hand settled on a problem hold the beta didn't plan for. The tracker
/// pauses until [BetaTracker.replan] is called with a plan from these
/// holds (indices into the problem's holds).
class OffBeta extends ClimbEvent {
  const OffBeta({required this.leftHold, required this.rightHold});

  final int leftHold;
  final int rightHold;
}

/// The climber came off the wall. [afterSend] is true when they'd already
/// sent (usually topping out or dropping off from the finish).
class OffWall extends ClimbEvent {
  const OffWall({required this.afterSend});

  final bool afterSend;
}

/// The climber is back on the start holds after coming off; tracking
/// restarts from the first step of the original beta.
class BackOnStart extends ClimbEvent {
  const BackOnStart();
}

/// Thresholds for [BetaTracker]. Coordinates are normalized to the frame.
class TrackerParams {
  const TrackerParams({
    this.holdMargin = 0.03,
    this.settleTime = const Duration(milliseconds: 300),
    this.offBetaSettleTime = const Duration(milliseconds: 800),
    this.lookahead = 2,
    this.minConfidence = 0.5,
    this.lostHandsTime = const Duration(milliseconds: 2500),
    this.belowStartMargin = 0.05,
    this.belowStartTime = const Duration(seconds: 1),
    this.backOnStartTime = const Duration(seconds: 1),
    this.offBetaDropAllowance = 0.03,
  });

  /// A hand within this distance of a hold's box is on it.
  final double holdMargin;

  /// How long a hand must stay on its target hold for the move to count.
  final Duration settleTime;

  /// How long a hand must stay on an unplanned hold to count as going
  /// off-beta. Longer than [settleTime], since a hand brushing past a
  /// hold or pausing on an intermediate is common.
  final Duration offBetaSettleTime;

  /// How many steps (counting the current one) a hand landing is checked
  /// against, so a missed detection doesn't stall the cues.
  final int lookahead;

  /// Keypoints less confident than this are treated as not visible.
  final double minConfidence;

  /// Both hands out of sight this long while climbing = off the wall.
  final Duration lostHandsTime;

  /// Both hands this far below the bottom of the start holds, for
  /// [belowStartTime] = off the wall (standing on the mat).
  final double belowStartMargin;
  final Duration belowStartTime;

  /// How long both hands must be back on the start holds to restart.
  final Duration backOnStartTime;

  /// A hand settling on a hold lower than its expected hold by more than
  /// this (e.g. dropping to chalk up past a low hold) isn't off-beta.
  final double offBetaDropAllowance;
}

/// Follows the climber through a [BetaPlan] from live pose keypoints:
/// works out when each move is done, when the climber goes off-beta, comes
/// off the wall, gets back on, or sends.
///
/// Pure logic with time passed in, like `StartDetector`: feed smoothed
/// keypoints to [onPose] and act on the events it returns. Starts in
/// [ClimbState.climbing], since a plan exists once the climber is on the
/// start holds.
class BetaTracker {
  BetaTracker({
    required this.problem,
    required BetaPlan plan,
    this.params = const TrackerParams(),
  }) : originalPlan = plan {
    _load(plan);
  }

  /// The problem whose holds the plan's hold indices refer to.
  final DetectedProblem problem;
  final TrackerParams params;

  /// The beta planned from the start holds; restored after coming off.
  final BetaPlan originalPlan;

  late BetaPlan _plan;
  late List<BetaStep> _steps;
  int _nextStep = 0;
  ClimbState _state = ClimbState.climbing;

  // Where each hand should be after the completed steps.
  late int _leftHold;
  late int _rightHold;

  // Reported by the last OffBeta, applied by replan(null).
  int? _offBetaLeft;
  int? _offBetaRight;

  final _leftWatch = _HandWatch();
  final _rightWatch = _HandWatch();
  Duration? _handsLostSince;
  Duration? _belowStartSince;
  Duration? _onStartSince;

  /// The beta being followed: [originalPlan], or a replan after going
  /// off-beta.
  BetaPlan get plan => _plan;

  /// [plan] grouped into cue-sized steps.
  List<BetaStep> get steps => _steps;

  ClimbState get state => _state;

  /// Index into [steps] of the step the climber is on (== the number of
  /// steps done). Equals `steps.length` once sent.
  int get nextStep => _nextStep;

  /// The step the climber is on, or null when there's none left.
  BetaStep? get currentStep =>
      _nextStep < _steps.length ? _steps[_nextStep] : null;

  /// The hold the current step's hand is heading for (index into the
  /// problem's holds), or null.
  int? get nextTargetHold {
    final step = currentStep;
    return step == null ? null : _plan.moves[step.handMoveIndex].toHold;
  }

  /// Where the tracker expects each hand to be (indices into the
  /// problem's holds).
  int get expectedLeftHold => _leftHold;
  int get expectedRightHold => _rightHold;

  /// Feeds one (smoothed) pose. Returns what happened, if anything.
  ClimbEvent? onPose(ClimberKeypoints keypoints, Duration now) {
    if (_state == ClimbState.replanning) return null;
    final left = _visible(keypoints.leftHand);
    final right = _visible(keypoints.rightHand);

    if (_state == ClimbState.climbing || _state == ClimbState.sent) {
      final off = _checkOffWall(left, right, now);
      if (off != null) return off;
    }
    if (_state == ClimbState.offWall) {
      return _checkBackOnStart(left, right, now);
    }
    if (_state != ClimbState.climbing) return null;
    return _watch(Limb.leftHand, _leftWatch, left, now) ??
        _watch(Limb.rightHand, _rightWatch, right, now);
  }

  /// Resumes after an [OffBeta] with [newPlan], planned from the off-beta
  /// holds. With null (or a plan with no moves), keeps following the old
  /// plan from where it was, with the hands where the climber put them.
  void replan(BetaPlan? newPlan) {
    if (_state != ClimbState.replanning) return;
    if (newPlan != null && newPlan.moves.isNotEmpty) {
      _load(newPlan);
    } else {
      _leftHold = _offBetaLeft ?? _leftHold;
      _rightHold = _offBetaRight ?? _rightHold;
    }
    _offBetaLeft = null;
    _offBetaRight = null;
    _state = ClimbState.climbing;
  }

  void _load(BetaPlan plan) {
    _plan = plan;
    _steps = betaSteps(plan);
    _nextStep = 0;
    _leftHold = plan.leftStart;
    _rightHold = plan.rightStart;
  }

  Keypoint? _visible(Keypoint? k) =>
      k != null && k.confidence >= params.minConfidence ? k : null;

  /// The problem hold under [k], preferring the nearest center, or null.
  int? _holdUnder(Keypoint k) {
    int? best;
    var bestDistance = double.infinity;
    for (var i = 0; i < problem.holds.length; i++) {
      final hold = problem.holds[i];
      if (!hold.contains(k.x, k.y, margin: params.holdMargin)) continue;
      final distance = hold.distanceSquaredTo(k.x, k.y);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = i;
      }
    }
    return best;
  }

  ClimbEvent? _checkOffWall(Keypoint? left, Keypoint? right, Duration now) {
    if (left == null && right == null) {
      final since = _handsLostSince ??= now;
      if (now - since >= params.lostHandsTime) return _goOffWall();
    } else {
      _handsLostSince = null;
    }

    var startBottom = 0.0;
    for (final i in {originalPlan.leftStart, originalPlan.rightStart}) {
      if (i < problem.holds.length) {
        startBottom = math.max(startBottom, problem.holds[i].bottom);
      }
    }
    final limit = startBottom + params.belowStartMargin;
    if (left != null && right != null && left.y > limit && right.y > limit) {
      final since = _belowStartSince ??= now;
      if (now - since >= params.belowStartTime) return _goOffWall();
    } else {
      _belowStartSince = null;
    }
    return null;
  }

  OffWall _goOffWall() {
    final afterSend = _state == ClimbState.sent;
    _state = ClimbState.offWall;
    _load(originalPlan);
    _resetWatches();
    return OffWall(afterSend: afterSend);
  }

  ClimbEvent? _checkBackOnStart(Keypoint? left, Keypoint? right, Duration now) {
    final starts = {originalPlan.leftStart, originalPlan.rightStart};
    final leftHold = left == null ? null : _holdUnder(left);
    final rightHold = right == null ? null : _holdUnder(right);
    final onStart =
        leftHold != null &&
        rightHold != null &&
        starts.contains(leftHold) &&
        starts.contains(rightHold) &&
        (starts.length == 1 || leftHold != rightHold);
    if (!onStart) {
      _onStartSince = null;
      return null;
    }
    final since = _onStartSince ??= now;
    if (now - since < params.backOnStartTime) return null;
    _state = ClimbState.climbing;
    _resetWatches();
    return const BackOnStart();
  }

  void _resetWatches() {
    _leftWatch.reset();
    _rightWatch.reset();
    _handsLostSince = null;
    _belowStartSince = null;
    _onStartSince = null;
  }

  ClimbEvent? _watch(
    Limb limb,
    _HandWatch watch,
    Keypoint? hand,
    Duration now,
  ) {
    final hold = hand == null ? null : _holdUnder(hand);
    if (hold != watch.hold) {
      watch
        ..hold = hold
        ..since = now
        ..checkedMove = false
        ..checkedOffBeta = false;
    }
    if (hold == null) return null;
    final held = now - watch.since!;
    if (!watch.checkedMove && held >= params.settleTime) {
      watch.checkedMove = true;
      final event = _onSettled(limb, hold);
      if (event != null) return event;
    }
    if (!watch.checkedOffBeta && held >= params.offBetaSettleTime) {
      watch.checkedOffBeta = true;
      return _onSettledLong(limb, hold);
    }
    return null;
  }

  /// A hand has been on [hold] for [TrackerParams.settleTime]: completes
  /// the current step (or a later one within the lookahead) if that's
  /// where this hand was headed.
  ClimbEvent? _onSettled(Limb limb, int hold) {
    final end = math.min(_steps.length, _nextStep + params.lookahead);
    for (var j = _nextStep; j < end; j++) {
      final move = _plan.moves[_steps[j].handMoveIndex];
      if (move.limb == limb && move.toHold == hold) return _completeThrough(j);
    }
    return null;
  }

  ClimbEvent _completeThrough(int step) {
    for (var j = _nextStep; j <= step; j++) {
      final move = _plan.moves[_steps[j].handMoveIndex];
      final target = move.toHold;
      if (target == null) continue;
      if (move.limb == Limb.leftHand) {
        _leftHold = target;
      } else {
        _rightHold = target;
      }
    }
    final skipped = step - _nextStep;
    _nextStep = step + 1;
    if (_nextStep >= _steps.length) {
      _state = ClimbState.sent;
      return const ClimbSent();
    }
    return StepCompleted(step, skipped: skipped);
  }

  /// A hand has been on [hold] for [TrackerParams.offBetaSettleTime]: if
  /// it's not where the beta has it, the climber has gone their own way.
  ClimbEvent? _onSettledLong(Limb limb, int hold) {
    final isLeft = limb == Limb.leftHand;
    final expected = isLeft ? _leftHold : _rightHold;
    if (hold == expected) return null;
    if (expected < problem.holds.length &&
        problem.holds[hold].centerY >
            problem.holds[expected].centerY + params.offBetaDropAllowance) {
      return null;
    }
    final leftHold = isLeft ? hold : _leftHold;
    final rightHold = isLeft ? _rightHold : hold;
    _offBetaLeft = leftHold;
    _offBetaRight = rightHold;
    _state = ClimbState.replanning;
    return OffBeta(leftHold: leftHold, rightHold: rightHold);
  }
}

/// How long one hand has been on which hold.
class _HandWatch {
  int? hold;
  Duration? since;
  bool checkedMove = false;
  bool checkedOffBeta = false;

  void reset() {
    hold = null;
    since = null;
    checkedMove = false;
    checkedOffBeta = false;
  }
}
