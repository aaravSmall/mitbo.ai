import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import 'package:mitbo/widgets/pose_mapping.dart';

// A raw landscape camera frame, as Android delivers it.
const _raw = Size(400, 300);

void main() {
  group('uprightImageSize', () {
    test('keeps width and height for 0 and 180 degrees', () {
      expect(uprightImageSize(_raw, InputImageRotation.rotation0deg), _raw);
      expect(uprightImageSize(_raw, InputImageRotation.rotation180deg), _raw);
    });

    test('swaps width and height for 90 and 270 degrees', () {
      const swapped = Size(300, 400);
      expect(uprightImageSize(_raw, InputImageRotation.rotation90deg), swapped);
      expect(
        uprightImageSize(_raw, InputImageRotation.rotation270deg),
        swapped,
      );
    });
  });

  group('mapToPreview', () {
    Offset map(
      Offset point,
      InputImageRotation rotation,
      Size previewSize, {
      PreviewFit fit = PreviewFit.cover,
      bool mirrored = false,
    }) => mapToPreview(
      point,
      imageSize: _raw,
      rotation: rotation,
      previewSize: previewSize,
      fit: fit,
      mirrored: mirrored,
    );

    for (final rotation in [
      InputImageRotation.rotation0deg,
      InputImageRotation.rotation180deg,
    ]) {
      test('scales a landscape preview at ${rotation.rawValue} degrees', () {
        const preview = Size(800, 600);
        expect(map(Offset.zero, rotation, preview), Offset.zero);
        expect(map(const Offset(100, 50), rotation, preview), Offset(200, 100));
        expect(
          map(const Offset(400, 300), rotation, preview),
          const Offset(800, 600),
        );
      });
    }

    for (final rotation in [
      InputImageRotation.rotation90deg,
      InputImageRotation.rotation270deg,
    ]) {
      test('scales a portrait preview at ${rotation.rawValue} degrees', () {
        // Upright image is 300x400, so a 600x800 preview is exactly 2x.
        const preview = Size(600, 800);
        expect(map(Offset.zero, rotation, preview), Offset.zero);
        expect(map(const Offset(100, 50), rotation, preview), Offset(200, 100));
        expect(
          map(const Offset(300, 400), rotation, preview),
          const Offset(600, 800),
        );
      });
    }

    test('letterboxes with contain when aspect ratios differ', () {
      // Upright 300x400 into a 600x600 square: scale 1.5, so the image is
      // 450x600 with 75px bars left and right.
      const preview = Size(600, 600);
      const rotation = InputImageRotation.rotation90deg;
      expect(
        map(Offset.zero, rotation, preview, fit: PreviewFit.contain),
        const Offset(75, 0),
      );
      expect(
        map(const Offset(150, 200), rotation, preview, fit: PreviewFit.contain),
        const Offset(300, 300),
      );
      expect(
        map(const Offset(300, 400), rotation, preview, fit: PreviewFit.contain),
        const Offset(525, 600),
      );
    });

    test('crops with cover when aspect ratios differ', () {
      // Upright 300x400 into a 600x600 square: scale 2, so the image is
      // 600x800 with 100px cropped top and bottom.
      const preview = Size(600, 600);
      const rotation = InputImageRotation.rotation90deg;
      expect(map(Offset.zero, rotation, preview), const Offset(0, -100));
      expect(
        map(const Offset(150, 200), rotation, preview),
        const Offset(300, 300),
      );
    });

    test('flips horizontally when mirrored', () {
      const preview = Size(800, 600);
      const rotation = InputImageRotation.rotation0deg;
      expect(
        map(const Offset(100, 50), rotation, preview, mirrored: true),
        const Offset(600, 100),
      );
    });
  });
}
