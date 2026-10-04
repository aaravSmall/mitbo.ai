import 'dart:typed_data';

/// A single camera frame, rotated upright and converted to RGBA.
///
/// Its pixel space is the same upright space pose landmarks and holds are
/// normalized against, so (x / width, y / height) is a normalized point.
class CapturedFrame {
  CapturedFrame({required this.width, required this.height, required this.rgba})
    : assert(rgba.length == width * height * 4);

  final int width;
  final int height;

  /// Row-major RGBA bytes, 4 per pixel, no row padding.
  final Uint8List rgba;
}
