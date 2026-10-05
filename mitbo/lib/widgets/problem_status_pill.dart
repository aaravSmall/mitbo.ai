import 'package:flutter/material.dart';

import '../beta/beta_planner.dart';
import '../beta/beta_tracker.dart';
import '../state/problem_session.dart';
import '../vision/hold_color.dart';
import '../vision/problem_detector.dart';

/// What to tell the climber in each detection phase. Once locked, the
/// climb's progress ([climbState], [movesDone] of [totalMoves]) is shown
/// when given.
String problemStatusText(
  ProblemPhase phase, {
  DetectedProblem? problem,
  BetaPlan? beta,
  String? failureReason,
  ClimbState? climbState,
  int movesDone = 0,
  int? totalMoves,
}) {
  switch (phase) {
    case ProblemPhase.scanningWall:
      return 'Step out of frame to scan the wall';
    case ProblemPhase.ready:
      return 'Ready — get on the start holds';
    case ProblemPhase.detecting:
      return 'Reading the problem…';
    case ProblemPhase.confirming:
      if (problem == null) return 'Are these the right holds?';
      final count = problem.holds.length;
      return '${_problemName(problem)} · $count '
          '${count == 1 ? 'hold' : 'holds'} — right?';
    case ProblemPhase.locked:
      if (problem == null) return 'Problem locked';
      final count = problem.holds.length;
      final color = _problemName(problem);
      final holds = '$color · $count ${count == 1 ? 'hold' : 'holds'}';
      switch (climbState) {
        case ClimbState.sent:
          return '$color · sent!';
        case ClimbState.offWall:
          return 'Get back on the start holds to go again';
        case ClimbState.replanning:
          return 'Working out new beta…';
        case ClimbState.climbing:
        case null:
          break;
      }
      if (beta == null) return holds;
      final moves = totalMoves ?? beta.handMoveCount;
      if (climbState == ClimbState.climbing && movesDone > 0) {
        return '$holds · move ${movesDone + 1} of $moves';
      }
      return '$holds · $moves ${moves == 1 ? 'move' : 'moves'}';
    case ProblemPhase.failed:
      return failureReason ?? "Couldn't read the problem";
  }
}

/// "Blue problem", or "Your problem" when the color was never read.
String _problemName(DetectedProblem problem) {
  if (identical(problem.color, HoldColor.unknown)) return 'Your problem';
  final name = problem.color.name;
  return '${name[0].toUpperCase()}${name.substring(1)} problem';
}

/// A small status bar over the camera preview showing problem detection
/// progress, with a reset button once a problem is locked or has failed,
/// and a replay/stop button for the spoken beta.
///
/// Once holds are found automatically it asks the user to confirm them
/// ([onConfirm]) or fix them by hand ([onMarkHolds]); [onMarkHolds] is also
/// the fallback offered when detection fails or the wall scan stalls.
class ProblemStatusPill extends StatelessWidget {
  const ProblemStatusPill({
    super.key,
    required this.phase,
    this.problem,
    this.beta,
    this.failureReason,
    this.speaking = false,
    this.onReset,
    this.onConfirm,
    this.onMarkHolds,
    this.onReplay,
    this.onStopSpeaking,
    this.climbState,
    this.movesDone = 0,
    this.totalMoves,
    this.replayTooltip = 'Replay beta',
  });

  final ProblemPhase phase;
  final DetectedProblem? problem;
  final BetaPlan? beta;
  final String? failureReason;

  /// Whether the beta is being read aloud right now.
  final bool speaking;
  final VoidCallback? onReset;

  /// Accepts automatically detected holds.
  final VoidCallback? onConfirm;

  /// Opens manual hold marking.
  final VoidCallback? onMarkHolds;
  final VoidCallback? onReplay;
  final VoidCallback? onStopSpeaking;

  /// Live climb progress, from the coach.
  final ClimbState? climbState;
  final int movesDone;
  final int? totalMoves;

  final String replayTooltip;

  @override
  Widget build(BuildContext context) {
    final busy =
        phase == ProblemPhase.scanningWall || phase == ProblemPhase.detecting;
    final canReset =
        onReset != null &&
        (phase == ProblemPhase.locked || phase == ProblemPhase.failed);
    final canReplay =
        phase == ProblemPhase.locked &&
        beta != null &&
        (speaking ? onStopSpeaking : onReplay) != null;
    final canConfirm = onConfirm != null && phase == ProblemPhase.confirming;
    final markLabel = switch (phase) {
      ProblemPhase.confirming => 'Fix',
      ProblemPhase.failed || ProblemPhase.scanningWall => 'Mark holds',
      _ => null,
    };
    final canMark = onMarkHolds != null && markLabel != null;
    final hasActions = canReset || canReplay || canConfirm || canMark;
    final icon = switch (phase) {
      ProblemPhase.ready => Icons.back_hand_outlined,
      ProblemPhase.confirming => Icons.help_outline,
      ProblemPhase.locked => Icons.check_circle_outline,
      ProblemPhase.failed => Icons.error_outline,
      _ => null,
    };

    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      shape: const StadiumBorder(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 6, hasActions ? 4 : 16, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            else if (icon != null)
              Icon(icon, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                problemStatusText(
                  phase,
                  problem: problem,
                  beta: beta,
                  failureReason: failureReason,
                  climbState: climbState,
                  movesDone: movesDone,
                  totalMoves: totalMoves,
                ),
                style: const TextStyle(color: Colors.white),
              ),
            ),
            if (canReplay)
              IconButton(
                onPressed: speaking ? onStopSpeaking : onReplay,
                tooltip: speaking ? 'Stop' : replayTooltip,
                icon: Icon(
                  speaking ? Icons.stop_circle_outlined : Icons.volume_up,
                  color: Colors.white,
                ),
              ),
            if (canConfirm) ...[
              const SizedBox(width: 4),
              TextButton(
                onPressed: onConfirm,
                child: const Text('Looks right'),
              ),
            ],
            if (canMark) ...[
              const SizedBox(width: 4),
              TextButton(onPressed: onMarkHolds, child: Text(markLabel)),
            ],
            if (canReset) ...[
              const SizedBox(width: 4),
              TextButton(onPressed: onReset, child: const Text('Reset')),
            ],
          ],
        ),
      ),
    );
  }
}
