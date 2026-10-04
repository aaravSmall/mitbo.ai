import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// How the camera image is scaled to fill the preview area.
enum PreviewFit {
  /// Scale to fit entirely inside the preview, letterboxing the spare space.
  contain,

  /// Scale to fill the preview, cropping whatever overflows.
  cover,
}

/// Size of the image after [rotation] has been applied, which is the space
/// ML Kit reports landmark coordinates in.
Size uprightImageSize(Size imageSize, InputImageRotation rotation) {
  switch (rotation) {
    case InputImageRotation.rotation90deg:
    case InputImageRotation.rotation270deg:
      return Size(imageSize.height, imageSize.width);
    case InputImageRotation.rotation0deg:
    case InputImageRotation.rotation180deg:
      return imageSize;
  }
}

/// Maps a landmark [point] from ML Kit's (upright) image space onto a
/// preview of [previewSize], centered and scaled according to [fit].
///
/// [imageSize] is the raw camera image size, before [rotation]. When
/// [mirrored] is true the result is flipped horizontally, for a preview
/// that's displayed mirrored (e.g. a selfie camera).
Offset mapToPreview(
  Offset point, {
  required Size imageSize,
  required InputImageRotation rotation,
  required Size previewSize,
  PreviewFit fit = PreviewFit.cover,
  bool mirrored = false,
}) {
  final upright = uprightImageSize(imageSize, rotation);
  final scaleX = previewSize.width / upright.width;
  final scaleY = previewSize.height / upright.height;
  final scale = fit == PreviewFit.cover
      ? math.max(scaleX, scaleY)
      : math.min(scaleX, scaleY);
  final dx = (previewSize.width - upright.width * scale) / 2;
  final dy = (previewSize.height - upright.height * scale) / 2;

  final x = point.dx * scale + dx;
  return Offset(mirrored ? previewSize.width - x : x, point.dy * scale + dy);
}
