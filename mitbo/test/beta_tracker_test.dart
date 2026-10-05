import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/beta/beta_planner.dart';
import 'package:mitbo/beta/beta_tracker.dart';
import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/problem_detector.dart';

DetectedHold _holdAt(double x, double y) => DetectedHold(
  left: x - 0.02,
  top: y - 0.02,
  right: x + 0.02,
  bottom: y + 0.02,
  centerX: x,
  centerY: y,
  pixelArea: 50,
  areaFraction: 0.001,
  fillRatio: 0.8,
);

// Normalized hold positions (y down), sorted top to bottom like the
// detector's output.
const _top = (0.5, 0.1); // 0
const _h1 = (0.4, 0.3); // 1
const _h2 = (0.6, 0.45); // 2
const _leftStart = (0.4, 0.6); // 3
const _rightStart = (0.6, 0.6); // 4
const _low = (0.3, 0.8); // 5: a foothold

final _problem = DetectedProblem(
  color: const HoldColor(hue: 0, saturation: 0.8, value: 0.8),
  holds: [
    for (final p in [_top, _h1, _h2, _leftStart, _rightStart, _low])
      _holdAt(p.$1, p.$2),
  ],
  startHoldIndices: const [3, 4],
);

// Wall positions don't matter to the tracker, only hold indices.
const _w = WallPoint(0, 0);

BetaMove _hand(Limb limb, int to, {MoveKind kind = MoveKind.reach}) =>
    BetaMove(limb: limb, kind: kind, from: _w, to: _w, toHold: to);

/// Left foot smear, L→1, R→2, L→top, R matches.
final _plan = BetaPlan(
  holds: List.filled(6, _w),
  leftStart: 3,
  rightStart: 4,
  topHold: 0,
  moves: [
    const BetaMove(limb: Limb.leftFoot, kind: MoveKind.smear, from: _w, to: _w),
    _hand(Limb.leftHand, 1),
    _hand(Limb.rightHand, 2),
    _hand(Limb.leftHand, 0),
    _hand(Limb.rightHand, 0, kind: MoveKind.match),
  ],
  cmPerUnit: 350,
  scaleFromBody: false,
);

/// Feeds poses every 100 ms and collects the events.
class _Climber {
  _Climber({BetaPlan? plan, bool waitForStart = false})
    : tracker = BetaTracker(
        problem: _problem,
        plan: plan ?? _plan,
        waitForStart: waitForStart,
      );

  final BetaTracker tracker;
  int _ms = 0;

  /// Holds the hands at [left] / [right] (null = not visible) for [ms].
  List<ClimbEvent> hold(
    (double, double)? left,
    (double, double)? right, {
    int ms = 1000,
  }) {
    final events = <ClimbEvent>[];
    final end = _ms + ms;
    for (; _ms < end; _ms += 100) {
      final keypoints = ClimberKeypoints(
        leftHand: left == null ? null : Keypoint(left.$1, left.$2, 0.9),
        rightHand: right == null ? null : Keypoint(right.$1, right.$2, 0.9),
      );
      final event = tracker.onPose(keypoints, Duration(milliseconds: _ms));
      if (event != null) events.add(event);
    }
    return events;
  }
}

