import 'beta_planner.dart';
import 'beta_tracker.dart';

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
      "Here's the beta: $hands hand ${hands == 1 ? 'move' : 'moves'}."
          '${_cruxSentence(plan)}',
    _startCue(plan),
  ];
  for (var i = 0; i < plan.moves.length; i++) {
    final move = plan.moves[i];
    // Smears are a planner detail (feet on blank wall); calling each one
    // out is noise.
    if (move.kind == MoveKind.smear) continue;
    cues.add(moveCue(move, crux: i == plan.cruxMove));
  }
  return cues;
}

/// " The crux is move 4." when the plan has a crux, else "".
String _cruxSentence(BetaPlan plan) {
  final crux = plan.cruxHandMove;
  return crux == null ? '' : ' The crux is move $crux.';
}

/// Spoken once a problem locks in live mode, before the first step:
/// "Got the red problem: 6 moves. The crux is move 4."
String liveIntro(BetaPlan plan, {String? colorName}) {
  final hands = plan.handMoveCount;
  if (hands == 0) return "You're already on the top hold.";
  final moves = '$hands ${hands == 1 ? 'move' : 'moves'}';
  final got = colorName == null ? 'Got it' : 'Got the $colorName problem';
  return '$got: $moves.${_cruxSentence(plan)}';
}

/// The live cue for one [step]: its foot moves (smears are left out), then
/// the hand move that finishes it. "Left foot up onto the next foothold.
/// Then right hand up to the next hold." A step holding the crux starts
/// with "Crux.".
String stepCue(BetaPlan plan, BetaStep step) {
  final feet = <String>[];
  var crux = false;
  for (final i in step.moveIndices) {
    if (i == plan.cruxMove) crux = true;
    if (i == step.handMoveIndex) continue;
    final move = plan.moves[i];
    if (move.kind == MoveKind.smear) continue;
    feet.add(moveCue(move, live: true));
  }
  final hand = moveCue(plan.moves[step.handMoveIndex], live: true);
  final cue = feet.isEmpty
      ? hand
      : '${feet.join(' ')} Then ${_lowerFirst(hand)}';
  return crux ? 'Crux. $cue' : cue;
}

/// Live cue when the climber goes off-beta and mitbo replans.
const newBetaCue = 'New beta from here.';

/// Live cue when the climber matches the top hold.
const sentCue = 'Nice send!';

/// Live cue when the climber comes off the wall before sending.
const offWallCue = 'Off the wall. Get back on the start holds to go again.';

/// Live cue after the intro when the beta was planned from a tap on the
/// phone: the climber still has to get on the wall.
const getOnStartCue = "Get on the start holds when you're ready.";

/// Live cue when the climber is back on the start holds, before the first
/// step.
const fromStartCue = 'From the start.';

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

/// The spoken cue for one move. A [crux] move is announced as such.
///
/// With [live], cues are spoken as the climber goes, so the finishing
/// match doesn't claim the send before it happens.
String moveCue(BetaMove move, {bool crux = false, bool live = false}) {
  final cue = _moveCue(move, live: live);
  return crux ? 'Crux. $cue' : cue;
}

String _moveCue(BetaMove move, {required bool live}) {
  final side = move.limb.side;
  final otherSide = move.limb.isLeft ? 'right' : 'left';
  switch (move.kind) {
    case MoveKind.match:
      if (live) return 'Match the top hold with your $side hand.';
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
