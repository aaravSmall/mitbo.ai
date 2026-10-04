import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/models/captured_frame.dart';
import 'package:mitbo/services/frame_converter.dart';

/// A 4x2 NV21 frame with neutral chroma, so each pixel is gray = its luma.
RawFrame _grayNv21(int rotationDegrees) => RawFrame(
  bytes: Uint8List.fromList([
    10, 20, 30, 40, //
    50, 60, 70, 80,
    128, 128, 128, 128, // V U V U
  ]),
  width: 4,
  height: 2,
  bytesPerRow: 4,
  format: RawFrameFormat.nv21,
  rotationDegrees: rotationDegrees,
);

/// Red channel of every pixel, row by row.
List<List<int>> _reds(CapturedFrame frame) => [
  for (var y = 0; y < frame.height; y++)
    [
      for (var x = 0; x < frame.width; x++)
        frame.rgba[(y * frame.width + x) * 4],
    ],
];

void main() {
  group('nv21', () {
    test('neutral chroma gives gray pixels with full alpha', () {
      final frame = convertFrameToUpright(_grayNv21(0));
      expect(frame.width, 4);
      expect(frame.height, 2);
      for (var i = 0; i < frame.rgba.length; i += 4) {
        expect(frame.rgba[i], frame.rgba[i + 1]);
        expect(frame.rgba[i], frame.rgba[i + 2]);
        expect(frame.rgba[i + 3], 255);
      }
    });

    test('converts chroma to color', () {
      final frame = convertFrameToUpright(
        RawFrame(
          // Strong V (red), neutral U.
          bytes: Uint8List.fromList([128, 128, 128, 128, 255, 128]),
          width: 2,
          height: 2,
          bytesPerRow: 2,
          format: RawFrameFormat.nv21,
          rotationDegrees: 0,
        ),
      );
      expect(frame.rgba.sublist(0, 4), [255, 38, 128, 255]);
    });

    test('rotation 0 keeps the layout', () {
      expect(_reds(convertFrameToUpright(_grayNv21(0))), [
        [10, 20, 30, 40],
        [50, 60, 70, 80],
      ]);
    });

    test('rotation 90 turns the frame clockwise and swaps its size', () {
      expect(_reds(convertFrameToUpright(_grayNv21(90))), [
        [50, 10],
        [60, 20],
        [70, 30],
        [80, 40],
      ]);
    });

    test('rotation 180 turns the frame upside down', () {
      expect(_reds(convertFrameToUpright(_grayNv21(180))), [
        [80, 70, 60, 50],
        [40, 30, 20, 10],
      ]);
    });

    test('rotation 270 turns the frame counter-clockwise', () {
      expect(_reds(convertFrameToUpright(_grayNv21(270))), [
        [40, 80],
        [30, 70],
        [20, 60],
        [10, 50],
      ]);
    });
  });

  test('bgra8888 swaps channels to RGBA and skips row padding', () {
    final frame = convertFrameToUpright(
      RawFrame(
        bytes: Uint8List.fromList([
          1, 2, 3, 255, 4, 5, 6, 255, 0, 0, 0, 0, // row 0 + padding
          7, 8, 9, 255, 10, 11, 12, 255, 0, 0, 0, 0, // row 1 + padding
        ]),
        width: 2,
        height: 2,
        bytesPerRow: 12,
        format: RawFrameFormat.bgra8888,
        rotationDegrees: 0,
      ),
    );
    expect(frame.rgba, [
      3, 2, 1, 255, 6, 5, 4, 255, //
      9, 8, 7, 255, 12, 11, 10, 255,
    ]);
  });
}
