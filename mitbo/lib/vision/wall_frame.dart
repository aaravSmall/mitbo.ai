import 'dart:typed_data';

/// A small, upright RGB snapshot of the camera image.
///
/// Pixels are in the same upright orientation that pose keypoints are
/// normalized in (see `ClimberKeypoints`), so a keypoint at normalized
/// (nx, ny) and [sampleNormalized] (nx, ny) refer to the same spot on the
/// wall. Pure Dart, so it can be built and analyzed off the UI isolate.
class WallFrame {
  WallFrame(this.width, this.height, this.rgb)
    : assert(width > 0 && height > 0),
      assert(rgb.length == width * height * 3);

  final int width;
  final int height;

  /// Packed RGB, row-major, 3 bytes per pixel.
  final Uint8List rgb;

  /// The (r, g, b) of the pixel at ([x], [y]).
  (int, int, int) pixel(int x, int y) {
    final i = (y * width + x) * 3;
    return (rgb[i], rgb[i + 1], rgb[i + 2]);
  }

  /// Pixel column for normalized x (0 = left edge, 1 = right), clamped.
  int columnAt(double nx) => (nx * width).floor().clamp(0, width - 1);

  /// Pixel row for normalized y (0 = top edge, 1 = bottom), clamped.
  int rowAt(double ny) => (ny * height).floor().clamp(0, height - 1);

  /// The pixel at normalized upright coordinates, clamped to the frame.
  (int, int, int) sampleNormalized(double nx, double ny) =>
      pixel(columnAt(nx), rowAt(ny));
}

/// Camera frame formats the converter understands.
enum RawFrameFormat {
  /// Android: full-res Y plane followed by interleaved V/U at half res.
  nv21,

  /// iOS: 4 bytes per pixel, blue first.
  bgra8888,
}

/// A copy of one camera frame's bytes, plus what's needed to make it
/// upright. Holds only sendable data so it can cross to another isolate.
class RawFrame {
  const RawFrame({
    required this.format,
    required this.bytes,
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.rotationDegrees,
  });

  final RawFrameFormat format;
  final Uint8List bytes;

  /// Raw image size, before rotation.
  final int width;
  final int height;

  /// Row stride of the (first) plane, in bytes.
  final int bytesPerRow;

  /// Clockwise rotation (0, 90, 180 or 270) that makes the image upright —
  /// the same rotation the pose landmark coordinates are in.
  final int rotationDegrees;

  /// Converts to an upright [WallFrame] at most [targetWidth] pixels wide.
  WallFrame toWallFrame({int targetWidth = defaultWallFrameWidth}) =>
      switch (format) {
        RawFrameFormat.nv21 => wallFrameFromNv21(
          bytes,
          width,
          height,
          bytesPerRow,
          rotationDegrees,
          targetWidth: targetWidth,
        ),
        RawFrameFormat.bgra8888 => wallFrameFromBgra(
          bytes,
          width,
          height,
          bytesPerRow,
          rotationDegrees,
          targetWidth: targetWidth,
        ),
      };
}

/// Default width of the upright snapshot. Small enough to segment in a few
/// tens of milliseconds, large enough to resolve individual holds.
const defaultWallFrameWidth = 320;

/// Builds an upright, downsampled [WallFrame] from an NV21 buffer.
///
/// [rotationDegrees] is the clockwise rotation that makes the raw image
/// upright. The output is at most [targetWidth] wide (never upscaled) and
/// keeps the upright aspect ratio. Out-of-range bytes read as mid-gray
/// rather than throwing, so a short buffer can't crash the caller.
WallFrame wallFrameFromNv21(
  Uint8List bytes,
  int width,
  int height,
  int bytesPerRow,
  int rotationDegrees, {
  int targetWidth = defaultWallFrameWidth,
}) {
  final uvStart = bytesPerRow * height;
  int byteAt(int i) => i < bytes.length ? bytes[i] : 128;

  void write(int x, int y, Uint8List out, int o) {
    final luma = byteAt(y * bytesPerRow + x);
    final uv = uvStart + (y >> 1) * bytesPerRow + (x & ~1);
    final v = byteAt(uv) - 128;
    final u = byteAt(uv + 1) - 128;
    // BT.601 full-range YCbCr -> RGB.
    out[o] = _clampByte(luma + 1.402 * v);
    out[o + 1] = _clampByte(luma - 0.344136 * u - 0.714136 * v);
    out[o + 2] = _clampByte(luma + 1.772 * u);
  }

  return _buildUpright(width, height, rotationDegrees, targetWidth, write);
}

