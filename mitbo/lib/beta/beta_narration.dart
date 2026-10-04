import 'beta_planner.dart';

/// Turns a [BetaPlan] into spoken cues, in order: an intro, the start
/// position, then one cue per move.
///
/// The planner decides every move; this only phrases them ("Left hand up
/// to the hold above your right hand."). Plain templates keep it offline
/// and predictable; an LLM could replace this layer later without touching
/// the planner.
List<String> betaCues(BetaPlan plan) {
  if (plan.holds.isEmpty) return const [];
  final hands = plan.handMoveCount;
  final cues = <String>[
    if (hands == 0)
      "You're already on the top hold."
    else
      "Here's the beta: $hands hand ${hands == 1 ? 'move' : 'moves'}.",
    _startCue(plan),
  ];
  for (final move in plan.moves) {
    // Smears are a planner detail (feet on blank wall); calling each one
    // out is noise.
    if (move.kind == MoveKind.smear) continue;
    cues.add(moveCue(move));
  }
  return cues;
}

String _startCue(BetaPlan plan) {
  if (plan.startMatched) return 'Start matched on the start hold.';
  final left = plan.holds[plan.leftStart];
  final right = plan.holds[plan.rightStart];
  if (left.x > right.x + 10) {
    return 'Start crossed: left hand on the right start hold, '
        'right hand on the left.';
  }
  return 'Start with your left hand on the left start hold '
      'and your right hand on the right.';
}

/// The spoken cue for one move.
String moveCue(BetaMove move) {
  final side = move.limb.side;
  final otherSide = move.limb.isLeft ? 'right' : 'left';
  switch (move.kind) {
    case MoveKind.match:
      return 'Match the top hold with your $side hand. '
          "That's the send!";
    case MoveKind.footHold:
      return '${_capitalize(side)} foot ${direction(move.dx, move.dy)} '
          'onto the next foothold.';
    case MoveKind.smear:
      return 'Smear your $side foot higher on the wall.';
    case MoveKind.reach:
    case MoveKind.bigReach:
      final target = _targetPhrase(move, otherSide);
      final cue =
          '${_capitalize(side)} hand ${direction(move.dx, move.dy)} '
          'to $target.';
      if (move.kind == MoveKind.bigReach) {
        return 'Big move: ${_lowerFirst(cue)} Commit to it.';
      }
      if (move.reachRatio > 0.85) return "$cue It's a long reach.";
      return cue;
  }
}

String _targetPhrase(BetaMove move, String otherSide) {
  if (move.toTop) return 'the top hold';
  final other = move.otherHand;
  if (other != null &&
      (move.to.x - other.x).abs() < 25 &&
      move.to.y > other.y + 10) {
    return 'the hold above your $otherSide hand';
  }
  return 'the next hold';
}

/// Spoken direction for a move of ([dx], [dy]) centimeters (y up).
String direction(double dx, double dy) {
  final side = dx < 0 ? 'left' : 'right';
  if (dy > 10) {
    return dx.abs() < 0.5 * dy ? 'up' : 'up and to the $side';
  }
  if (dy > -10) return 'across to the $side';
  return dx.abs() < 0.5 * -dy ? 'down' : 'down and to the $side';
}

String _capitalize(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _lowerFirst(String s) =>
    s.isEmpty ? s : '${s[0].toLowerCase()}${s.substring(1)}';
