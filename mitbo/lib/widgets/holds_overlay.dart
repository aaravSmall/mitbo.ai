import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../holds/hold.dart';
import '../holds/hold_geometry.dart';
import '../holds/problem.dart';
import 'pose_mapping.dart';

/// Draws a problem's holds as outlined circles over the camera preview.
///
/// Like [PoseOverlay], it must exactly cover the preview so holds line up
/// with the wall (and with the skeleton drawn on top).
class HoldsOverlay extends StatelessWidget {
  const HoldsOverlay({super.key, required this.problem});

  final Problem problem;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: HoldsPainter(
          holds: problem.holds,
          frameSize: problem.frameSize,
          color: problem.color,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// Paints [holds] marked on a frame of [frameSize] (upright pixels) into a
/// preview, using the same mapping as the pose overlay.
class HoldsPainter extends CustomPainter {
  HoldsPainter({
    required this.holds,
    required this.frameSize,
    this.color,
    this.selectedId,
  });

  final List<Hold> holds;
  final Size frameSize;

  /// The problem color; holds are outlined in white until one is picked.
  final Color? color;

  /// Highlighted hold (on the marking screen).
  final String? selectedId;

  @override
  void paint(Canvas canvas, Size size) {
    if (holds.isEmpty || size.isEmpty) return;
    // Holds marked in one orientation don't match a preview in the other.
    if ((frameSize.width > frameSize.height) != (size.width > size.height)) {
      return;
    }
    final transform = PreviewTransform(
      uprightSize: frameSize,
      previewSize: size,
    );
    final shadow = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5;

    for (final hold in holds) {
      final center = normalizedToPreview(
        hold.center,
        imageSize: frameSize,
        rotation: InputImageRotation.rotation0deg,
        previewSize: size,
      );
      final radius = holdRadiusPixels(hold.radius, frameSize) * transform.scale;
      final selected = hold.id == selectedId;
      final outline = Paint()
        ..color = color ?? Colors.white
        ..style = PaintingStyle.stroke
        // Auto-detected holds are drawn lighter than ones the user marked.
        ..strokeWidth = hold.source == HoldSource.manual ? 2.5 : 1.5;

      if (selected) {
        canvas.drawCircle(
          center,
          radius,
          Paint()..color = (color ?? Colors.white).withValues(alpha: 0.25),
        );
        outline.strokeWidth = 3.5;
      }
      canvas.drawCircle(center, radius, shadow);
      canvas.drawCircle(center, radius, outline);
    }
  }

  @override
  bool shouldRepaint(HoldsPainter oldDelegate) =>
      oldDelegate.holds != holds ||
      oldDelegate.frameSize != frameSize ||
      oldDelegate.color != color ||
      oldDelegate.selectedId != selectedId;
}
