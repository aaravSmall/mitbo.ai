import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/beta/beta_narration.dart';
import 'package:mitbo/beta/beta_planner.dart';
import 'package:mitbo/beta/beta_tracker.dart';
import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/models/climber_profile.dart';
import 'package:mitbo/services/beta_narrator.dart';
import 'package:mitbo/services/pose_service.dart';
import 'package:mitbo/state/climb_coach.dart';
import 'package:mitbo/state/problem_session.dart';
import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/problem_detector.dart';
import 'package:mitbo/vision/wall_frame.dart';

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

const _leftStart = (0.4, 0.6);
const _rightStart = (0.6, 0.6);

/// A small red problem on a square frame: top, two intermediates, two
/// start holds and a foothold, sorted top to bottom.
final _problem = DetectedProblem(
  color: const HoldColor(hue: 0, saturation: 0.8, value: 0.8),
  holds: [
    for (final p in [
      (0.5, 0.1),
      (0.4, 0.3),
      (0.6, 0.45),
      _leftStart,
      _rightStart,
      (0.3, 0.8),
    ])
      _holdAt(p.$1, p.$2),
  ],
  startHoldIndices: const [3, 4],
);

const _climber = ClimberProfile(heightCm: 180, wingspanCm: 185);

(double, double) _center(int hold) =>
    (_problem.holds[hold].centerX, _problem.holds[hold].centerY);

/// Records what the coach asks to be said, without a TTS engine.
class _RecordingNarrator extends BetaNarrator {
  final said = <List<String>>[];
  int stops = 0;

  @override
  Future<void> narrate(List<String> cues) async {
    said.add(List.of(cues));
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.value();
  }
}

/// A coach on a real [ProblemSession] whose wall grab and detection are
/// faked, driven by hand positions and a manual clock.
class _Rig {
  _Rig({CueMode mode = CueMode.live}) {
    session = ProblemSession(
      frames: frames,
      grabFrame: () => (grab = Completer<WallFrame?>()).future,
      detect: (reference, start, params) async => ProblemFound(_problem),
      profile: () => _climber,
      clock: () => now,
    );
    coach = ClimbCoach(
      session: session,
      frames: frames,
      narrator: narrator,
      profile: () => _climber,
      clock: () => now,
      mode: mode,
    );
  }

  final frames = ValueNotifier<PoseFrame?>(null);
  final narrator = _RecordingNarrator();
  late final ProblemSession session;
  late final ClimbCoach coach;
  Duration now = Duration.zero;
  Completer<WallFrame?>? grab;
  (double, double)? left;
  (double, double)? right;

  /// Emits the current hand positions every 100 ms for [ms].
  void hold({int ms = 1000}) {
    for (var t = 0; t < ms; t += 100) {
      frames.value = PoseFrame(
        pose: null,
        imageSize: const Size(640, 480),
        rotation: InputImageRotation.rotation0deg,
        keypoints: ClimberKeypoints(
          leftHand: left == null ? null : Keypoint(left!.$1, left!.$2, 0.9),
          rightHand: right == null ? null : Keypoint(right!.$1, right!.$2, 0.9),
        ),
      );
      now += const Duration(milliseconds: 100);
    }
  }

  /// Scans the wall, settles on the start holds until the problem is
  /// found, then confirms the holds so it locks.
  Future<void> lock() async {
    left = null;
    right = null;
    hold(ms: 1100);
    grab!.complete(WallFrame(2, 2, Uint8List(12)));
    await _flush();
    left = _leftStart;
    right = _rightStart;
    hold(ms: 1500);
    await _flush();
    expect(session.phase, ProblemPhase.confirming);
    // Nothing is coached until the user confirms the holds.
    expect(coach.plan, isNull);
    session.confirmProblem();
    await _flush();
    expect(session.phase, ProblemPhase.locked);
  }

  /// Puts the hand for the current step on its target hold.
  void doNextMove() {
    final plan = coach.plan!;
    final move = plan.moves[coach.currentStep!.handMoveIndex];
    final target = _center(move.toHold!);
    if (move.limb == Limb.leftHand) {
      left = target;
    } else {
      right = target;
    }
    hold(ms: 500);
  }
}

