import 'dart:math' as math;

import '../models/climber_keypoints.dart';

/// Where the climber's hands (and feet, if visible) were when they settled
/// on the start holds. Normalized upright coordinates.
class StartPosition {
  const StartPosition({
    required this.leftHand,
    required this.rightHand,
    this.leftFoot,
    this.rightFoot,
    this.hipCenter,
    this.shoulderCenter,
    this.matchedDistance = 0.04,
  });

  final Keypoint leftHand;
  final Keypoint rightHand;
  final Keypoint? leftFoot;
  final Keypoint? rightFoot;

  /// Body points at the start, used by the beta planner for scale.
  final Keypoint? hipCenter;
  final Keypoint? shoulderCenter;

  /// Hands closer than this are on one shared start hold.
  final double matchedDistance;

  /// True when both hands are on the same start hold.
  bool get matched => _distance(leftHand, rightHand) <= matchedDistance;

  /// The points to sample hold color at: one per start hold.
  List<(double, double)> get handPoints => matched
      ? [((leftHand.x + rightHand.x) / 2, (leftHand.y + rightHand.y) / 2)]
      : [(leftHand.x, leftHand.y), (rightHand.x, rightHand.y)];
}

/// Detects the moment the climber settles on the start holds: both hands
/// visible, above the hips, and still for [holdFor].
///
/// Fires once, then stays quiet until [reset]. Time is passed in so the
/// logic is deterministic and testable.
class StartDetector {
  StartDetector({
    this.holdFor = const Duration(milliseconds: 1200),
    this.stillRadius = 0.025,
    this.glitchJump = 0.15,
    this.matchedDistance = 0.04,
    this.handsAboveHipsMargin = 0.02,
  });

  /// How long both hands must stay put.
  final Duration holdFor;

  /// How far (normalized) a hand may drift and still count as still.
  final double stillRadius;

  /// A jump larger than this between consecutive frames is treated as a
  /// tracking glitch: the stillness timer restarts.
  final double glitchJump;

  /// See [StartPosition.matchedDistance].
  final double matchedDistance;

  /// When the hip center is visible, both hands must be at least this far
  /// above it, so standing around with arms down doesn't count as a start.
  final double handsAboveHipsMargin;

  Keypoint? _anchorLeft;
  Keypoint? _anchorRight;
  Keypoint? _lastLeft;
  Keypoint? _lastRight;
  Duration? _stillSince;
  bool _fired = false;

  // Set by reset(requireMove: true): hands must leave these spots before
  // a new start can be detected.
  Keypoint? _blockedLeft;
  Keypoint? _blockedRight;
  bool _requireMove = false;

  /// Whether a start has been detected since the last [reset].
  bool get fired => _fired;

  /// Feeds one (smoothed) pose result. Returns the start position on the
  /// frame the start is detected, null otherwise.
  StartPosition? onPose(ClimberKeypoints keypoints, Duration time) {
    if (_fired) return null;
    final left = keypoints.leftHand;
    final right = keypoints.rightHand;
    if (left == null || right == null || !_handsUp(keypoints)) {
      _restart(null, null, null);
      return null;
    }

    if (_requireMove) {
      final blockedLeft = _blockedLeft;
      final blockedRight = _blockedRight;
      if (blockedLeft == null || blockedRight == null) {
        // Hands weren't visible at reset: block at the first sighting.
        _blockedLeft = left;
        _blockedRight = right;
        return null;
      }
      if (_distance(left, blockedLeft) <= stillRadius &&
          _distance(right, blockedRight) <= stillRadius) {
        return null;
      }
      _requireMove = false;
    }

    final lastLeft = _lastLeft;
    final lastRight = _lastRight;
    final glitch =
        lastLeft != null &&
        lastRight != null &&
        (_distance(left, lastLeft) > glitchJump ||
            _distance(right, lastRight) > glitchJump);
    final anchorLeft = _anchorLeft;
    final anchorRight = _anchorRight;
    final moved =
        anchorLeft == null ||
        anchorRight == null ||
        _distance(left, anchorLeft) > stillRadius ||
        _distance(right, anchorRight) > stillRadius;

    if (glitch || moved) {
      _restart(left, right, time);
    }
    _lastLeft = left;
    _lastRight = right;

    final stillSince = _stillSince;
    if (stillSince == null || time - stillSince < holdFor) return null;
    _fired = true;
    return StartPosition(
      leftHand: left,
      rightHand: right,
      leftFoot: keypoints.leftFoot,
      rightFoot: keypoints.rightFoot,
      hipCenter: keypoints.hipCenter,
      shoulderCenter: keypoints.shoulderCenter,
      matchedDistance: matchedDistance,
    );
  }

  /// Re-arms the detector. With [requireMove], the hands must first move
  /// away from where they are now, so a climber still standing on a start
  /// that just failed doesn't retrigger it over and over.
  void reset({bool requireMove = false}) {
    _requireMove = requireMove;
    _blockedLeft = requireMove ? _lastLeft : null;
    _blockedRight = requireMove ? _lastRight : null;
    _fired = false;
    _restart(null, null, null);
  }

  bool _handsUp(ClimberKeypoints keypoints) {
    final hip = keypoints.hipCenter;
    if (hip == null) return true;
    final limit = hip.y - handsAboveHipsMargin;
    return keypoints.leftHand!.y < limit && keypoints.rightHand!.y < limit;
  }

  void _restart(Keypoint? left, Keypoint? right, Duration? time) {
    _anchorLeft = left;
    _anchorRight = right;
    _stillSince = time;
    if (left == null) {
      _lastLeft = null;
      _lastRight = null;
    }
  }
}

double _distance(Keypoint a, Keypoint b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}
