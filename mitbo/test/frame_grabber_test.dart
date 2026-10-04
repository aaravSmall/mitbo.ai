import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraImageData, CameraImageFormat, CameraImagePlane;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/services/frame_grabber.dart';
import 'package:mitbo/vision/wall_frame.dart';

const _backCamera = CameraDescription(
  name: 'back',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

CameraImage _image({
  ImageFormatGroup group = ImageFormatGroup.nv21,
  int raw = 17,
  int planes = 1,
  Uint8List? bytes,
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
          bytes: bytes ?? Uint8List(width * height * 2),
          bytesPerRow: width,
        ),
      ),
    ),
  );
}

final _frame = WallFrame(1, 1, Uint8List(3));

/// Converter whose results are released manually.
class _FakeConverter {
  final calls = <RawFrame>[];
  final pending = <Completer<WallFrame>>[];

  Future<WallFrame> call(RawFrame raw) {
    calls.add(raw);
    final completer = Completer<WallFrame>();
    pending.add(completer);
    return completer.future;
  }
}

void _offer(FrameGrabber grabber, CameraImage image) => grabber.onCameraImage(
  image,
  camera: _backCamera,
  deviceOrientation: DeviceOrientation.portraitUp,
);

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('does nothing per frame while no grab is pending', () {
    final converter = _FakeConverter();
    final grabber = FrameGrabber(convert: converter.call);
    _offer(grabber, _image());
    _offer(grabber, _image());
    expect(converter.calls, isEmpty);
    expect(grabber.hasPending, isFalse);
  });

  test('converts the next frame once and resolves the grab', () async {
    final converter = _FakeConverter();
    final grabber = FrameGrabber(convert: converter.call);
    final first = grabber.grabNext();
    final second = grabber.grabNext();
    expect(grabber.hasPending, isTrue);

    _offer(grabber, _image());
    // Frames arriving mid-conversion are ignored.
    _offer(grabber, _image());
    expect(converter.calls, hasLength(1));
    expect(converter.calls.single.format, RawFrameFormat.nv21);
    // Back camera in portrait on Android: 90° clockwise to upright.
    expect(converter.calls.single.rotationDegrees, 90);

    converter.pending.single.complete(_frame);
    expect(await first, same(_frame));
    expect(await second, same(_frame));
    expect(grabber.hasPending, isFalse);

    _offer(grabber, _image());
    expect(converter.calls, hasLength(1));
  });

  test('cancel resolves the grab with null and drops the late result', () async {
    final converter = _FakeConverter();
    final grabber = FrameGrabber(convert: converter.call);
    final grab = grabber.grabNext();
    _offer(grabber, _image());
    grabber.cancel();
    expect(await grab, isNull);

    // A new grab isn't satisfied by the cancelled conversion.
    final next = grabber.grabNext();
    converter.pending.single.complete(_frame);
    await Future<void>.delayed(Duration.zero);
    expect(grabber.hasPending, isTrue);

    _offer(grabber, _image());
    expect(converter.calls, hasLength(2));
    converter.pending.last.complete(_frame);
    expect(await next, same(_frame));
  });

  test('resolves with null when conversion fails', () async {
    final grabber = FrameGrabber(
      convert: (_) => Future<WallFrame>.error(StateError('boom')),
    );
    final grab = grabber.grabNext();
    _offer(grabber, _image());
    expect(await grab, isNull);
  });

  test('resolves with null for unsupported formats', () async {
    final converter = _FakeConverter();
    final grabber = FrameGrabber(convert: converter.call);
    final grab = grabber.grabNext();
    _offer(
      grabber,
      _image(group: ImageFormatGroup.yuv420, raw: 35, planes: 3),
    );
    expect(await grab, isNull);
    expect(converter.calls, isEmpty);
  });

  test('a disposed grabber resolves grabs with null', () async {
    final grabber = FrameGrabber(convert: _FakeConverter().call);
    final pending = grabber.grabNext();
    grabber.dispose();
    expect(await pending, isNull);
    expect(await grabber.grabNext(), isNull);
  });

  group('rawFrameFrom', () {
    test('copies the plane bytes', () {
      final bytes = Uint8List(16)..fillRange(0, 16, 7);
      final raw = FrameGrabber.rawFrameFrom(
        _image(bytes: bytes),
        InputImageRotation.rotation270deg,
      )!;
      bytes.fillRange(0, 16, 0);
      expect(raw.bytes.every((b) => b == 7), isTrue);
      expect(raw.rotationDegrees, 270);
      expect((raw.width, raw.height, raw.bytesPerRow), (4, 2, 4));
    });

    test('maps BGRA frames', () {
      final raw = FrameGrabber.rawFrameFrom(
        _image(group: ImageFormatGroup.bgra8888, raw: 1111970369),
        InputImageRotation.rotation0deg,
      );
      expect(raw?.format, RawFrameFormat.bgra8888);
    });
  });
}
