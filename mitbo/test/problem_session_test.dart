import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/beta/beta_planner.dart';
import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/models/climber_profile.dart';
import 'package:mitbo/services/pose_service.dart';
import 'package:mitbo/state/problem_session.dart';
import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/problem_detector.dart';
import 'package:mitbo/vision/start_detector.dart';
import 'package:mitbo/vision/wall_frame.dart';
import 'package:mitbo/widgets/hold_overlay.dart';
import 'package:mitbo/widgets/problem_status_pill.dart';

const _hold = DetectedHold(
  left: 0.45,
  top: 0.45,
  right: 0.55,
  bottom: 0.55,
  centerX: 0.5,
  centerY: 0.5,
  pixelArea: 100,
  areaFraction: 0.001,
  fillRatio: 0.8,
);

const _redProblem = DetectedProblem(
  color: HoldColor(hue: 0, saturation: 0.8, value: 0.8),
  holds: [_hold, _hold, _hold],
  startHoldIndices: [2],
);

/// Lets pending microtasks (completed fakes) run. Works under testWidgets'
/// fake async too, unlike a zero-length timer.
Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.value();
  }
}

PoseFrame _poseFrame(ClimberKeypoints keypoints) => PoseFrame(
  pose: null,
  imageSize: const Size(640, 480),
  rotation: InputImageRotation.rotation90deg,
  keypoints: keypoints,
);

const _handsOnStart = ClimberKeypoints(
  leftHand: Keypoint(0.4, 0.3, 0.9),
  rightHand: Keypoint(0.6, 0.3, 0.9),
);

/// A session wired to fakes: a pose notifier, a manual clock, a grab that
/// completes on demand, and a detector that returns queued results.
class _Harness {
  _Harness() {
    session = ProblemSession(
      frames: frames,
      grabFrame: () {
        grabs++;
        return (grab = Completer<WallFrame?>()).future;
      },
      detect: (reference, start, params) {
        detections.add((reference, start, params));
        return (detection = Completer<ProblemResult>()).future;
      },
      clock: () => now,
    );
  }

  final frames = ValueNotifier<PoseFrame?>(null);
  late final ProblemSession session;
  Duration now = Duration.zero;
  int grabs = 0;
  Completer<WallFrame?>? grab;
  Completer<ProblemResult>? detection;
  final detections = <(WallFrame, StartPosition, SegmentationParams)>[];
  final wall = WallFrame(2, 2, Uint8List(12));

  /// Emits [keypoints] every 100 ms from [fromMs] to [toMs] inclusive.
  void emit(
    ClimberKeypoints keypoints, {
    required int fromMs,
    required int toMs,
  }) {
    for (var t = fromMs; t <= toMs; t += 100) {
      now = Duration(milliseconds: t);
      frames.value = _poseFrame(keypoints);
    }
  }

  /// Scans the wall: an empty frame for a second, then the grab lands.
  Future<void> scanWall({int fromMs = 0}) async {
    emit(ClimberKeypoints.none, fromMs: fromMs, toMs: fromMs + 1000);
    grab!.complete(wall);
    await _flush();
  }
}

