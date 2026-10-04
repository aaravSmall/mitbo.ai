import 'dart:typed_data';

import '../models/captured_frame.dart';

/// Pixel layouts the camera stream delivers (see
/// [PoseService.imageFormatGroup]).
enum RawFrameFormat {
  /// Android: a packed Y plane followed by interleaved V/U at half
  /// resolution, as one plane.
  nv21,

  /// iOS: 4 bytes per pixel, B, G, R, A.
  bgra8888,
}

/// The parts of a camera frame needed to convert it, as plain data so the
/// conversion can run in a background isolate.
class RawFrame {
  const RawFrame({
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.format,
    required this.rotationDegrees,
  });

  final Uint8List bytes;
  final int width;
  final int height;

  /// Row stride of the Y plane (nv21) or the pixel rows (bgra8888).
  final int bytesPerRow;
  final RawFrameFormat format;

  /// Clockwise rotation that makes the frame upright: 0, 90, 180 or 270.
  final int rotationDegrees;
}

/// Converts [raw] to an upright RGBA [CapturedFrame].
///
/// Top-level (not a closure) so it can be passed to `compute`.
CapturedFrame convertFrameToUpright(RawFrame raw) {
  final w = raw.width;
  final h = raw.height;
  final quarterTurns = (raw.rotationDegrees ~/ 90) % 4;
  final outWidth = quarterTurns.isOdd ? h : w;
  final outHeight = quarterTurns.isOdd ? w : h;
  final out = Uint8List(outWidth * outHeight * 4);
  final src = raw.bytes;
  final stride = raw.bytesPerRow;
  final chromaStart = stride * h;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int r, g, b;
      if (raw.format == RawFrameFormat.nv21) {
        final luma = src[y * stride + x];
        final chroma = chromaStart + (y >> 1) * stride + (x & ~1);
        final v = src[chroma] - 128;
        final u = src[chroma + 1] - 128;
        // BT.601 full-range YUV to RGB, in fixed point (x1024).
        r = luma + ((1436 * v) >> 10);
        g = luma - ((352 * u + 731 * v) >> 10);
        b = luma + ((1815 * u) >> 10);
      } else {
        final i = y * stride + x * 4;
        b = src[i];
        g = src[i + 1];
        r = src[i + 2];
      }

      // Clockwise rotation into the upright frame.
      final int ox, oy;
      switch (quarterTurns) {
        case 1:
          ox = h - 1 - y;
          oy = x;
        case 2:
          ox = w - 1 - x;
          oy = h - 1 - y;
        case 3:
          ox = y;
          oy = w - 1 - x;
        default:
          ox = x;
          oy = y;
      }
      final o = (oy * outWidth + ox) * 4;
      out[o] = r.clamp(0, 255);
      out[o + 1] = g.clamp(0, 255);
      out[o + 2] = b.clamp(0, 255);
      out[o + 3] = 255;
    }
  }
  return CapturedFrame(width: outWidth, height: outHeight, rgba: out);
}
