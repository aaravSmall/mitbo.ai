import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/vision/start_detector.dart';
import 'package:mitbo/vision/wall_frame.dart';
import 'package:mitbo/vision/wall_reference.dart';

Duration _ms(int ms) => Duration(milliseconds: ms);

ClimberKeypoints _hands(
  double lx,
  double ly,
  double rx,
  double ry, {
  Keypoint? hip,
}) => ClimberKeypoints(
  leftHand: Keypoint(lx, ly, 0.9),
  rightHand: Keypoint(rx, ry, 0.9),
  hipCenter: hip,
);

final _frame = WallFrame(1, 1, Uint8List(3));

/// Feeds [keypoints] every 100 ms from [from] to [to] (inclusive) and
/// returns the first start position detected, if any.
StartPosition? _feed(
  StartDetector detector,
  ClimberKeypoints Function(int ms) keypoints, {
  required int from,
  required int to,
}) {
  StartPosition? result;
  for (var t = from; t <= to; t += 100) {
    result ??= detector.onPose(keypoints(t), _ms(t));
  }
  return result;
}

void main() {
  group('WallReferenceTracker', () {
    const person = ClimberKeypoints(hipCenter: Keypoint(0.5, 0.6, 0.9));

    test('waits for the frame to be clear for a second', () {
      final tracker = WallReferenceTracker();
      tracker.onPose(ClimberKeypoints.none, _ms(0));
      expect(tracker.wantsCapture, isFalse);
      tracker.onPose(ClimberKeypoints.none, _ms(900));
      expect(tracker.wantsCapture, isFalse);
      tracker.onPose(ClimberKeypoints.none, _ms(1000));
      expect(tracker.wantsCapture, isTrue);
      expect(tracker.setReference(_frame, _ms(1050)), isTrue);
      expect(tracker.reference, same(_frame));
      expect(tracker.wantsCapture, isFalse);
    });

    test('never captures while someone is in frame', () {
      final tracker = WallReferenceTracker();
      for (var t = 0; t <= 10000; t += 100) {
        tracker.onPose(person, _ms(t));
        expect(tracker.wantsCapture, isFalse);
      }
      expect(tracker.setReference(_frame, _ms(10000)), isFalse);
      expect(tracker.reference, isNull);
    });

    test('a person stepping in restarts the clear timer', () {
      final tracker = WallReferenceTracker();
      tracker.onPose(ClimberKeypoints.none, _ms(0));
      tracker.onPose(person, _ms(800));
      tracker.onPose(ClimberKeypoints.none, _ms(900));
      tracker.onPose(ClimberKeypoints.none, _ms(1500));
      expect(tracker.wantsCapture, isFalse);
      tracker.onPose(ClimberKeypoints.none, _ms(1900));
      expect(tracker.wantsCapture, isTrue);
    });

    test('rejects a grab that lands after someone walked in', () {
      final tracker = WallReferenceTracker()
        ..onPose(ClimberKeypoints.none, _ms(0))
        ..onPose(ClimberKeypoints.none, _ms(1000));
      expect(tracker.wantsCapture, isTrue);
      tracker.onPose(person, _ms(1030));
      expect(tracker.setReference(_frame, _ms(1060)), isFalse);
    });

    test('refreshes every 5 s while clear, keeps the old one while busy', () {
      final tracker = WallReferenceTracker()
        ..onPose(ClimberKeypoints.none, _ms(0))
        ..onPose(ClimberKeypoints.none, _ms(1000))
        ..setReference(_frame, _ms(1000));
      tracker.onPose(ClimberKeypoints.none, _ms(5900));
      expect(tracker.wantsCapture, isFalse);
      tracker.onPose(ClimberKeypoints.none, _ms(6000));
      expect(tracker.wantsCapture, isTrue);
      expect(tracker.referenceAge, _ms(5000));

      tracker.onPose(person, _ms(6100));
      expect(tracker.wantsCapture, isFalse);
      expect(tracker.reference, same(_frame));
    });

    test('reset forgets the reference', () {
      final tracker = WallReferenceTracker()
        ..onPose(ClimberKeypoints.none, _ms(0))
        ..onPose(ClimberKeypoints.none, _ms(1000))
        ..setReference(_frame, _ms(1000))
        ..reset();
      expect(tracker.reference, isNull);
      expect(tracker.referenceAge, isNull);
      expect(tracker.wantsCapture, isFalse);
    });
  });

  group('StartDetector', () {
    ClimberKeypoints still(int _) => _hands(0.4, 0.3, 0.6, 0.32);

    test('fires once both hands are still for 1.2 s', () {
      final detector = StartDetector();
      expect(_feed(detector, still, from: 0, to: 1100), isNull);
      final start = detector.onPose(still(1200), _ms(1200));
      expect(start, isNotNull);
      expect(start!.leftHand.x, 0.4);
      expect(start.matched, isFalse);
      expect(start.handPoints, [(0.4, 0.3), (0.6, 0.32)]);
      expect(detector.fired, isTrue);
    });

    test('stays quiet after firing until reset', () {
      final detector = StartDetector();
      expect(_feed(detector, still, from: 0, to: 1200), isNotNull);
      expect(_feed(detector, still, from: 1300, to: 5000), isNull);
      detector.reset();
      expect(_feed(detector, still, from: 5100, to: 6300), isNotNull);
    });

    test('small jitter still counts as still', () {
      final detector = StartDetector();
      final start = _feed(
        detector,
        (t) => _hands(0.4 + (t % 200 == 0 ? 0.01 : 0), 0.3, 0.6, 0.32),
        from: 0,
        to: 1200,
      );
      expect(start, isNotNull);
    });

    test('a drifting hand keeps restarting the timer', () {
      final detector = StartDetector();
      final start = _feed(
        detector,
        // Right hand reaching up 0.01 every 100 ms.
        (t) => _hands(0.4, 0.3, 0.6, 0.5 - t / 10000),
        from: 0,
        to: 2000,
      );
      expect(start, isNull);
    });

    test('a tracking glitch restarts the timer', () {
      final detector = StartDetector();
      expect(_feed(detector, still, from: 0, to: 1000), isNull);
      // One wild frame, then back.
      expect(detector.onPose(_hands(0.4, 0.3, 0.9, 0.9), _ms(1100)), isNull);
      expect(_feed(detector, still, from: 1200, to: 2300), isNull);
      expect(detector.onPose(still(2400), _ms(2400)), isNotNull);
    });

    test('needs both hands visible', () {
      final detector = StartDetector();
      final start = _feed(
        detector,
        (_) => const ClimberKeypoints(leftHand: Keypoint(0.4, 0.3, 0.9)),
        from: 0,
        to: 3000,
      );
      expect(start, isNull);
    });

    test('ignores hands below the hips (standing around)', () {
      final detector = StartDetector();
      final start = _feed(
        detector,
        (_) => _hands(0.4, 0.7, 0.6, 0.7, hip: const Keypoint(0.5, 0.6, 0.9)),
        from: 0,
        to: 3000,
      );
      expect(start, isNull);
    });

    test('accepts hands above the hips', () {
      final detector = StartDetector();
      final start = _feed(
        detector,
        (_) => _hands(0.4, 0.4, 0.6, 0.4, hip: const Keypoint(0.5, 0.6, 0.9)),
        from: 0,
        to: 1200,
      );
      expect(start, isNotNull);
    });

    test('matched hands give a single start point', () {
      final detector = StartDetector();
      final start = _feed(
        detector,
        (_) => _hands(0.50, 0.30, 0.52, 0.30),
        from: 0,
        to: 1200,
      )!;
      expect(start.matched, isTrue);
      expect(start.handPoints, hasLength(1));
      expect(start.handPoints.single.$1, closeTo(0.51, 1e-9));
    });

    test('reset(requireMove) waits for the hands to move first', () {
      final detector = StartDetector();
      expect(_feed(detector, still, from: 0, to: 1200), isNotNull);
      detector.reset(requireMove: true);
      // Still in the same spot: no retrigger.
      expect(_feed(detector, still, from: 1300, to: 4000), isNull);
      // Moves to a new start and settles.
      final start = _feed(
        detector,
        (_) => _hands(0.3, 0.4, 0.5, 0.42),
        from: 4100,
        to: 5300,
      );
      expect(start, isNotNull);
      expect(start!.leftHand.x, 0.3);
    });
  });
}