void main() {
  group('ClimbCoach', () {
    test('live: intro and first move on lock, then a cue per move', () async {
      final rig = _Rig();
      expect(rig.coach.state, isNull);
      await rig.lock();

      final coach = rig.coach;
      final plan = coach.plan!;
      expect(plan, same(rig.session.beta));
      expect(coach.state, ClimbState.climbing);
      expect(coach.totalMoves, plan.handMoveCount);
      expect(rig.narrator.said, hasLength(1));
      final first = rig.narrator.said.single;
      expect(first[0], startsWith('Got the red problem: '));
      expect(first[1], stepCue(plan, coach.currentStep!));
      expect(coach.nextTargetHold, isNotNull);

      for (var guard = 0; guard < 20; guard++) {
        if (coach.state != ClimbState.climbing) break;
        rig.doNextMove();
      }
      expect(coach.state, ClimbState.sent);
      expect(coach.movesDone, coach.totalMoves);
      expect(coach.nextTargetHold, isNull);
      // Intro, one cue per remaining move, then the send.
      expect(rig.narrator.said, hasLength(coach.totalMoves + 1));
      expect(rig.narrator.said.last, [sentCue]);
    });

    test('upfront: reads the whole beta once and stays quiet', () async {
      final rig = _Rig(mode: CueMode.upfront);
      await rig.lock();
      final plan = rig.coach.plan!;
      expect(rig.narrator.said, [betaCues(plan)]);
      rig.doNextMove();
      expect(rig.coach.movesDone, 1);
      expect(rig.narrator.said, hasLength(1));

      rig.coach.replay();
      expect(rig.narrator.said.last, betaCues(plan));
    });

    test('going off-beta replans from the holds the climber is on', () async {
      final rig = _Rig();
      await rig.lock();
      final coach = rig.coach;
      final plan = coach.plan!;

      // A hold above the start the beta doesn't send the left hand to
      // next.
      final steps = betaSteps(plan);
      final leftTargets = {
        for (final step in steps.take(2))
          if (plan.moves[step.handMoveIndex].limb == Limb.leftHand)
            plan.moves[step.handMoveIndex].toHold,
      };
      final offBeta = [0, 1, 2].firstWhere((h) => !leftTargets.contains(h));

      rig.left = _center(offBeta);
      rig.hold(ms: 1000);
      expect(coach.replanned, isTrue);
      expect(coach.state, ClimbState.climbing);
      final replan = coach.plan!;
      expect(replan, isNot(same(plan)));
      expect(replan.leftStart, offBeta);
      expect(replan.rightStart, 4);
      // Same wall scale as the original plan.
      expect(replan.cmPerUnit, plan.cmPerUnit);
      expect(rig.narrator.said.last, [
        newBetaCue,
        stepCue(replan, coach.currentStep!),
      ]);
    });

    test('coming off and getting back on restarts the beta', () async {
      final rig = _Rig();
      await rig.lock();
      rig.doNextMove();
      expect(rig.coach.movesDone, 1);

      rig.left = null;
      rig.right = null;
      rig.hold(ms: 2600);
      expect(rig.coach.state, ClimbState.offWall);
      expect(rig.narrator.said.last, [offWallCue]);
      expect(rig.coach.nextTargetHold, isNull);

      rig.left = _leftStart;
      rig.right = _rightStart;
      rig.hold(ms: 1100);
      expect(rig.coach.state, ClimbState.climbing);
      expect(rig.coach.movesDone, 0);
      expect(rig.narrator.said.last.first, fromStartCue);
    });

    test('replay repeats the current move', () async {
      final rig = _Rig();
      await rig.lock();
      rig.coach.replay();
      expect(rig.narrator.said.last, [
        stepCue(rig.coach.plan!, rig.coach.currentStep!),
      ]);
    });

    test('switching mode stops talking; resetting the problem too', () async {
      final rig = _Rig();
      await rig.lock();
      rig.coach.mode = CueMode.upfront;
      expect(rig.narrator.stops, 1);
      expect(rig.coach.mode, CueMode.upfront);

      rig.session.resetProblem();
      expect(rig.narrator.stops, 2);
      expect(rig.coach.state, isNull);
      expect(rig.coach.plan, isNull);
    });
  });
}
