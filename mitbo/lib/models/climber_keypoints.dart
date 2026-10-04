import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Landmarks ML Kit is less sure than this are actually in frame are ignored.
const minLandmarkLikelihood = 0.5;

/// A body point in normalized, upright image coordinates — the same
/// orientation the pose overlay draws in, before any mirroring.
class Keypoint {
  const Keypoint(this.x, this.y, this.confidence);

  /// 0 at the left edge of the upright image, 1 at the right.
  final double x;

  /// 0 at the top of the upright image, 1 at the bottom.
  final double y;

  /// ML Kit's in-frame likelihood for the landmark(s) this came from, 0–1.
  final double confidence;

  @override
  bool operator ==(Object other) =>
      other is Keypoint &&
      other.x == x &&
      other.y == y &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(x, y, confidence);

  @override
  String toString() => 'Keypoint($x, $y, confidence: $confidence)';
}

/// The points the beta engine reasons about.
enum ClimberPoint { leftHand, rightHand, leftFoot, rightFoot, hipCenter }

/// A climber's hands, feet and hip center, derived from a raw ML Kit pose.
/// A point is null when the landmarks it needs aren't confidently in frame.
class ClimberKeypoints {
  const ClimberKeypoints({
    this.leftHand,
    this.rightHand,
    this.leftFoot,
    this.rightFoot,
    this.hipCenter,
  });

  /// No climber in frame.
  static const none = ClimberKeypoints();

  /// Derives keypoints from [pose], whose landmarks are in the upright space
  /// of an [imageWidth] x [imageHeight] raw image rotated by [rotation].
  ///
  /// Hands sit on the wrist, moved [handNudge] of the way toward the
  /// index/pinky midpoint when both are visible (0 = wrist, 1 = knuckles).
  factory ClimberKeypoints.fromPose(
    Pose pose, {
    required double imageWidth,
    required double imageHeight,
    required InputImageRotation rotation,
    double handNudge = 0.5,
  }) {
    final swap =
        rotation == InputImageRotation.rotation90deg ||
        rotation == InputImageRotation.rotation270deg;
    final width = swap ? imageHeight : imageWidth;
    final height = swap ? imageWidth : imageHeight;

    PoseLandmark? visible(PoseLandmarkType type) {
      final landmark = pose.landmarks[type];
      return landmark != null && landmark.likelihood >= minLandmarkLikelihood
          ? landmark
          : null;
    }

    Keypoint at(double x, double y, double confidence) => Keypoint(
      (x / width).clamp(0.0, 1.0),
      (y / height).clamp(0.0, 1.0),
      confidence,
    );

    Keypoint? hand(
      PoseLandmarkType wristType,
      PoseLandmarkType indexType,
      PoseLandmarkType pinkyType,
    ) {
      final wrist = visible(wristType);
      if (wrist == null) return null;
      final index = visible(indexType);
      final pinky = visible(pinkyType);
      if (index == null || pinky == null) {
        return at(wrist.x, wrist.y, wrist.likelihood);
      }
      final knucklesX = (index.x + pinky.x) / 2;
      final knucklesY = (index.y + pinky.y) / 2;
      return at(
        wrist.x + (knucklesX - wrist.x) * handNudge,
        wrist.y + (knucklesY - wrist.y) * handNudge,
        wrist.likelihood,
      );
    }

    Keypoint? foot(PoseLandmarkType ankleType, PoseLandmarkType toeType) {
      final used = [visible(ankleType), visible(toeType)].nonNulls.toList();
      if (used.isEmpty) return null;
      return at(
        used.map((l) => l.x).reduce((a, b) => a + b) / used.length,
        used.map((l) => l.y).reduce((a, b) => a + b) / used.length,
        used.map((l) => l.likelihood).reduce((a, b) => a < b ? a : b),
      );
    }

    Keypoint? hipCenter() {
      final left = visible(PoseLandmarkType.leftHip);
      final right = visible(PoseLandmarkType.rightHip);
      if (left == null || right == null) return null;
      return at(
        (left.x + right.x) / 2,
        (left.y + right.y) / 2,
        left.likelihood < right.likelihood ? left.likelihood : right.likelihood,
      );
    }

    return ClimberKeypoints(
      leftHand: hand(
        PoseLandmarkType.leftWrist,
        PoseLandmarkType.leftIndex,
        PoseLandmarkType.leftPinky,
      ),
      rightHand: hand(
        PoseLandmarkType.rightWrist,
        PoseLandmarkType.rightIndex,
        PoseLandmarkType.rightPinky,
      ),
      leftFoot: foot(
        PoseLandmarkType.leftAnkle,
        PoseLandmarkType.leftFootIndex,
      ),
      rightFoot: foot(
        PoseLandmarkType.rightAnkle,
        PoseLandmarkType.rightFootIndex,
      ),
      hipCenter: hipCenter(),
    );
  }

  final Keypoint? leftHand;
  final Keypoint? rightHand;
  final Keypoint? leftFoot;
  final Keypoint? rightFoot;
  final Keypoint? hipCenter;

  Keypoint? operator [](ClimberPoint point) => switch (point) {
    ClimberPoint.leftHand => leftHand,
    ClimberPoint.rightHand => rightHand,
    ClimberPoint.leftFoot => leftFoot,
    ClimberPoint.rightFoot => rightFoot,
    ClimberPoint.hipCenter => hipCenter,
  };
}

/// Smooths keypoints across frames with a per-point exponential moving
/// average, so jitter in ML Kit's output doesn't reach the beta engine.
class KeypointSmoother {
  KeypointSmoother({this.alpha = 0.5, this.maxMissingFrames = 5})
    : assert(alpha > 0 && alpha <= 1),
      assert(maxMissingFrames >= 0);

  /// Weight of the newest frame: 1 = no smoothing, closer to 0 = smoother
  /// but laggier.
  final double alpha;

  /// A point missing for more than this many consecutive frames starts
  /// fresh when it reappears, instead of easing in from where it was.
  final int maxMissingFrames;

  final _smoothed = <ClimberPoint, Keypoint>{};
  final _missingFrames = <ClimberPoint, int>{};

  /// Folds [raw] into the running averages and returns the smoothed points.
  /// Points missing from [raw] are null in the result; confidence is always
  /// the current frame's.
  ClimberKeypoints smooth(ClimberKeypoints raw) {
    Keypoint? update(ClimberPoint point) {
      final current = raw[point];
      if (current == null) {
        final missing = (_missingFrames[point] ?? 0) + 1;
        _missingFrames[point] = missing;
        if (missing > maxMissingFrames) _smoothed.remove(point);
        return null;
      }
      _missingFrames[point] = 0;
      final previous = _smoothed[point];
      final next = previous == null
          ? current
          : Keypoint(
              alpha * current.x + (1 - alpha) * previous.x,
              alpha * current.y + (1 - alpha) * previous.y,
              current.confidence,
            );
      return _smoothed[point] = next;
    }

    return ClimberKeypoints(
      leftHand: update(ClimberPoint.leftHand),
      rightHand: update(ClimberPoint.rightHand),
      leftFoot: update(ClimberPoint.leftFoot),
      rightFoot: update(ClimberPoint.rightFoot),
      hipCenter: update(ClimberPoint.hipCenter),
    );
  }

  /// Forgets all history, e.g. when the camera restarts.
  void reset() {
    _smoothed.clear();
    _missingFrames.clear();
  }
}
