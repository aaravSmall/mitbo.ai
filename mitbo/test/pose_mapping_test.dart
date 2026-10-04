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

  group('normalized mapping', () {
    const allRotations = InputImageRotation.values;

    test('normalizedToPreview scales the upright frame for every rotation', () {
      for (final rotation in allRotations) {
        final upright = uprightImageSize(_raw, rotation);
        // A preview exactly 2x the upright frame.
        final preview = upright * 2;
        Offset toPreview(Offset n) => normalizedToPreview(
          n,
          imageSize: _raw,
          rotation: rotation,
          previewSize: preview,
        );
        expect(toPreview(Offset.zero), Offset.zero, reason: '$rotation');
        expect(
          toPreview(const Offset(1, 1)),
          Offset(preview.width, preview.height),
          reason: '$rotation',
        );
        expect(
          toPreview(const Offset(0.25, 0.5)),
          Offset(preview.width / 4, preview.height / 2),
          reason: '$rotation',
        );
      }
    });

    test('previewToNormalized inverts normalizedToPreview for every rotation, '
        'fit and mirroring', () {
      const points = [
        Offset(0, 0),
        Offset(1, 1),
        Offset(0.3, 0.7),
        Offset(0.9, 0.05),
      ];
      for (final rotation in allRotations) {
        for (final fit in PreviewFit.values) {
          for (final mirrored in [false, true]) {
            for (final point in points) {
              final args = (
                imageSize: _raw,
                rotation: rotation,
                previewSize: const Size(390, 700),
                fit: fit,
                mirrored: mirrored,
              );
              final preview = normalizedToPreview(
                point,
                imageSize: args.imageSize,
                rotation: args.rotation,
                previewSize: args.previewSize,
                fit: args.fit,
                mirrored: args.mirrored,
              );
              final back = previewToNormalized(
                preview,
                imageSize: args.imageSize,
                rotation: args.rotation,
                previewSize: args.previewSize,
                fit: args.fit,
                mirrored: args.mirrored,
              );
              // With cover, edge points may be cropped off-screen but
              // still map back exactly.
              expect(back, isNotNull, reason: '$args $point');
              expect(back!.dx, closeTo(point.dx, 1e-9), reason: '$args');
              expect(back.dy, closeTo(point.dy, 1e-9), reason: '$args');
            }
          }
        }
      }
    });

    test('previewToNormalized maps a tap to the right spot (90 degrees)', () {
      // Upright 300x400 into 600x800: exactly 2x.
      expect(
        previewToNormalized(
          const Offset(150, 600),
          imageSize: _raw,
          rotation: InputImageRotation.rotation90deg,
          previewSize: const Size(600, 800),
        ),
        const Offset(0.25, 0.75),
      );
    });

    test('previewToNormalized returns null in contain letterbox bars', () {
      // Upright 300x400 in a 600x600 square: 75px bars left and right.
      Offset? tap(Offset point) => previewToNormalized(
        point,
        imageSize: _raw,
        rotation: InputImageRotation.rotation90deg,
        previewSize: const Size(600, 600),
        fit: PreviewFit.contain,
      );
      expect(tap(const Offset(10, 300)), isNull);
      expect(tap(const Offset(590, 300)), isNull);
      expect(tap(const Offset(75, 0)), Offset.zero);
      expect(tap(const Offset(300, 300)), const Offset(0.5, 0.5));
    });
  });
}
