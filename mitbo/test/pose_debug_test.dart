import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/services/pose_service.dart';
import 'package:mitbo/widgets/pose_debug_sheet.dart';
import 'package:mitbo/widgets/pose_overlay.dart';

void main() {
  testWidgets('debug sheet reports keypoint and model changes', (tester) async {
    final changes = <PoseDebugSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PoseDebugSheet(
            initial: const PoseDebugSettings(),
            onChanged: changes.add,
          ),
        ),
      ),
    );

    await tester.tap(find.text('Show smoothed keypoints'));
    await tester.pump();
    await tester.tap(find.text('Accurate'));
    await tester.pump();

    expect(changes.last.showKeypoints, isTrue);
    expect(changes.last.model, PoseDetectionModel.accurate);
    expect(changes.last.alpha, 0.5);
    expect(changes.last.handNudge, 0.5);
  });

  testWidgets('overlay paints smoothed keypoints without errors', (
    tester,
  ) async {
    final frames = ValueNotifier<PoseFrame?>(
      PoseFrame(
        pose: Pose(landmarks: {}),
        imageSize: const Size(400, 300),
        rotation: InputImageRotation.rotation90deg,
        keypoints: const ClimberKeypoints(
          leftHand: Keypoint(0.2, 0.3, 0.9),
          hipCenter: Keypoint(0.5, 0.6, 0.75),
        ),
      ),
    );
    addTearDown(frames.dispose);

    await tester.pumpWidget(
      SizedBox(
        width: 300,
        height: 400,
        child: PoseOverlay(frames: frames, showKeypoints: true),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
