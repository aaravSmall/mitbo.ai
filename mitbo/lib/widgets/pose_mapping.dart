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

/// Scale and offset that place an upright image of [uprightSize] in a
/// preview of [previewSize], centered and scaled according to [fit].
///
/// Shared by every image-to-screen mapping (pose landmarks, holds, the
/// frozen frame on the hold marking screen) so they all line up.
class PreviewTransform {
  factory PreviewTransform({
    required Size uprightSize,
    required Size previewSize,
    PreviewFit fit = PreviewFit.cover,
    bool mirrored = false,
  }) {
    final scaleX = previewSize.width / uprightSize.width;
    final scaleY = previewSize.height / uprightSize.height;
    final scale = fit == PreviewFit.cover
        ? math.max(scaleX, scaleY)
        : math.min(scaleX, scaleY);
    return PreviewTransform._(
      uprightSize: uprightSize,
      previewSize: previewSize,
      scale: scale,
      offset: Offset(
        (previewSize.width - uprightSize.width * scale) / 2,
        (previewSize.height - uprightSize.height * scale) / 2,
      ),
      mirrored: mirrored,
    );
  }

  const PreviewTransform._({
    required this.uprightSize,
    required this.previewSize,
    required this.scale,
    required this.offset,
    required this.mirrored,
  });

  final Size uprightSize;
  final Size previewSize;

  /// Preview pixels per upright image pixel.
  final double scale;

  /// Where the image's top-left corner lands (before mirroring).
  final Offset offset;
  final bool mirrored;

  /// Where the whole image is drawn in the preview (before mirroring). With
  /// [PreviewFit.cover] it overflows the preview and gets cropped.
  Rect get imageRect => offset & (uprightSize * scale);

  /// Upright image pixels to preview pixels.
  Offset toPreview(Offset uprightPoint) {
    final x = uprightPoint.dx * scale + offset.dx;
    return Offset(
      mirrored ? previewSize.width - x : x,
      uprightPoint.dy * scale + offset.dy,
    );
  }

  /// Preview pixels back to upright image pixels.
  Offset toUpright(Offset previewPoint) {
    final x = mirrored ? previewSize.width - previewPoint.dx : previewPoint.dx;
    return Offset(
      (x - offset.dx) / scale,
      (previewPoint.dy - offset.dy) / scale,
    );
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
}) => PreviewTransform(
  uprightSize: uprightImageSize(imageSize, rotation),
  previewSize: previewSize,
  fit: fit,
  mirrored: mirrored,
).toPreview(point);

/// Maps a normalized upright-image point (0–1 on each axis, the convention
/// [ClimberKeypoints] and holds use) onto the preview.
Offset normalizedToPreview(
  Offset normalized, {
  required Size imageSize,
  required InputImageRotation rotation,
  required Size previewSize,
  PreviewFit fit = PreviewFit.cover,
  bool mirrored = false,
}) {
  final upright = uprightImageSize(imageSize, rotation);
  return PreviewTransform(
    uprightSize: upright,
    previewSize: previewSize,
    fit: fit,
    mirrored: mirrored,
  ).toPreview(
    Offset(normalized.dx * upright.width, normalized.dy * upright.height),
  );
}

/// Maps a preview point (e.g. a tap) to a normalized upright-image point,
/// the inverse of [normalizedToPreview]. Returns null when the point falls
/// outside the image (only possible with [PreviewFit.contain]).
Offset? previewToNormalized(
  Offset previewPoint, {
  required Size imageSize,
  required InputImageRotation rotation,
  required Size previewSize,
  PreviewFit fit = PreviewFit.cover,
  bool mirrored = false,
}) {
  final upright = uprightImageSize(imageSize, rotation);
  final point = PreviewTransform(
    uprightSize: upright,
    previewSize: previewSize,
    fit: fit,
    mirrored: mirrored,
  ).toUpright(previewPoint);
  final normalized = Offset(
    point.dx / upright.width,
    point.dy / upright.height,
  );
  const epsilon = 1e-9;
  if (normalized.dx < -epsilon ||
      normalized.dx > 1 + epsilon ||
      normalized.dy < -epsilon ||
      normalized.dy > 1 + epsilon) {
    return null;
  }
  return Offset(normalized.dx.clamp(0, 1), normalized.dy.clamp(0, 1));
}