void main() {
  group('betaSteps', () {
    test('groups foot moves with the hand move that follows', () {
      final steps = betaSteps(_plan);
      expect(steps, hasLength(4));
      expect(steps[0].moveIndices, [0, 1]);
      expect(steps[0].handMoveIndex, 1);
      expect(steps[1].moveIndices, [2]);
      expect(steps.last.handMoveIndex, 4);
    });
  });

  group('BetaTracker', () {
    test('follows the climber move by move to the send', () {
      final c = _Climber();
      expect(c.tracker.state, ClimbState.climbing);
      expect(c.tracker.nextTargetHold, 1);
      expect(c.hold(_leftStart, _rightStart), isEmpty);

      var events = c.hold(_h1, _rightStart, ms: 500);
      expect(events, hasLength(1));
      expect((events.single as StepCompleted).step, 0);
      expect((events.single as StepCompleted).skipped, 0);
      expect(c.tracker.nextTargetHold, 2);
      expect(c.tracker.expectedLeftHold, 1);

      events = c.hold(_h1, _h2, ms: 500);
      expect((events.single as StepCompleted).step, 1);
      events = c.hold(_top, _h2, ms: 500);
      expect((events.single as StepCompleted).step, 2);
      expect(c.tracker.nextTargetHold, 0);

      events = c.hold(_top, _top, ms: 500);
      expect(events.single, isA<ClimbSent>());
      expect(c.tracker.state, ClimbState.sent);
      expect(c.tracker.currentStep, isNull);
    });

    test('can wait for the climber to get on the start first', () {
      final c = _Climber(waitForStart: true);
      expect(c.tracker.state, ClimbState.waitingForStart);
      expect(c.tracker.nextStep, 0);
      // Away from the wall: no off-wall event, no moves.
      expect(c.hold(null, null, ms: 3000), isEmpty);
      expect(c.hold((0.4, 0.9), (0.6, 0.9), ms: 1500), isEmpty);
      expect(c.hold(_h1, _rightStart), isEmpty);

      final events = c.hold(_leftStart, _rightStart, ms: 1100);
      expect((events.single as BackOnStart).first, isTrue);
      expect(c.tracker.state, ClimbState.climbing);
      expect(c.hold(_h1, _rightStart, ms: 500).single, isA<StepCompleted>());
    });

    test('a hand brushing past its target does not count', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      expect(c.hold(_h1, _rightStart, ms: 200), isEmpty);
      expect(c.hold(_leftStart, _rightStart), isEmpty);
      expect(c.tracker.nextStep, 0);
    });

    test('skips ahead when a later move lands first', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      final events = c.hold(_leftStart, _h2, ms: 500);
      final done = events.single as StepCompleted;
      expect(done.step, 1);
      expect(done.skipped, 1);
      expect(c.tracker.nextStep, 2);
      expect(c.tracker.expectedRightHold, 2);
    });

    test('settling on an unplanned hold goes off-beta', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      // Left hand takes hold 2 (the beta has the right hand there).
      final events = c.hold(_h2, _rightStart);
      final off = events.single as OffBeta;
      expect(off.leftHold, 2);
      expect(off.rightHold, 4);
      expect(c.tracker.state, ClimbState.replanning);
      // Paused until replanned.
      expect(c.hold(_h2, _rightStart), isEmpty);

      c.tracker.replan(null);
      expect(c.tracker.state, ClimbState.climbing);
      expect(c.tracker.expectedLeftHold, 2);
      expect(c.tracker.nextStep, 0);
    });

    test('a replan is followed, and dropped after coming off', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      c.hold(_h2, _rightStart);
      final replanned = BetaPlan(
        holds: List.filled(6, _w),
        leftStart: 2,
        rightStart: 4,
        topHold: 0,
        moves: [
          _hand(Limb.leftHand, 0),
          _hand(Limb.rightHand, 0, kind: MoveKind.match),
        ],
        cmPerUnit: 350,
        scaleFromBody: false,
      );
      c.tracker.replan(replanned);
      expect(c.tracker.plan, same(replanned));
      expect(c.tracker.nextTargetHold, 0);
      expect(c.hold(_h2, _rightStart), isEmpty);

      final events = c.hold(null, null, ms: 2600);
      expect(events.single, isA<OffWall>());
      expect(c.tracker.plan, same(_plan));
      expect(c.tracker.nextTargetHold, 1);
    });

    test('dropping a hand low to chalk up is not off-beta', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      expect(c.hold(_low, _rightStart, ms: 1500), isEmpty);
      expect(c.tracker.state, ClimbState.climbing);
    });

    test('losing both hands means off the wall; back on start restarts', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      c.hold(_h1, _rightStart, ms: 500);
      expect(c.tracker.nextStep, 1);

      expect(c.hold(null, null, ms: 2000), isEmpty);
      var events = c.hold(null, null, ms: 600);
      expect((events.single as OffWall).afterSend, isFalse);
      expect(c.tracker.state, ClimbState.offWall);
      expect(c.tracker.nextStep, 0);

      // Hands somewhere else don't restart it.
      expect(c.hold(_h1, _h2, ms: 1500), isEmpty);
      events = c.hold(_leftStart, _rightStart, ms: 1100);
      expect((events.single as BackOnStart).first, isFalse);
      expect(c.tracker.state, ClimbState.climbing);
    });

    test('both hands below the start holds means off the wall', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      final events = c.hold((0.4, 0.85), (0.6, 0.85), ms: 1100);
      expect(events.single, isA<OffWall>());
    });

    test('coming off after the send is reported as such', () {
      final c = _Climber();
      c.hold(_leftStart, _rightStart);
      c.hold(_h1, _rightStart, ms: 500);
      c.hold(_h1, _h2, ms: 500);
      c.hold(_top, _h2, ms: 500);
      c.hold(_top, _top, ms: 500);
      expect(c.tracker.state, ClimbState.sent);
      final events = c.hold(null, null, ms: 2600);
      expect((events.single as OffWall).afterSend, isTrue);
    });
  });
}