void main() {
  group('ProblemSession', () {
    test('scans the wall, detects the start, and locks the problem', () async {
      final h = _Harness();
      final phases = <ProblemPhase>[];
      h.session.addListener(() => phases.add(h.session.phase));
      expect(h.session.phase, ProblemPhase.scanningWall);

      await h.scanWall();
      expect(h.grabs, 1);
      expect(h.session.phase, ProblemPhase.ready);
      expect(h.session.reference, same(h.wall));

      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      expect(h.session.phase, ProblemPhase.detecting);
      expect(h.detections, hasLength(1));
      expect(h.detections.single.$1, same(h.wall));
      expect(h.detections.single.$2.leftHand.x, 0.4);

      h.detection!.complete(const ProblemFound(_redProblem));
      await _flush();
      expect(h.session.phase, ProblemPhase.locked);
      expect(h.session.problem, same(_redProblem));
      expect(h.session.problemImageSize, const Size(2, 2));
      // A beta is planned as soon as the problem locks.
      expect(h.session.beta, isNotNull);
      expect(h.session.beta!.holds, hasLength(_redProblem.holds.length));
      expect(phases, [
        ProblemPhase.ready,
        ProblemPhase.detecting,
        ProblemPhase.locked,
      ]);

      // Locked: climbing around doesn't trigger new detections.
      h.emit(_handsOnStart, fromMs: 2400, toMs: 6000);
      expect(h.detections, hasLength(1));
    });

    test('does not look for a start before the wall is scanned', () {
      final h = _Harness();
      h.emit(_handsOnStart, fromMs: 0, toMs: 5000);
      expect(h.session.phase, ProblemPhase.scanningWall);
      expect(h.detections, isEmpty);
      expect(h.grabs, 0);
    });

    test('a failed detection retries once the hands move', () async {
      final h = _Harness();
      await h.scanWall();
      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      h.detection!.complete(const ProblemFailed('No luck'));
      await _flush();
      expect(h.session.phase, ProblemPhase.failed);
      expect(h.session.failureReason, 'No luck');

      // Same spot: no retry.
      h.emit(_handsOnStart, fromMs: 2400, toMs: 5000);
      expect(h.detections, hasLength(1));

      // New start.
      const moved = ClimberKeypoints(
        leftHand: Keypoint(0.3, 0.4, 0.9),
        rightHand: Keypoint(0.5, 0.4, 0.9),
      );
      h.emit(moved, fromMs: 5100, toMs: 6300);
      expect(h.detections, hasLength(2));
      expect(h.session.phase, ProblemPhase.detecting);
    });

    test('detection errors become a failure', () async {
      final h = _Harness();
      await h.scanWall();
      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      h.detection!.completeError(StateError('boom'));
      await _flush();
      expect(h.session.phase, ProblemPhase.failed);
      expect(h.session.failureReason, isNotNull);
    });

    test('resetProblem keeps the wall and waits for a new start', () async {
      final h = _Harness();
      await h.scanWall();
      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      h.detection!.complete(const ProblemFound(_redProblem));
      await _flush();

      h.session.resetProblem();
      expect(h.session.phase, ProblemPhase.ready);
      expect(h.session.problem, isNull);
      expect(h.session.beta, isNull);
      expect(h.session.reference, same(h.wall));

      h.emit(_handsOnStart, fromMs: 2400, toMs: 3600);
      expect(h.detections, hasLength(2));
    });

    test('restart rescans and drops detections still in flight', () async {
      final h = _Harness();
      await h.scanWall();
      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      final stale = h.detection!;

      h.session.restart();
      expect(h.session.phase, ProblemPhase.scanningWall);
      expect(h.session.reference, isNull);

      stale.complete(const ProblemFound(_redProblem));
      await _flush();
      expect(h.session.phase, ProblemPhase.scanningWall);
      expect(h.session.problem, isNull);
    });

    test('a grab landing after restart is ignored', () async {
      final h = _Harness();
      h.emit(ClimberKeypoints.none, fromMs: 0, toMs: 1000);
      final stale = h.grab!;
      h.session.restart();
      stale.complete(h.wall);
      await _flush();
      expect(h.session.reference, isNull);
      expect(h.session.phase, ProblemPhase.scanningWall);

      // A fresh scan still works.
      await h.scanWall(fromMs: 2000);
      expect(h.session.phase, ProblemPhase.ready);
    });

    test('changing params re-runs the last detection', () async {
      final h = _Harness();
      await h.scanWall();
      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      h.detection!.complete(const ProblemFound(_redProblem));
      await _flush();

      const params = SegmentationParams(
        tolerance: ColorTolerance(hueTolerance: 30),
      );
      h.session.params = params;
      expect(h.detections, hasLength(2));
      expect(h.detections.last.$3.tolerance.hueTolerance, 30);
      expect(h.session.phase, ProblemPhase.detecting);
    });

    test('stops listening once disposed', () async {
      final h = _Harness();
      h.session.dispose();
      h.emit(ClimberKeypoints.none, fromMs: 0, toMs: 2000);
      expect(h.grabs, 0);
    });
  });

  group('problemStatusText', () {
    test('describes each phase', () {
      expect(
        problemStatusText(ProblemPhase.scanningWall),
        'Step out of frame to scan the wall',
      );
      expect(
        problemStatusText(ProblemPhase.ready),
        'Ready — get on the start holds',
      );
      expect(problemStatusText(ProblemPhase.detecting), 'Reading the problem…');
      expect(
        problemStatusText(ProblemPhase.locked, problem: _redProblem),
        'Red problem · 3 holds',
      );
      expect(
        problemStatusText(ProblemPhase.failed, failureReason: 'Nope'),
        'Nope',
      );
    });

    testWidgets('pill offers reset only once locked or failed', (
      tester,
    ) async {
      var resets = 0;
      Future<void> pump(ProblemPhase phase) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ProblemStatusPill(
                phase: phase,
                problem: _redProblem,
                onReset: () => resets++,
              ),
            ),
          ),
        ),
      );

      await pump(ProblemPhase.ready);
      expect(find.text('Reset'), findsNothing);

      await pump(ProblemPhase.locked);
      expect(find.text('Red problem · 3 holds'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      expect(resets, 1);
    });

    testWidgets('pill shows the move count and replays the beta', (
      tester,
    ) async {
      final beta = planBeta(
        _redProblem,
        const StartPosition(
          leftHand: Keypoint(0.5, 0.5, 0.9),
          rightHand: Keypoint(0.5, 0.5, 0.9),
        ),
        profile: const ClimberProfile(heightCm: 170, wingspanCm: 170),
        aspect: 0.75,
      );
      var replays = 0;
      var stops = 0;
      Future<void> pump({required bool speaking}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ProblemStatusPill(
                phase: ProblemPhase.locked,
                problem: _redProblem,
                beta: beta,
                speaking: speaking,
                onReplay: () => replays++,
                onStopSpeaking: () => stops++,
              ),
            ),
          ),
        ),
      );

      await pump(speaking: false);
      final moves = beta.handMoveCount;
      expect(
        find.text('Red problem · 3 holds · $moves ${moves == 1 ? 'move' : 'moves'}'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Replay beta'));
      expect(replays, 1);

      await pump(speaking: true);
      await tester.tap(find.byTooltip('Stop'));
      expect(stops, 1);
    });
  });

  group('HoldOverlay', () {
    test('maps a centered hold to the preview center', () {
      final rect = holdRectOnPreview(
        _hold,
        imageSize: const Size(320, 427),
        previewSize: const Size(360, 640),
      );
      expect(rect.center.dx, closeTo(180, 0.5));
      expect(rect.center.dy, closeTo(320, 0.5));
    });

    test('scales the box with the preview (cover fit)', () {
      // 320x427 into 360x640: cover scale is 640/427, so a box 10% of the
      // image wide is 32 * 640/427 px wide on screen.
      final rect = holdRectOnPreview(
        _hold,
        imageSize: const Size(320, 427),
        previewSize: const Size(360, 640),
      );
      expect(rect.width, closeTo(32 * 640 / 427, 0.5));
      expect(rect.height, closeTo(42.7 * 640 / 427, 0.5));
    });

    testWidgets('paints a locked problem without errors', (tester) async {
      final h = _Harness();
      await h.scanWall();
      h.emit(_handsOnStart, fromMs: 1100, toMs: 2300);
      h.detection!.complete(const ProblemFound(_redProblem));
      await tester.pump();

      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 360,
            height: 640,
            child: HoldOverlay(session: h.session),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(HoldOverlay), findsOneWidget);
    });
  });
}
