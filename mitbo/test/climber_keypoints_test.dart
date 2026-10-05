import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/models/climber_keypoints.dart';

/// Builds a pose from (x, y, likelihood) triples.
Pose _pose(Map<PoseLandmarkType, (double, double, double)> points) => Pose(
  landmarks: {
    for (final MapEntry(key: type, value: (x, y, likelihood)) in points.entries)
      type: PoseLandmark(type: type, x: x, y: y, z: 0, likelihood: likelihood),
  },
);

/// Keypoints from a 100x100 upright image, so normalized = pixels / 100.
ClimberKeypoints _keypoints(
  Map<PoseLandmarkType, (double, double, double)> points, {
  double handNudge = 0.5,
}) => ClimberKeypoints.fromPose(
  _pose(points),
  imageWidth: 100,
  imageHeight: 100,
  rotation: InputImageRotation.rotation0deg,
  handNudge: handNudge,
);

Matcher _at(double x, double y, double confidence) => isA<Keypoint>()
    .having((k) => k.x, 'x', closeTo(x, 1e-9))
    .having((k) => k.y, 'y', closeTo(y, 1e-9))
    .having((k) => k.confidence, 'confidence', closeTo(confidence, 1e-9));

void main() {
  group('normalization', () {
    test('divides by the upright image size', () {
      final keypoints = ClimberKeypoints.fromPose(
        _pose({PoseLandmarkType.leftWrist: (200, 75, 0.9)}),
        imageWidth: 400,
        imageHeight: 300,
        rotation: InputImageRotation.rotation0deg,
      );
      expect(keypoints.leftHand, _at(0.5, 0.25, 0.9));
    });

    test('swaps width and height for 90 and 270 degrees', () {
      for (final rotation in [
        InputImageRotation.rotation90deg,
        InputImageRotation.rotation270deg,
      ]) {
        // Raw 400x300 is upright 300x400.
        final keypoints = ClimberKeypoints.fromPose(
          _pose({PoseLandmarkType.leftWrist: (150, 100, 0.9)}),
          imageWidth: 400,
          imageHeight: 300,
          rotation: rotation,
        );
        expect(keypoints.leftHand, _at(0.5, 0.25, 0.9));
      }
    });

    test('clamps landmarks just outside the frame to 0..1', () {
      final keypoints = _keypoints({
        PoseLandmarkType.rightWrist: (-5, 104, 0.9),
      });
      expect(keypoints.rightHand, _at(0, 1, 0.9));
    });
  });

  group('hands', () {
    test('nudge the wrist toward the index/pinky midpoint', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftWrist: (10, 10, 0.9),
        PoseLandmarkType.leftIndex: (30, 10, 0.8),
        PoseLandmarkType.leftPinky: (30, 30, 0.8),
      });
      // Knuckle midpoint (30, 20); halfway there from (10, 10).
      expect(keypoints.leftHand, _at(0.2, 0.15, 0.9));
    });

    test('nudge amount is configurable', () {
      final keypoints = _keypoints({
        PoseLandmarkType.rightWrist: (10, 10, 0.9),
        PoseLandmarkType.rightIndex: (30, 10, 0.8),
        PoseLandmarkType.rightPinky: (30, 30, 0.8),
      }, handNudge: 0.25);
      expect(keypoints.rightHand, _at(0.15, 0.125, 0.9));
    });

    test('stay on the wrist unless both index and pinky are visible', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftWrist: (10, 10, 0.9),
        PoseLandmarkType.leftIndex: (30, 10, 0.8),
        PoseLandmarkType.leftPinky: (30, 30, 0.2),
        PoseLandmarkType.rightWrist: (50, 50, 0.7),
        PoseLandmarkType.rightIndex: (70, 50, 0.8),
      });
      expect(keypoints.leftHand, _at(0.1, 0.1, 0.9));
      expect(keypoints.rightHand, _at(0.5, 0.5, 0.7));
    });

    test('are null when the wrist is not confidently in frame', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftWrist: (10, 10, 0.3),
        PoseLandmarkType.leftIndex: (30, 10, 0.9),
        PoseLandmarkType.leftPinky: (30, 30, 0.9),
      });
      expect(keypoints.leftHand, isNull);
      expect(keypoints.rightHand, isNull);
    });
  });

  group('feet', () {
    test('average the ankle and foot index, with the lower confidence', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftAnkle: (20, 80, 0.9),
        PoseLandmarkType.leftFootIndex: (30, 90, 0.6),
      });
      expect(keypoints.leftFoot, _at(0.25, 0.85, 0.6));
    });

    test('fall back to whichever of ankle or foot index is visible', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftAnkle: (20, 80, 0.9),
        PoseLandmarkType.leftFootIndex: (30, 90, 0.1),
        PoseLandmarkType.rightFootIndex: (60, 90, 0.7),
      });
      expect(keypoints.leftFoot, _at(0.2, 0.8, 0.9));
      expect(keypoints.rightFoot, _at(0.6, 0.9, 0.7));
    });

    test('are null when neither is visible', () {
      final keypoints = _keypoints({
        PoseLandmarkType.rightAnkle: (20, 80, 0.4),
      });
      expect(keypoints.leftFoot, isNull);
      expect(keypoints.rightFoot, isNull);
    });
  });

  group('hipCenter', () {
    test('is the midpoint of the hips, with the lower confidence', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftHip: (40, 50, 0.95),
        PoseLandmarkType.rightHip: (60, 54, 0.7),
      });
      expect(keypoints.hipCenter, _at(0.5, 0.52, 0.7));
    });

    test('is null if either hip is below the likelihood threshold', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftHip: (40, 50, 0.95),
        PoseLandmarkType.rightHip: (60, 54, 0.49),
      });
      expect(keypoints.hipCenter, isNull);
    });
  });

  group('shoulderCenter', () {
    test('is the midpoint of the shoulders, with the lower confidence', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftShoulder: (40, 30, 0.8),
        PoseLandmarkType.rightShoulder: (60, 34, 0.9),
      });
      expect(keypoints.shoulderCenter, _at(0.5, 0.32, 0.8));
    });

    test('is null if a shoulder is hidden', () {
      final keypoints = _keypoints({
        PoseLandmarkType.leftShoulder: (40, 30, 0.8),
      });
      expect(keypoints.shoulderCenter, isNull);
    });
  });

  test('likelihood exactly at the threshold counts as visible', () {
    final keypoints = _keypoints({
      PoseLandmarkType.leftWrist: (10, 10, minLandmarkLikelihood),
      PoseLandmarkType.rightWrist: (10, 10, minLandmarkLikelihood - 0.01),
    });
    expect(keypoints.leftHand, isNotNull);
    expect(keypoints.rightHand, isNull);
  });

  group('KeypointSmoother', () {
    ClimberKeypoints hipAt(double x, double y, [double confidence = 0.9]) =>
        ClimberKeypoints(hipCenter: Keypoint(x, y, confidence));

    test('passes the first sighting through unchanged', () {
      final smoother = KeypointSmoother();
      expect(smoother.smooth(hipAt(0.2, 0.4)).hipCenter, _at(0.2, 0.4, 0.9));
    });

    test('blends new positions with alpha, keeping current confidence', () {
      final smoother = KeypointSmoother(alpha: 0.5);
      smoother.smooth(hipAt(0.2, 0.2));
      expect(
        smoother.smooth(hipAt(0.4, 0.6, 0.7)).hipCenter,
        _at(0.3, 0.4, 0.7),
      );
      expect(smoother.smooth(hipAt(0.4, 0.6)).hipCenter, _at(0.35, 0.5, 0.9));
    });

    test('uses the configured alpha', () {
      final smoother = KeypointSmoother(alpha: 0.25);
      smoother.smooth(hipAt(0, 0));
      expect(smoother.smooth(hipAt(1, 0.4)).hipCenter, _at(0.25, 0.1, 0.9));
    });

    test('smooths each point independently', () {
      final smoother = KeypointSmoother(alpha: 0.5);
      smoother.smooth(
        const ClimberKeypoints(
          leftHand: Keypoint(0, 0, 0.9),
          rightFoot: Keypoint(1, 1, 0.9),
        ),
      );
      final next = smoother.smooth(
        const ClimberKeypoints(
          leftHand: Keypoint(0.4, 0.4, 0.9),
          rightFoot: Keypoint(0.6, 0.6, 0.9),
        ),
      );
      expect(next.leftHand, _at(0.2, 0.2, 0.9));
      expect(next.rightFoot, _at(0.8, 0.8, 0.9));
    });

    test('reports missing points as null but resumes the average '
        'within the missing-frame limit', () {
      final smoother = KeypointSmoother(alpha: 0.5, maxMissingFrames: 5);
      smoother.smooth(hipAt(0, 0));
      for (var i = 0; i < 5; i++) {
        expect(smoother.smooth(ClimberKeypoints.none).hipCenter, isNull);
      }
      expect(smoother.smooth(hipAt(1, 1)).hipCenter, _at(0.5, 0.5, 0.9));
    });

    test('starts fresh after more than maxMissingFrames missing frames', () {
      final smoother = KeypointSmoother(alpha: 0.5, maxMissingFrames: 5);
      smoother.smooth(hipAt(0, 0));
      for (var i = 0; i < 6; i++) {
        smoother.smooth(ClimberKeypoints.none);
      }
      expect(smoother.smooth(hipAt(1, 1)).hipCenter, _at(1, 1, 0.9));
    });

    test('a sighting resets the missing-frame count', () {
      final smoother = KeypointSmoother(alpha: 0.5, maxMissingFrames: 2);
      smoother.smooth(hipAt(0, 0));
      smoother.smooth(ClimberKeypoints.none);
      smoother.smooth(ClimberKeypoints.none);
      smoother.smooth(hipAt(0, 0));
      smoother.smooth(ClimberKeypoints.none);
      smoother.smooth(ClimberKeypoints.none);
      expect(smoother.smooth(hipAt(1, 1)).hipCenter, _at(0.5, 0.5, 0.9));
    });

    test('reset forgets all history', () {
      final smoother = KeypointSmoother(alpha: 0.5);
      smoother.smooth(hipAt(0, 0));
      smoother.reset();
      expect(smoother.smooth(hipAt(1, 1)).hipCenter, _at(1, 1, 0.9));
    });
  });
}
