import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../models/climber_keypoints.dart';

/// The most recent pose detection result, plus what's needed to map its
/// landmark coordinates (which are in source-image space) onto the preview.
@immutable
class PoseFrame {
  const PoseFrame({
    required this.pose,
    required this.imageSize,
    required this.rotation,
    required this.keypoints,
  });

  /// The detected pose, or null if no one was found in the frame.
  final Pose? pose;

  /// Size of the raw camera image, before [rotation] is applied.
  final Size imageSize;

  /// Rotation from [imageSize] to the upright space the landmark
  /// coordinates are in. Always 0° on iOS, where the camera plugin already
  /// delivers upright frames.
  final InputImageRotation rotation;

  /// Smoothed hands, feet and hip center derived from [pose]
  /// ([ClimberKeypoints.none] when no one is in frame).
  final ClimberKeypoints keypoints;
}

/// Creates the detector for [model]; injectable for tests.
typedef PoseDetectorFactory = PoseDetector Function(PoseDetectionModel model);

PoseDetector _createDetector(PoseDetectionModel model) => PoseDetector(
  options: PoseDetectorOptions(model: model, mode: PoseDetectionMode.stream),
);

/// Runs ML Kit pose detection (stream mode) on camera frames.
///
/// Owns the [PoseDetector]. Frames that arrive while a detection is still
/// in flight are dropped, so a slow detector never backs up the camera.
class PoseService {
  PoseService({
    PoseDetectionModel model = PoseDetectionModel.base,
    PoseDetectorFactory createDetector = _createDetector,
    KeypointSmoother? smoother,
  }) : _model = model,
       _createDetectorFor = createDetector,
       _detector = createDetector(model),
       _smoother = smoother ?? KeypointSmoother();

  final PoseDetectorFactory _createDetectorFor;
  PoseDetectionModel _model;
  PoseDetector _detector;
  final KeypointSmoother _smoother;
  final ValueNotifier<PoseFrame?> latest = ValueNotifier(null);

  /// How far hands are moved from the wrist toward the knuckles (0–1).
  /// See [ClimberKeypoints.fromPose].
  double handNudge = 0.5;

  bool _busy = false;
  bool _disposed = false;
  bool _paused = false;

  // The detection currently running, so a model switch can wait for it
  // before closing the detector it's running on.
  Future<void>? _inFlight;

  // Bumped by [reset] so a detection already in flight is discarded.
  int _session = 0;

  /// The pose model currently in use.
  PoseDetectionModel get model => _model;

  /// Smoothing weight of the newest frame; see [KeypointSmoother.alpha].
  double get alpha => _smoother.alpha;
  set alpha(double value) => _smoother.alpha = value;

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

  /// Whether detection is paused (e.g. while the user marks holds). Frames
  /// are ignored while paused; unpausing resets, so nothing stale from
  /// before the pause is published.
  bool get paused => _paused;
  set paused(bool value) {
    if (value == _paused) return;
    _paused = value;
    if (!value) reset();
  }

  /// Rotation of the space ML Kit reports landmark coordinates in, for a
  /// frame whose upright [rotation] is as given. ML Kit ignores the rotation
  /// on iOS (frames already arrive upright), so its coordinates are in the
  /// raw image's space there.
  static InputImageRotation coordinateRotation(InputImageRotation rotation) =>
      defaultTargetPlatform == TargetPlatform.iOS
      ? InputImageRotation.rotation0deg
      : rotation;

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
    if (_busy || _disposed || _paused) return;
    final rotation = rotationFor(camera, deviceOrientation);
    if (rotation == null) return;
    final inputImage = inputImageFrom(image, rotation);
    if (inputImage == null) return;

    _busy = true;
    final session = _session;
    final detection = _detector.processImage(inputImage);
    _inFlight = detection;
    try {
      final poses = await detection;
      if (_disposed || session != _session) return;
      final pose = poses.isEmpty ? null : poses.first;
      final imageSize = Size(image.width.toDouble(), image.height.toDouble());
      final coordinateRotation = PoseService.coordinateRotation(rotation);
      final raw = pose == null
          ? ClimberKeypoints.none
          : ClimberKeypoints.fromPose(
              pose,
              imageWidth: imageSize.width,
              imageHeight: imageSize.height,
              rotation: coordinateRotation,
              handNudge: handNudge,
            );
      latest.value = PoseFrame(
        pose: pose,
        imageSize: imageSize,
        rotation: coordinateRotation,
        keypoints: _smoother.smooth(raw),
      );
    } catch (e) {
      if (session == _session) debugPrint('Pose detection failed: $e');
    } finally {
      // After a model switch the busy flag belongs to the new detector.
      if (identical(_inFlight, detection)) {
        _inFlight = null;
        _busy = false;
      }
    }
  }

  /// Switches to the [model] pose model.
  ///
  /// The new detector takes the next frame. The old one is closed once any
  /// detection still running on it finishes, and that result is discarded.
  Future<void> setModel(PoseDetectionModel model) async {
    if (_disposed || model == _model) return;
    final oldDetector = _detector;
    final oldDetection = _inFlight;
    _model = model;
    _detector = _createDetectorFor(model);
    // Nothing is running on the new detector yet.
    _busy = false;
    _inFlight = null;
    reset();
    await _closeAfter(oldDetector, oldDetection);
  }

  /// Closes [detector] once [detection] (if any) has finished, so a
  /// detector is never closed mid-call. Callers don't await this, so
  /// errors are logged rather than thrown.
  static Future<void> _closeAfter(
    PoseDetector detector,
    Future<void>? detection,
  ) async {
    try {
      await detection;
    } catch (_) {
      // Its result is being discarded anyway.
    }
    try {
      await detector.close();
    } catch (e) {
      debugPrint('Failed to close pose detector: $e');
    }
  }

  /// Clears the latest result and smoothing history, and discards any
  /// detection still in flight. Call when the camera (re)starts.
  void reset() {
    if (_disposed) return;
    _session++;
    _smoother.reset();
    latest.value = null;
  }

  /// Closes the detector. Stop the camera image stream before calling this.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    latest.dispose();
    await _closeAfter(_detector, _inFlight);
  }
}
