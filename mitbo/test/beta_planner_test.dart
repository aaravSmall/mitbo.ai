import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/beta/beta_narration.dart';
import 'package:mitbo/beta/beta_planner.dart';
import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/models/climber_profile.dart';
import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/problem_detector.dart';
import 'package:mitbo/vision/start_detector.dart';

// Portrait frame; with no torso in frame the planner assumes it shows
// fallbackFrameHeightCm of wall, so these helpers convert wall cm
// (x right, y up) to normalized coordinates on that scale.
const _aspect = 0.75;
const _scale = fallbackFrameHeightCm;

double _nx(double xCm) => xCm / (_aspect * _scale);
double _ny(double yCm) => 1 - yCm / _scale;

DetectedHold _holdAt(double xCm, double yCm) {
  final x = _nx(xCm);
  final y = _ny(yCm);
  return DetectedHold(
    left: x - 0.01,
    top: y - 0.01,
    right: x + 0.01,
    bottom: y + 0.01,
    centerX: x,
    centerY: y,
    pixelArea: 50,
    areaFraction: 0.001,
    fillRatio: 0.8,
  );
}

Keypoint _keypointAt(double xCm, double yCm) =>
    Keypoint(_nx(xCm), _ny(yCm), 0.9);

/// A problem from hold positions in cm; [starts] index into [points].
/// Holds are sorted top to bottom like the detector's output.
DetectedProblem _problem(List<(double, double)> points, List<int> starts) {
  final order = List.generate(points.length, (i) => i)
    ..sort((a, b) => points[b].$2.compareTo(points[a].$2));
  return DetectedProblem(
    color: const HoldColor(hue: 0, saturation: 0.8, value: 0.8),
    holds: [for (final i in order) _holdAt(points[i].$1, points[i].$2)],
    startHoldIndices: [for (final s in starts) order.indexOf(s)],
  );
}

StartPosition _start(
  (double, double) left,
  (double, double) right, {
  Keypoint? shoulders,
  Keypoint? hips,
}) => StartPosition(
  leftHand: _keypointAt(left.$1, left.$2),
  rightHand: _keypointAt(right.$1, right.$2),
  shoulderCenter: shoulders,
  hipCenter: hips,
);

ClimberProfile _climber(double height, double wingspan) =>
    ClimberProfile(heightCm: height, wingspanCm: wingspan);

/// Two start holds, a ladder of alternating holds every 35 cm, and a top.
final _ladder = <(double, double)>[
  (110, 100),
  (150, 100),
  for (var k = 0; k < 6; k++) (k.isEven ? 110.0 : 150.0, 135.0 + 35 * k),
  (130, 330),
];