/// Builds an upright, downsampled [WallFrame] from a BGRA8888 buffer.
/// See [wallFrameFromNv21] for the parameters.
WallFrame wallFrameFromBgra(
  Uint8List bytes,
  int width,
  int height,
  int bytesPerRow,
  int rotationDegrees, {
  int targetWidth = defaultWallFrameWidth,
}) {
  int byteAt(int i) => i < bytes.length ? bytes[i] : 128;

  void write(int x, int y, Uint8List out, int o) {
    final i = y * bytesPerRow + x * 4;
    out[o] = byteAt(i + 2);
    out[o + 1] = byteAt(i + 1);
    out[o + 2] = byteAt(i);
  }

  return _buildUpright(width, height, rotationDegrees, targetWidth, write);
}

/// Upright size of a [width] x [height] image after [rotationDegrees].
(int, int) uprightSize(int width, int height, int rotationDegrees) =>
    rotationDegrees == 90 || rotationDegrees == 270
    ? (height, width)
    : (width, height);

/// Raw pixel that upright pixel ([u], [v]) comes from, for a raw image of
/// [width] x [height] rotated clockwise by [rotationDegrees].
///
/// Rotating clockwise by 90° sends raw (x, y) to upright (height-1-y, x);
/// this is the inverse of that (and of 180° / 270°).
(int, int) rawPixelFor(
  int u,
  int v,
  int width,
  int height,
  int rotationDegrees,
) => switch (rotationDegrees) {
  90 => (v, height - 1 - u),
  180 => (width - 1 - u, height - 1 - v),
  270 => (width - 1 - v, u),
  _ => (u, v),
};

typedef _PixelWriter = void Function(int x, int y, Uint8List out, int offset);

WallFrame _buildUpright(
  int width,
  int height,
  int rotationDegrees,
  int targetWidth,
  _PixelWriter write,
) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('Frame size must be positive, got ${width}x$height');
  }
  final rotation = ((rotationDegrees % 360) + 360) % 360;
  if (rotation % 90 != 0) {
    throw ArgumentError.value(rotationDegrees, 'rotationDegrees');
  }
  final (uprightWidth, uprightHeight) = uprightSize(width, height, rotation);
  final outWidth = targetWidth < uprightWidth ? targetWidth : uprightWidth;
  final scale = uprightWidth / outWidth;
  final outHeight = (uprightHeight / scale).round().clamp(1, uprightHeight);
  final scaleY = uprightHeight / outHeight;

  final out = Uint8List(outWidth * outHeight * 3);
  var o = 0;
  for (var oy = 0; oy < outHeight; oy++) {
    // Nearest neighbour at the center of each output pixel.
    final v = ((oy + 0.5) * scaleY).floor().clamp(0, uprightHeight - 1);
    for (var ox = 0; ox < outWidth; ox++) {
      final u = ((ox + 0.5) * scale).floor().clamp(0, uprightWidth - 1);
      final (x, y) = rawPixelFor(u, v, width, height, rotation);
      write(x, y, out, o);
      o += 3;
    }
  }
  return WallFrame(outWidth, outHeight, out);
}

int _clampByte(double value) {
  final rounded = value.round();
  return rounded < 0 ? 0 : (rounded > 255 ? 255 : rounded);
}
