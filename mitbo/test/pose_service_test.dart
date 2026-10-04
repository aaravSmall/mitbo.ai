import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraImageData, CameraImageFormat, CameraImagePlane;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/services/pose_service.dart';

const _backCamera = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

CameraImage _frame({
  required ImageFormatGroup group,
  required int raw,
  int planes = 1,
}) {
  const width = 4;
  const height = 2;
  return CameraImage.fromPlatformInterface(
    CameraImageData(
      format: CameraImageFormat(group, raw: raw),
      width: width,
      height: height,
      planes: List.generate(
        planes,
        (_) => CameraImagePlane(
          bytes: Uint8List(width * height * 4),
          bytesPerRow: width * 4,
        ),
      ),
    ),
  );
}

CameraImage _nv21Frame() => _frame(group: ImageFormatGroup.nv21, raw: 17);

/// Detector whose results are released manually, so tests can hold a
/// detection "in flight".
class _FakeDetector extends Fake implements PoseDetector {
  final pending = <Completer<List<Pose>>>[];
  bool closed = false;

  @override
  Future<List<Pose>> processImage(InputImage inputImage) {
    final completer = Completer<List<Pose>>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> close() async => closed = true;
}

Future<void> _process(PoseService service, CameraImage image) =>
    service.processCameraImage(
      image,
      camera: _backCamera,
      deviceOrientation: DeviceOrientation.portraitUp,
    );

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('imageFormatGroup', () {
    test('is nv21 on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(PoseService.imageFormatGroup, ImageFormatGroup.nv21);
    });

    test('is bgra8888 on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(PoseService.imageFormatGroup, ImageFormatGroup.bgra8888);
    });
  });

  group('rotationFor', () {
    test('uses only the sensor orientation on iOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        PoseService.rotationFor(_backCamera, DeviceOrientation.landscapeLeft),
        InputImageRotation.rotation90deg,
      );
    });

    test('compensates for device orientation on Android (back camera)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        PoseService.rotationFor(_backCamera, DeviceOrientation.portraitUp),
        InputImageRotation.rotation90deg,
      );
      expect(
        PoseService.rotationFor(_backCamera, DeviceOrientation.landscapeLeft),
        InputImageRotation.rotation0deg,
      );
      expect(
        PoseService.rotationFor(_backCamera, DeviceOrientation.landscapeRight),
        InputImageRotation.rotation180deg,
      );
    });

    test('compensates the other way for a front camera on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const front = CameraDescription(
        name: 'front',
        lensDirection: CameraLensDirection.front,
        sensorOrientation: 270,
      );
      expect(
        PoseService.rotationFor(front, DeviceOrientation.landscapeLeft),
        InputImageRotation.rotation0deg,
      );
    });
  });

  group('inputImageFrom', () {
    test('wraps a single-plane nv21 frame on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final input = PoseService.inputImageFrom(
        _nv21Frame(),
        InputImageRotation.rotation90deg,
      );
      expect(input, isNotNull);
      expect(input!.metadata!.format, InputImageFormat.nv21);
      expect(input.metadata!.size, const Size(4, 2));
      expect(input.metadata!.rotation, InputImageRotation.rotation90deg);
      expect(input.metadata!.bytesPerRow, 16);
    });

    test('rejects a format that does not match the platform', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(
        PoseService.inputImageFrom(
          _nv21Frame(),
          InputImageRotation.rotation0deg,
        ),
        isNull,
      );
    });

    test('rejects multi-plane frames', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(
        PoseService.inputImageFrom(
          _frame(group: ImageFormatGroup.nv21, raw: 17, planes: 3),
          InputImageRotation.rotation0deg,
        ),
        isNull,
      );
    });
  });

  group('processCameraImage', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('drops frames while a detection is in flight', () async {
      final detector = _FakeDetector();
      final service = PoseService(detector: detector);

      final first = _process(service, _nv21Frame());
      await _process(service, _nv21Frame());
      expect(detector.pending, hasLength(1));

      detector.pending.single.complete([]);
      await first;
      final next = _process(service, _nv21Frame());
      expect(detector.pending, hasLength(2));
      detector.pending.last.complete([]);
      await next;
    });

    test('publishes the image size and rotation with the result', () async {
      final detector = _FakeDetector();
      final service = PoseService(detector: detector);

      final processing = _process(service, _nv21Frame());
      detector.pending.single.complete([]);
      await processing;

      final frame = service.latest.value!;
      expect(frame.pose, isNull);
      expect(frame.imageSize, const Size(4, 2));
      expect(frame.rotation, InputImageRotation.rotation90deg);
    });

    test(
      'publishes a 0 degree rotation on iOS, where frames are upright',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final detector = _FakeDetector();
        final service = PoseService(detector: detector);

        final processing = _process(
          service,
          _frame(
            group: ImageFormatGroup.bgra8888,
            raw: InputImageFormat.bgra8888.rawValue,
          ),
        );
        detector.pending.single.complete([]);
        await processing;

        expect(service.latest.value!.rotation, InputImageRotation.rotation0deg);
      },
    );

    test('publishes smoothed climber keypoints in upright space', () async {
      final detector = _FakeDetector();
      final service = PoseService(detector: detector);

      // Raw 4x2 frame rotated 90 degrees is upright 2x4.
      final processing = _process(service, _nv21Frame());
      detector.pending.single.complete([
        Pose(
          landmarks: {
            PoseLandmarkType.leftWrist: PoseLandmark(
              type: PoseLandmarkType.leftWrist,
              x: 1,
              y: 1,
              z: 0,
              likelihood: 0.9,
            ),
          },
        ),
      ]);
      await processing;

      final keypoints = service.latest.value!.keypoints;
      expect(keypoints.leftHand, const Keypoint(0.5, 0.25, 0.9));
      expect(keypoints.hipCenter, isNull);
    });

    test('publishes no keypoints when nobody is in frame', () async {
      final detector = _FakeDetector();
      final service = PoseService(detector: detector);

      final processing = _process(service, _nv21Frame());
      detector.pending.single.complete([]);
      await processing;

      final keypoints = service.latest.value!.keypoints;
      for (final point in ClimberPoint.values) {
        expect(keypoints[point], isNull);
      }
    });

    test('reset clears the result and drops an in-flight detection', () async {
      final detector = _FakeDetector();
      final service = PoseService(detector: detector);

      final first = _process(service, _nv21Frame());
      detector.pending.single.complete([]);
      await first;
      expect(service.latest.value, isNotNull);

      final inFlight = _process(service, _nv21Frame());
      service.reset();
      expect(service.latest.value, isNull);
      detector.pending.last.complete([]);
      await inFlight;
      expect(service.latest.value, isNull);
    });

    test('dispose closes the detector and ignores late results', () async {
      final detector = _FakeDetector();
      final service = PoseService(detector: detector);

      final processing = _process(service, _nv21Frame());
      await service.dispose();
      expect(detector.closed, isTrue);

      // Completing after dispose must not touch the disposed notifier.
      detector.pending.single.complete([]);
      await processing;

      await _process(service, _nv21Frame());
      expect(detector.pending, hasLength(1));
    });
  });
}
