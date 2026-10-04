import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../models/climber_keypoints.dart';
import '../services/pose_service.dart';
import 'pose_mapping.dart';

/// Draws the latest detected pose as a skeleton over the camera preview.
///
/// Must be sized to exactly cover the preview (e.g. passed as
/// `CameraPreview.child`) so landmark coordinates line up with the body.
class PoseOverlay extends StatelessWidget {
  const PoseOverlay({
    super.key,
    required this.frames,
    this.mirrored = false,
    this.showKeypoints = false,
  });

  final ValueListenable<PoseFrame?> frames;

  /// Flip horizontally, for a mirrored preview. The back camera isn't.
  final bool mirrored;

  /// Also draw the smoothed [ClimberKeypoints] (debug view).
  final bool showKeypoints;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: PosePainter(
          frames: frames,
          mirrored: mirrored,
          showKeypoints: showKeypoints,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  PosePainter({
    required this.frames,
    required this.mirrored,
    this.showKeypoints = false,
  }) : super(repaint: frames);

  final ValueListenable<PoseFrame?> frames;
  final bool mirrored;
  final bool showKeypoints;

  static const _bones = [
    // Torso.
    (PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder),
    (PoseLandmarkType.leftHip, PoseLandmarkType.rightHip),
    (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip),
    (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip),
    // Arms.
    (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow),
    (PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist),
    (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow),
    (PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist),
    // Legs.
    (PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee),
    (PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle),
    (PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee),
    (PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle),
  ];

  static const _joints = [
    PoseLandmarkType.leftShoulder,
    PoseLandmarkType.rightShoulder,
    PoseLandmarkType.leftElbow,
    PoseLandmarkType.rightElbow,
    PoseLandmarkType.leftKnee,
    PoseLandmarkType.rightKnee,
  ];

  static const _handColor = Colors.amber;
  static const _footColor = Colors.cyanAccent;
  static const _hipColor = Colors.pinkAccent;

  // The points beta is built around get bigger, distinctly colored markers.
  static const _keyPoints = {
    PoseLandmarkType.leftWrist: _handColor,
    PoseLandmarkType.rightWrist: _handColor,
    PoseLandmarkType.leftAnkle: _footColor,
    PoseLandmarkType.rightAnkle: _footColor,
    PoseLandmarkType.leftHip: _hipColor,
    PoseLandmarkType.rightHip: _hipColor,
  };

  static const _climberPointStyles = {
    ClimberPoint.leftHand: ('LH', _handColor),
    ClimberPoint.rightHand: ('RH', _handColor),
    ClimberPoint.leftFoot: ('LF', _footColor),
    ClimberPoint.rightFoot: ('RF', _footColor),
    ClimberPoint.hipCenter: ('HIP', _hipColor),
    ClimberPoint.shoulderCenter: ('SH', _hipColor),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final frame = frames.value;
    final pose = frame?.pose;
    if (frame == null || pose == null) return;

    Offset? pointFor(PoseLandmarkType type) {
      final landmark = pose.landmarks[type];
      if (landmark == null || landmark.likelihood < minLandmarkLikelihood) {
        return null;
      }
      return mapToPreview(
        Offset(landmark.x, landmark.y),
        imageSize: frame.imageSize,
        rotation: frame.rotation,
        previewSize: size,
        mirrored: mirrored,
      );
    }

    final bonePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    for (final (from, to) in _bones) {
      final a = pointFor(from);
      final b = pointFor(to);
      if (a != null && b != null) canvas.drawLine(a, b, bonePaint);
    }

    final jointPaint = Paint()..color = Colors.white;
    for (final type in _joints) {
      final p = pointFor(type);
      if (p != null) canvas.drawCircle(p, 4, jointPaint);
    }

    final outline = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final MapEntry(key: type, value: color) in _keyPoints.entries) {
      final p = pointFor(type);
      if (p == null) continue;
      canvas.drawCircle(p, 9, Paint()..color = color);
      canvas.drawCircle(p, 9, outline);
    }

    if (showKeypoints) _paintKeypoints(canvas, size, frame);
  }

  /// Smoothed keypoints: larger, translucent, labeled, with confidence —
  /// so the gap to the raw markers underneath is visible.
  void _paintKeypoints(Canvas canvas, Size size, PoseFrame frame) {
    final upright = uprightImageSize(frame.imageSize, frame.rotation);
    const radius = 16.0;
    final ring = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (final MapEntry(key: point, value: (label, color))
        in _climberPointStyles.entries) {
      final keypoint = frame.keypoints[point];
      if (keypoint == null) continue;
      final center = mapToPreview(
        Offset(keypoint.x * upright.width, keypoint.y * upright.height),
        imageSize: frame.imageSize,
        rotation: frame.rotation,
        previewSize: size,
        mirrored: mirrored,
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = color.withValues(alpha: 0.45),
      );
      canvas.drawCircle(center, radius, ring);
      _drawText(
        canvas,
        label,
        center,
        const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      );
      _drawText(
        canvas,
        keypoint.confidence.toStringAsFixed(2),
        center + const Offset(radius + 14, 0),
        const TextStyle(
          color: Colors.white,
          fontSize: 10,
          backgroundColor: Colors.black54,
        ),
      );
    }
  }

  static void _drawText(
    Canvas canvas,
    String text,
    Offset center,
    TextStyle style,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(PosePainter oldDelegate) =>
      oldDelegate.frames != frames ||
      oldDelegate.mirrored != mirrored ||
      oldDelegate.showKeypoints != showKeypoints;
}
