import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../vision/wall_frame.dart';
import 'pose_service.dart';

/// Converts a copied camera frame to a [WallFrame]; injectable for tests.
typedef WallFrameConverter = Future<WallFrame> Function(RawFrame raw);

Future<WallFrame> _convertOffMainIsolate(RawFrame raw) =>
    Isolate.run(() => raw.toWallFrame());

/// Hands out [WallFrame] snapshots of the camera stream on request.
///
/// Feed every camera frame to [onCameraImage]. While nothing is waiting on
/// [grabNext] that's a no-op, so the grabber costs nothing per frame.
class FrameGrabber {
  FrameGrabber({WallFrameConverter convert = _convertOffMainIsolate})
    : _convert = convert;

  final WallFrameConverter _convert;
  Completer<WallFrame?>? _pending;
  bool _converting = false;
  bool _disposed = false;

  // Bumped by [cancel] so a conversion already running is discarded.
  int _session = 0;

  /// True while a [grabNext] call is waiting for a frame.
  bool get hasPending => _pending != null;

  /// Resolves with the next camera frame as a [WallFrame], or null if the
  /// grab is cancelled (camera stopped) or the frame can't be converted.
  /// Calls made while a grab is pending share its result.
  Future<WallFrame?> grabNext() {
    if (_disposed) return Future.value(null);
    return (_pending ??= Completer<WallFrame?>()).future;
  }

  /// Offers a camera frame. Only does work while a grab is pending.
  void onCameraImage(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) {
    if (_pending == null || _converting || _disposed) return;
    final rotation = PoseService.rotationFor(camera, deviceOrientation);
    if (rotation == null) return;
    final raw = rawFrameFrom(image, PoseService.coordinateRotation(rotation));
    if (raw == null) {
      _finish(null);
      return;
    }
    _converting = true;
    _run(raw, _session);
  }

  Future<void> _run(RawFrame raw, int session) async {
    WallFrame? frame;
    try {
      frame = await _convert(raw);
    } catch (e) {
      debugPrint('Wall frame conversion failed: $e');
    }
    if (session != _session) return;
    _converting = false;
    _finish(frame);
  }

  /// Copies [image]'s bytes into a [RawFrame] whose rotation is
  /// [rotation]. The copy is made synchronously because the camera plugin
  /// may reuse the buffer once the frame callback returns. Returns null for
  /// formats other than single-plane NV21 / BGRA8888.
  @visibleForTesting
  static RawFrame? rawFrameFrom(
    CameraImage image,
    InputImageRotation rotation,
  ) {
    final format = switch (image.format.group) {
      ImageFormatGroup.nv21 => RawFrameFormat.nv21,
      ImageFormatGroup.bgra8888 => RawFrameFormat.bgra8888,
      _ => null,
    };
    if (format == null || image.planes.length != 1) return null;
    final plane = image.planes.first;
    return RawFrame(
      format: format,
      bytes: Uint8List.fromList(plane.bytes),
      width: image.width,
      height: image.height,
      bytesPerRow: plane.bytesPerRow,
      rotationDegrees: rotationDegrees(rotation),
    );
  }

  /// Clockwise degrees for an ML Kit rotation.
  static int rotationDegrees(InputImageRotation rotation) => switch (rotation) {
    InputImageRotation.rotation0deg => 0,
    InputImageRotation.rotation90deg => 90,
    InputImageRotation.rotation180deg => 180,
    InputImageRotation.rotation270deg => 270,
  };

  /// Resolves any pending grab with null and discards a conversion in
  /// flight. Call when the camera stops.
  void cancel() {
    _session++;
    _converting = false;
    _finish(null);
  }

  void dispose() {
    if (_disposed) return;
    cancel();
    _disposed = true;
  }

  void _finish(WallFrame? frame) {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(frame);
  }
}
