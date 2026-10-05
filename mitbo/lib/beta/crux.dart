import 'beta_planner.dart';

/// A move scoring at least this is hard enough to call out as the crux.
/// Below it, the problem has no single standout move and none is flagged.
const cruxThreshold = 0.6;

/// How hard a move is for this climber, from geometry alone: 0 for a
/// comfortable move, rising past 1 for long, high or committing ones.
///
/// Only hand moves score; feet and the final match are treated as easy.
/// Factors, each 0–1 unless noted:
/// - *span:* hand-to-hand distance past 60% of the climber's max span,
/// - *height:* how far above the higher foot the hand lands, past 75% of
///   the climber's max reach from there,
/// - *gain:* height gained past 1.1× the ideal gain per move (weighted ½),
/// - *cross:* reaching across the other hand (+0.3),
/// - *big move:* nothing was comfortably in reach (+1).
double moveDifficulty(BetaMove move, ReachModel reach) {
  if (!move.limb.isHand || move.kind == MoveKind.match) return 0;
  var score = _ramp(move.reachRatio, 0.6, 1.0);
  final footY = move.footY;
  if (footY != null) {
    score += _ramp((move.to.y - footY) / reach.maxReachAboveFoot, 0.75, 1.0);
  }
  score += 0.5 * _ramp(move.dy / reach.idealGain, 1.1, 1.6);
  final other = move.otherHand;
  if (other != null) {
    final crossing = move.limb.isLeft
        ? move.to.x - other.x
        : other.x - move.to.x;
    if (crossing > 5) score += 0.3;
  }
  if (move.kind == MoveKind.bigReach) score += 1;
  return score;
}

/// Index into [difficulties] of the crux: the hardest move, if it reaches
/// [threshold]. Ties go to the earlier move.
int? findCrux(List<double> difficulties, {double threshold = cruxThreshold}) {
  int? best;
  for (var i = 0; i < difficulties.length; i++) {
    if (difficulties[i] < threshold) continue;
    if (best == null || difficulties[i] > difficulties[best]) best = i;
  }
  return best;
}

double _ramp(double value, double low, double high) =>
    ((value - low) / (high - low)).clamp(0.0, 1.0).toDouble();
