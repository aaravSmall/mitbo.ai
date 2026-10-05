import 'package:flutter/material.dart';

import '../beta/beta_planner.dart';
import '../beta/beta_tracker.dart';
import '../state/problem_session.dart';
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
    case ProblemPhase.locked:
      if (problem == null) return 'Problem locked';
      final name = problem.color.name;
      final count = problem.holds.length;
      final color = '${name[0].toUpperCase()}${name.substring(1)}';
      final holds = '$color problem · $count ${count == 1 ? 'hold' : 'holds'}';
      switch (climbState) {
        case ClimbState.sent:
          return '$color problem · sent!';
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

/// A small status bar over the camera preview showing problem detection
/// progress, with a reset button once a problem is locked or has failed,
/// and a replay/stop button for the spoken beta.
class ProblemStatusPill extends StatelessWidget {
  const ProblemStatusPill({
    super.key,
    required this.phase,
    this.problem,
    this.beta,
    this.failureReason,
    this.speaking = false,
    this.onReset,
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
    final icon = switch (phase) {
      ProblemPhase.ready => Icons.back_hand_outlined,
      ProblemPhase.locked => Icons.check_circle_outline,
      ProblemPhase.failed => Icons.error_outline,
      _ => null,
    };

    return Material(
      color: Colors.black.withValues(alpha: 0.7),
      shape: const StadiumBorder(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 6, canReset || canReplay ? 4 : 16, 6),
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
