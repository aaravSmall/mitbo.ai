import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// The most recent pose detection result, plus what's needed to map its
/// landmark coordinates (which are in source-image space) onto the preview.
@immutable
class PoseFrame {
  const PoseFrame({
    required this.pose,
    required this.imageSize,
    required this.rotation,
  });

  /// The detected pose, or null if no one was found in the frame.
  final Pose? pose;

  /// Size of the raw camera image, before [rotation] is applied.
  final Size imageSize;

  /// Rotation ML Kit applied to the image to make it upright.
  final InputImageRotation rotation;
}

/// Runs ML Kit pose detection (stream mode, base model) on camera frames.
///
/// Owns the [PoseDetector]. Frames that arrive while a detection is still
/// in flight are dropped, so a slow detector never backs up the camera.
class PoseService {
  PoseService({PoseDetector? detector})
    : _detector =
          detector ??
          PoseDetector(
            options: PoseDetectorOptions(
              model: PoseDetectionModel.base,
              mode: PoseDetectionMode.stream,
            ),
          );

  final PoseDetector _detector;
  final ValueNotifier<PoseFrame?> latest = ValueNotifier(null);

  bool _busy = false;
  bool _disposed = false;

  /// Image format ML Kit expects from the camera stream on this platform.
  static ImageFormatGroup get imageFormatGroup =>
      defaultTargetPlatform == TargetPlatform.iOS
      ? ImageFormatGroup.bgra8888
      : ImageFormatGroup.nv21;

  static const _deviceOrientationDegrees = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  /// Rotation needed to make a frame from [camera] upright.
  ///
  /// iOS frames only need the sensor orientation; on Android the current
  /// device orientation has to be compensated for too.
  @visibleForTesting
  static InputImageRotation? rotationFor(
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    final sensorOrientation = camera.sensorOrientation;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }
    final deviceDegrees = _deviceOrientationDegrees[deviceOrientation];
    if (deviceDegrees == null) return null;
    final degrees = camera.lensDirection == CameraLensDirection.front
        ? (sensorOrientation + deviceDegrees) % 360
        : (sensorOrientation - deviceDegrees + 360) % 360;
    return InputImageRotationValue.fromRawValue(degrees);
  }

  /// Wraps a single-plane nv21 (Android) or bgra8888 (iOS) frame for ML Kit.
  /// Returns null for any other format.
  @visibleForTesting
  static InputImage? inputImageFrom(
    CameraImage image,
    InputImageRotation rotation,
  ) {
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final expected = defaultTargetPlatform == TargetPlatform.iOS
        ? InputImageFormat.bgra8888
        : InputImageFormat.nv21;
    if (format != expected || image.planes.length != 1) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format!,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  /// Runs detection on [image] and publishes the result to [latest].
  /// Drops the frame if a detection is already running.
  Future<void> processCameraImage(
    CameraImage image, {
    required CameraDescription camera,
    required DeviceOrientation deviceOrientation,
  }) async {
    if (_busy || _disposed) return;
    final rotation = rotationFor(camera, deviceOrientation);
    if (rotation == null) return;
    final inputImage = inputImageFrom(image, rotation);
    if (inputImage == null) return;

    _busy = true;
    try {
      final poses = await _detector.processImage(inputImage);
      if (_disposed) return;
      latest.value = PoseFrame(
        pose: poses.isEmpty ? null : poses.first,
        imageSize: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
      );
    } catch (e) {
      debugPrint('Pose detection failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// Closes the detector. Stop the camera image stream before calling this.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    latest.dispose();
    await _detector.close();
  }
}