void main() {
  group('planBeta', () {
    test('climbs a ladder hand over hand and matches the top', () {
      final plan = planBeta(
        _problem(_ladder, [0, 1]),
        _start((110, 100), (150, 100)),
        profile: _climber(175, 178),
        aspect: _aspect,
      );
      expect(plan.sends, isTrue);
      expect(plan.scaleFromBody, isFalse);
      expect(plan.warnings, isNotEmpty);
      expect(plan.startMatched, isFalse);

      final handMoves = plan.moves.where((m) => m.limb.isHand).toList();
      // Hands alternate on the way up and never overstretch.
      for (var i = 1; i < handMoves.length - 1; i++) {
        expect(handMoves[i].limb, isNot(handMoves[i - 1].limb));
      }
      for (final move in handMoves) {
        expect(move.reachRatio, lessThanOrEqualTo(1));
        expect(move.kind, isNot(MoveKind.bigReach));
        // Every hand move goes up.
        expect(move.dy, greaterThan(0));
      }
      // No crossing: left hand stays left of right hand on reaches.
      for (final move in handMoves.where((m) => m.kind == MoveKind.reach)) {
        final other = move.otherHand!;
        if (move.limb == Limb.leftHand) {
          expect(move.to.x, lessThan(other.x));
        } else {
          expect(move.to.x, greaterThan(other.x));
        }
      }
    });

    test('a taller climber skips holds a shorter one needs', () {
      int handMoves(ClimberProfile profile) => planBeta(
        _problem(_ladder, [0, 1]),
        _start((110, 100), (150, 100)),
        profile: profile,
        aspect: _aspect,
      ).handMoveCount;

      expect(handMoves(_climber(190, 196)), lessThan(handMoves(_climber(160, 158))));
    });

    test('flags a reach beyond the comfortable range as a big move', () {
      final plan = planBeta(
        _problem([(110, 100), (150, 100), (130, 330)], [0, 1]),
        _start((110, 100), (150, 100)),
        profile: _climber(170, 170),
        aspect: _aspect,
      );
      expect(plan.moves.map((m) => m.kind), contains(MoveKind.bigReach));
      expect(plan.sends, isTrue);
      // The big move is the crux, and the narration says so.
      final big = plan.moves.indexWhere((m) => m.kind == MoveKind.bigReach);
      expect(plan.cruxMove, big);
      expect(plan.difficulties, hasLength(plan.moves.length));
      final cues = betaCues(plan);
      expect(cues.first, endsWith('The crux is move ${plan.cruxHandMove}.'));
      expect(cues.where((c) => c.startsWith('Crux. Big move:')), hasLength(1));
    });

    test('a matched start uses one hold for both hands', () {
      final plan = planBeta(
        _problem([(130, 100), (110, 150), (150, 190), (130, 230)], [0]),
        _start((128, 100), (132, 100)),
        profile: _climber(170, 170),
        aspect: _aspect,
      );
      expect(plan.startMatched, isTrue);
      expect(plan.sends, isTrue);
    });

    test('measures the wall from the torso when it is visible', () {
      // Torso of 0.1 image heights on a 175 cm climber:
      // 0.29 * 175 / 0.1 = 507.5 cm per image height.
      final plan = planBeta(
        _problem(_ladder, [0, 1]),
        _start(
          (110, 100),
          (150, 100),
          shoulders: const Keypoint(0.5, 0.6, 0.9),
          hips: const Keypoint(0.5, 0.7, 0.9),
        ),
        profile: _climber(175, 175),
        aspect: _aspect,
      );
      expect(plan.scaleFromBody, isTrue);
      expect(plan.cmPerUnit, closeTo(507.5, 0.01));
      expect(plan.warnings, isEmpty);
    });

    test('ignores an implausible torso measurement', () {
      final plan = planBeta(
        _problem(_ladder, [0, 1]),
        _start(
          (110, 100),
          (150, 100),
          shoulders: const Keypoint(0.5, 0.6, 0.9),
          hips: const Keypoint(0.5, 0.601, 0.9),
        ),
        profile: _climber(175, 175),
        aspect: _aspect,
      );
      expect(plan.scaleFromBody, isFalse);
      expect(plan.cmPerUnit, fallbackFrameHeightCm);
    });

    test('a start on the top hold needs no moves', () {
      final plan = planBeta(
        _problem([(130, 200)], [0]),
        _start((128, 200), (132, 200)),
        profile: _climber(170, 170),
        aspect: _aspect,
      );
      expect(plan.moves, isEmpty);
      expect(betaCues(plan).first, "You're already on the top hold.");
    });
  });

  group('narration', () {
    test('direction words', () {
      expect(direction(0, 40), 'up');
      expect(direction(-30, 40), 'up and to the left');
      expect(direction(30, 40), 'up and to the right');
      expect(direction(40, 2), 'across to the right');
      expect(direction(-5, -40), 'down');
      expect(direction(-40, -20), 'down and to the left');
    });

    test('reaches above the other hand say so', () {
      const move = BetaMove(
        limb: Limb.leftHand,
        kind: MoveKind.reach,
        from: WallPoint(110, 100),
        to: WallPoint(140, 160),
        otherHand: WallPoint(150, 120),
        reachRatio: 0.3,
      );
      expect(moveCue(move), 'Left hand up and to the right to the hold above your right hand.');
    });

    test('long reaches, big moves, the top, feet and the match', () {
      expect(
        moveCue(
          const BetaMove(
            limb: Limb.rightHand,
            kind: MoveKind.reach,
            from: WallPoint(150, 100),
            to: WallPoint(200, 170),
            otherHand: WallPoint(100, 120),
            reachRatio: 0.9,
          ),
        ),
        "Right hand up and to the right to the next hold. It's a long reach.",
      );
      expect(
        moveCue(
          const BetaMove(
            limb: Limb.rightHand,
            kind: MoveKind.bigReach,
            from: WallPoint(150, 100),
            to: WallPoint(150, 300),
            otherHand: WallPoint(100, 100),
          ),
        ),
        'Big move: right hand up to the next hold. Commit to it.',
      );
      expect(
        moveCue(
          const BetaMove(
            limb: Limb.leftHand,
            kind: MoveKind.reach,
            from: WallPoint(110, 250),
            to: WallPoint(130, 330),
            otherHand: WallPoint(150, 280),
            toTop: true,
          ),
        ),
        'Left hand up to the top hold.',
      );
      expect(
        moveCue(
          const BetaMove(
            limb: Limb.rightFoot,
            kind: MoveKind.footHold,
            from: WallPoint(150, 0),
            to: WallPoint(150, 60),
          ),
        ),
        'Right foot up onto the next foothold.',
      );
      expect(
        moveCue(
          const BetaMove(
            limb: Limb.rightHand,
            kind: MoveKind.match,
            from: WallPoint(150, 300),
            to: WallPoint(130, 330),
          ),
        ),
        "Match the top hold with your right hand. That's the send!",
      );
    });

    test('a full plan reads intro, start, then moves without smears', () {
      final plan = planBeta(
        _problem(_ladder, [0, 1]),
        _start((110, 100), (150, 100)),
        profile: _climber(175, 178),
        aspect: _aspect,
      );
      final cues = betaCues(plan);
      expect(
        cues[0],
        startsWith("Here's the beta: ${plan.handMoveCount} hand moves."),
      );
      expect(
        cues[1],
        'Start with your left hand on the left start hold '
        'and your right hand on the right.',
      );
      expect(cues.last, "Match the top hold with your right hand. That's the send!");
      expect(cues.where((c) => c.contains('Smear')), isEmpty);
      final smears = plan.moves.where((m) => m.kind == MoveKind.smear).length;
      expect(cues, hasLength(2 + plan.moves.length - smears));
    });
  });
}
