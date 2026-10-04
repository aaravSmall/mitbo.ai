import 'package:flutter/material.dart';

import '../state/problem_session.dart';
import '../vision/problem_detector.dart';

/// What to tell the climber in each detection phase.
String problemStatusText(
  ProblemPhase phase, {
  DetectedProblem? problem,
  String? failureReason,
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
      return '$color problem · $count ${count == 1 ? 'hold' : 'holds'}';
    case ProblemPhase.failed:
      return failureReason ?? "Couldn't read the problem";
  }
}

/// A small status bar over the camera preview showing problem detection
/// progress, with a reset button once a problem is locked or has failed.
class ProblemStatusPill extends StatelessWidget {
  const ProblemStatusPill({
    super.key,
    required this.phase,
    this.problem,
    this.failureReason,
    this.onReset,
  });

  final ProblemPhase phase;
  final DetectedProblem? problem;
  final String? failureReason;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final busy =
        phase == ProblemPhase.scanningWall || phase == ProblemPhase.detecting;
    final canReset =
        onReset != null &&
        (phase == ProblemPhase.locked || phase == ProblemPhase.failed);
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
        padding: EdgeInsets.fromLTRB(16, 6, canReset ? 4 : 16, 6),
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
                  failureReason: failureReason,
                ),
                style: const TextStyle(color: Colors.white),
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
