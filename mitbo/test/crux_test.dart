import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/beta/beta_narration.dart';
import 'package:mitbo/beta/beta_planner.dart';
import 'package:mitbo/beta/crux.dart';
import 'package:mitbo/models/climber_profile.dart';

final _reach = ReachModel(const ClimberProfile(heightCm: 170, wingspanCm: 170));

BetaMove _reachMove({
  Limb limb = Limb.rightHand,
  MoveKind kind = MoveKind.reach,
  WallPoint from = const WallPoint(150, 100),
  required WallPoint to,
  WallPoint otherHand = const WallPoint(110, 110),
  double reachRatio = 0.4,
  double? footY = 0,
}) => BetaMove(
  limb: limb,
  kind: kind,
  from: from,
  to: to,
  otherHand: otherHand,
  reachRatio: reachRatio,
  footY: footY,
);

void main() {
  group('moveDifficulty', () {
    test('a comfortable move scores zero', () {
      // 40 cm up, well within span and reach above the feet.
      final move = _reachMove(to: const WallPoint(150, 140), footY: 40);
      expect(moveDifficulty(move, _reach), 0);
    });

    test('feet, smears and the final match are never hard', () {
      const foot = BetaMove(
        limb: Limb.leftFoot,
        kind: MoveKind.footHold,
        from: WallPoint(100, 0),
        to: WallPoint(100, 100),
      );
      const match = BetaMove(
        limb: Limb.leftHand,
        kind: MoveKind.match,
        from: WallPoint(100, 200),
        to: WallPoint(130, 300),
        reachRatio: 0.99,
      );
      expect(moveDifficulty(foot, _reach), 0);
      expect(moveDifficulty(match, _reach), 0);
    });

    test('a long span scores more than a short one', () {
      final short = _reachMove(to: const WallPoint(150, 160), reachRatio: 0.5);
      final long = _reachMove(to: const WallPoint(150, 160), reachRatio: 0.95);
      expect(
        moveDifficulty(long, _reach),
        greaterThan(moveDifficulty(short, _reach)),
      );
      expect(moveDifficulty(long, _reach), closeTo(0.875, 1e-9));
    });

    test('reaching far above the feet adds difficulty', () {
      final top = _reach.maxReachAboveFoot;
      final low = _reachMove(to: WallPoint(150, 0.5 * top), footY: 0);
      final high = _reachMove(to: WallPoint(150, top), footY: 0);
      expect(moveDifficulty(low, _reach), 0);
      expect(moveDifficulty(high, _reach), greaterThanOrEqualTo(1));
    });

    test('crossing over the other hand adds a little', () {
      // Right hand finishing left of the left hand.
      final cross = _reachMove(
        to: const WallPoint(90, 140),
        otherHand: const WallPoint(110, 110),
      );
      expect(moveDifficulty(cross, _reach), closeTo(0.3, 1e-9));
    });

    test('a big move is always hard', () {
      final big = _reachMove(
        kind: MoveKind.bigReach,
        to: const WallPoint(150, 140),
      );
      expect(moveDifficulty(big, _reach), greaterThanOrEqualTo(1));
    });
  });

  group('findCrux', () {
    test('picks the hardest move above the threshold', () {
      expect(findCrux([0, 0.7, 1.2, 0.9]), 2);
    });

    test('ties go to the earlier move', () {
      expect(findCrux([0.8, 0.8]), 0);
    });

    test('no move hard enough means no crux', () {
      expect(findCrux([0, 0.3, cruxThreshold - 0.01]), isNull);
      expect(findCrux(const []), isNull);
    });
  });

  group('crux cues', () {
    test('the crux move is announced', () {
      final move = _reachMove(to: const WallPoint(150, 160));
      expect(
        moveCue(move, crux: true),
        'Crux. Right hand up to the next hold.',
      );
    });

    test('live match cues do not claim the send early', () {
      const match = BetaMove(
        limb: Limb.leftHand,
        kind: MoveKind.match,
        from: WallPoint(100, 200),
        to: WallPoint(130, 300),
      );
      expect(
        moveCue(match, live: true),
        'Match the top hold with your left hand.',
      );
      expect(moveCue(match), endsWith("That's the send!"));
    });
  });
}
