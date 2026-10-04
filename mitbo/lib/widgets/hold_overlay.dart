import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../beta/beta_planner.dart';
import '../state/problem_session.dart';
import '../vision/hold_segmenter.dart';
import 'pose_mapping.dart';

/// Outlines the locked problem's holds over the camera preview, marking
/// start holds "S" and the top hold "T", and numbering the hand moves of
/// the beta in order ("1L", "2R", ...).
///
/// Must be sized to exactly cover the preview (like `PoseOverlay`).
class HoldOverlay extends StatelessWidget {
  const HoldOverlay({super.key, required this.session});

  final ProblemSession session;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: HoldPainter(session: session),
        size: Size.infinite,
      ),
    );
  }
}

/// Maps a hold's normalized bounding box onto a preview of [previewSize],
/// for a snapshot of [imageSize] (already upright) shown with [fit].
Rect holdRectOnPreview(
  DetectedHold hold, {
  required Size imageSize,
  required Size previewSize,
  PreviewFit fit = PreviewFit.cover,
}) {
  Offset map(double nx, double ny) => mapToPreview(
    Offset(nx * imageSize.width, ny * imageSize.height),
    imageSize: imageSize,
    rotation: InputImageRotation.rotation0deg,
    previewSize: previewSize,
    fit: fit,
  );
  return Rect.fromPoints(
    map(hold.left, hold.top),
    map(hold.right, hold.bottom),
  );
}

class HoldPainter extends CustomPainter {
  HoldPainter({required this.session}) : super(repaint: session);

  final ProblemSession session;

  // White line on a dark halo stays visible on any hold color.
  static const _lineColor = Colors.white;
  static const _haloColor = Colors.black54;

  @override
  void paint(Canvas canvas, Size size) {
    final problem = session.problem;
    final imageSize = session.problemImageSize;
    if (problem == null || imageSize == null) return;

    final top = problem.topHold;
    final steps = betaStepLabels(session.beta);
    for (var i = 0; i < problem.holds.length; i++) {
      final hold = problem.holds[i];
      final isStart = problem.startHoldIndices.contains(i);
      final isTop = identical(hold, top) && !isStart;
      final rect = holdRectOnPreview(
        hold,
        imageSize: imageSize,
        previewSize: size,
      ).inflate(4);
      final outline = RRect.fromRectAndRadius(rect, const Radius.circular(6));
      final width = isStart || isTop ? 4.0 : 2.5;

      canvas.drawRRect(
        outline,
        Paint()
          ..color = _haloColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = width + 2,
      );
      canvas.drawRRect(
        outline,
        Paint()
          ..color = _lineColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = width,
      );
      if (isStart) _label(canvas, 'S', rect);
      if (isTop) _label(canvas, 'T', rect);
      final step = steps[i];
      if (step != null) _label(canvas, step, rect, below: true);
    }
  }

  static void _label(
    Canvas canvas,
    String text,
    Rect rect, {
    bool below = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Colors.black,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const padding = 3.0;
    final badge = Rect.fromLTWH(
      rect.left - padding,
      below ? rect.bottom + padding : rect.top - painter.height - padding * 2,
      painter.width + padding * 2,
      painter.height + padding,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(badge, const Radius.circular(4)),
      Paint()..color = _lineColor,
    );
    painter.paint(canvas, badge.topLeft + const Offset(padding, padding / 2));
    painter.dispose();
  }

  @override
  bool shouldRepaint(HoldPainter oldDelegate) => oldDelegate.session != session;
}

/// Labels for the holds hand moves land on, keyed by hold index: the move
/// number and hand, e.g. "1L", or "5R 6L" for a hold used twice.
Map<int, String> betaStepLabels(BetaPlan? beta) {
  final labels = <int, String>{};
  if (beta == null) return labels;
  var step = 0;
  for (final move in beta.moves) {
    if (!move.limb.isHand) continue;
    step++;
    final hold = move.toHold;
    if (hold == null) continue;
    final label = '$step${move.limb.isLeft ? 'L' : 'R'}';
    labels[hold] = labels.containsKey(hold) ? '${labels[hold]} $label' : label;
  }
  return labels;
}
