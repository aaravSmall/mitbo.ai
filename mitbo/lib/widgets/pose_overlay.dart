import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../services/pose_service.dart';
import 'pose_mapping.dart';

/// Landmarks ML Kit is less sure than this are actually in frame are hidden.
const minLandmarkLikelihood = 0.5;

/// Draws the latest detected pose as a skeleton over the camera preview.
///
/// Must be sized to exactly cover the preview (e.g. passed as
/// `CameraPreview.child`) so landmark coordinates line up with the body.
class PoseOverlay extends StatelessWidget {
  const PoseOverlay({super.key, required this.frames, this.mirrored = false});

  final ValueListenable<PoseFrame?> frames;

  /// Flip horizontally, for a mirrored preview. The back camera isn't.
  final bool mirrored;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: PosePainter(frames: frames, mirrored: mirrored),
        size: Size.infinite,
      ),
    );
  }
}

class PosePainter extends CustomPainter {
  PosePainter({required this.frames, required this.mirrored})
    : super(repaint: frames);

  final ValueListenable<PoseFrame?> frames;
  final bool mirrored;

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

  // The points beta is built around get bigger, distinctly colored markers.
  static const _keyPoints = {
    PoseLandmarkType.leftWrist: Colors.amber,
    PoseLandmarkType.rightWrist: Colors.amber,
    PoseLandmarkType.leftAnkle: Colors.cyanAccent,
    PoseLandmarkType.rightAnkle: Colors.cyanAccent,
    PoseLandmarkType.leftHip: Colors.pinkAccent,
    PoseLandmarkType.rightHip: Colors.pinkAccent,
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
  }

  @override
  bool shouldRepaint(PosePainter oldDelegate) =>
      oldDelegate.frames != frames || oldDelegate.mirrored != mirrored;
}
