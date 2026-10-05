import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/holds/hold.dart';
import 'package:mitbo/holds/hold_conversion.dart';
import 'package:mitbo/holds/hold_detector.dart';
import 'package:mitbo/holds/hold_geometry.dart';
import 'package:mitbo/holds/problem.dart';
import 'package:mitbo/vision/hold_color.dart';
import 'package:mitbo/vision/hold_segmenter.dart';
import 'package:mitbo/vision/problem_detector.dart';
import 'package:mitbo/vision/wall_frame.dart';

import 'support/synthetic_wall.dart';

Hold _hold(
  String id,
  double x,
  double y, {
  double radius = 0.05,
  HoldSource source = HoldSource.manual,
  Color? color,
}) => Hold(
  id: id,
  center: Offset(x, y),
  radius: radius,
  source: source,
  color: color,
);

/// A [width] x [height] frame whose pixels are colored by [colorAt].
WallFrame _frame(int width, int height, Color Function(int x, int y) colorAt) {
  final rgb = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = colorAt(x, y).toARGB32();
      final i = (y * width + x) * 3;
      rgb[i] = (c >> 16) & 0xff;
      rgb[i + 1] = (c >> 8) & 0xff;
      rgb[i + 2] = c & 0xff;
    }
  }
  return WallFrame(width, height, rgb);
}

void main() {
  group('serialization', () {
    test('Hold round-trips through JSON, with and without a color', () {
      final holds = [
        _hold('a', 0.25, 0.75, radius: 0.04),
        _hold(
          'b',
          0,
          1,
          radius: 0.1,
          source: HoldSource.auto,
          color: const Color(0xFF12AB34),
        ),
      ];
      for (final hold in holds) {
        final encoded = jsonEncode(hold.toJson());
        final decoded = Hold.fromJson(
          jsonDecode(encoded) as Map<String, Object?>,
        );
        expect(decoded, hold);
        expect(decoded.hashCode, hold.hashCode);
      }
    });

    test('Problem round-trips through JSON', () {
      final problem = Problem(
        holds: [
          _hold('a', 0.1, 0.2),
          _hold('b', 0.3, 0.4, source: HoldSource.auto),
        ],
        color: const Color(0xFFFF8800),
        frameSize: const Size(720, 1280),
      );
      final decoded = Problem.fromJson(
        jsonDecode(jsonEncode(problem.toJson())) as Map<String, Object?>,
      );
      expect(decoded, problem);
      expect(decoded.hashCode, problem.hashCode);
    });

    test('Problem without a color or holds round-trips', () {
      final problem = Problem(holds: const [], frameSize: const Size(10, 20));
      final decoded = Problem.fromJson(
        jsonDecode(jsonEncode(problem.toJson())) as Map<String, Object?>,
      );
      expect(decoded, problem);
      expect(decoded.color, isNull);
    });

    test('rejects an unknown problem version', () {
      final json = Problem(
        holds: const [],
        frameSize: const Size(1, 1),
      ).toJson()..['version'] = 99;
      expect(() => Problem.fromJson(json), throwsFormatException);
    });
  });

  group('value semantics', () {
    test('holds and problems compare by value', () {
      expect(_hold('a', 0.1, 0.2), _hold('a', 0.1, 0.2));
      expect(_hold('a', 0.1, 0.2), isNot(_hold('a', 0.1, 0.3)));
      expect(
        Problem(holds: [_hold('a', 0.1, 0.2)], frameSize: const Size(1, 2)),
        Problem(holds: [_hold('a', 0.1, 0.2)], frameSize: const Size(1, 2)),
      );
      expect(
        Problem(holds: [_hold('a', 0.1, 0.2)], frameSize: const Size(1, 2)),
        isNot(Problem(holds: const [], frameSize: const Size(1, 2))),
      );
    });

    test("a problem's holds can't be modified", () {
      final source = [_hold('a', 0.1, 0.2)];
      final problem = Problem(holds: source, frameSize: const Size(1, 1));
      source.add(_hold('b', 0.3, 0.4));
      expect(problem.holds, hasLength(1));
      expect(() => problem.holds.add(_hold('c', 0, 0)), throwsUnsupportedError);
    });
  });

  group('hitTestHolds', () {
    const square = Size(100, 100);

    test('selects the hold whose circle contains the tap', () {
      final holds = [_hold('a', 0.2, 0.2), _hold('b', 0.7, 0.7)];
      expect(
        hitTestHolds(holds, const Offset(0.22, 0.21), frameSize: square)?.id,
        'a',
      );
      expect(
        hitTestHolds(holds, const Offset(0.7, 0.68), frameSize: square)?.id,
        'b',
      );
    });

    test('returns null for empty space', () {
      final holds = [_hold('a', 0.2, 0.2)];
      expect(
        hitTestHolds(holds, const Offset(0.5, 0.5), frameSize: square),
        isNull,
      );
      expect(
        hitTestHolds(const [], const Offset(0.5, 0.5), frameSize: square),
        isNull,
      );
    });

    test('accepts taps within slop of the edge, but not beyond', () {
      // Radius 5px; slop 1.5px.
      final holds = [_hold('a', 0.5, 0.5)];
      expect(
        hitTestHolds(holds, const Offset(0.56, 0.5), frameSize: square)?.id,
        'a',
      );
      expect(
        hitTestHolds(holds, const Offset(0.57, 0.5), frameSize: square),
        isNull,
      );
      expect(
        hitTestHolds(
          holds,
          const Offset(0.56, 0.5),
          frameSize: square,
          slop: 0,
        ),
        isNull,
      );
    });

    test('a small hold inside a big one stays selectable', () {
      final big = _hold('big', 0.5, 0.5, radius: 0.2);
      final small = _hold('small', 0.6, 0.5, radius: 0.03);
      final holds = [big, small];
      expect(
        hitTestHolds(holds, const Offset(0.6, 0.5), frameSize: square)?.id,
        'small',
      );
      expect(
        hitTestHolds(holds, const Offset(0.45, 0.5), frameSize: square)?.id,
        'big',
      );
    });

    test('between overlapping holds, the relatively closer center wins', () {
      final holds = [_hold('a', 0.45, 0.5), _hold('b', 0.53, 0.5)];
      expect(
        hitTestHolds(holds, const Offset(0.47, 0.5), frameSize: square)?.id,
        'a',
      );
      expect(
        hitTestHolds(holds, const Offset(0.5, 0.5), frameSize: square)?.id,
        'b',
      );
    });

    test('works for holds at the edges of the frame', () {
      final holds = [_hold('left', 0.01, 0.5), _hold('corner', 0.98, 0.99)];
      expect(
        hitTestHolds(holds, const Offset(0, 0.5), frameSize: square)?.id,
        'left',
      );
      expect(
        hitTestHolds(holds, const Offset(1, 1), frameSize: square)?.id,
        'corner',
      );
    });

    test('measures distance in pixels on a non-square frame', () {
      // 100x200 portrait: radius 0.05 = 5px. 0.03 down is 6px away (miss);
      // 0.04 across is 4px away (hit).
      const portrait = Size(100, 200);
      final holds = [_hold('a', 0.5, 0.5)];
      expect(
        hitTestHolds(
          holds,
          const Offset(0.5, 0.534),
          frameSize: portrait,
          slop: 0,
        ),
        isNull,
      );
      expect(
        hitTestHolds(
          holds,
          const Offset(0.54, 0.5),
          frameSize: portrait,
          slop: 0,
        )?.id,
        'a',
      );
    });
  });

  group('averageColorInCircle', () {
    const red = Color(0xFFFF0000);
    const blue = Color(0xFF0000FF);

    test('returns the color of a solid area', () {
      final frame = _frame(40, 40, (_, _) => const Color(0xFF336699));
      expect(
        averageColorInCircle(frame, const Offset(0.5, 0.5), 0.2)?.toARGB32(),
        0xFF336699,
      );
    });

    test('only samples inside the circle', () {
      // Left half red, right half blue; a circle in the left half is red.
      final frame = _frame(40, 40, (x, _) => x < 20 ? red : blue);
      expect(
        averageColorInCircle(frame, const Offset(0.25, 0.5), 0.1)?.toARGB32(),
        red.toARGB32(),
      );
    });

    test('averages a circle straddling two colors', () {
      final frame = _frame(40, 40, (x, _) => x < 20 ? red : blue);
      final color = averageColorInCircle(frame, const Offset(0.5, 0.5), 0.25)!;
      expect(color.toARGB32() >> 16 & 0xff, closeTo(128, 2));
      expect(color.toARGB32() & 0xff, closeTo(128, 2));
      expect(color.toARGB32() >> 8 & 0xff, 0);
    });

    test('clips circles at the frame edge', () {
      final frame = _frame(40, 40, (x, y) => x < 4 ? red : blue);
      expect(
        averageColorInCircle(frame, const Offset(0, 0.5), 0.1)?.toARGB32(),
        red.toARGB32(),
      );
    });

    test('returns null when the circle covers no pixels', () {
      final frame = _frame(10, 10, (_, _) => red);
      expect(averageColorInCircle(frame, const Offset(0.5, 0.5), 0), isNull);
      expect(averageColorInCircle(frame, const Offset(3, 3), 0.1), isNull);
    });
  });

  test('NoopHoldDetector finds nothing', () async {
    final frame = _frame(2, 2, (_, _) => const Color(0xFF000000));
    expect(await const NoopHoldDetector().detect(frame), isEmpty);
    expect(
      await const NoopHoldDetector().detect(
        frame,
        targetColor: const HoldColor(hue: 0, saturation: 1, value: 1),
      ),
      isEmpty,
    );
  });

  group('SegmentingHoldDetector', () {
    test('finds the holds of the target color as auto holds', () async {
      final wall = SyntheticWall(200, 300)
        ..disc(40, 50, 10, wallRed)
        ..disc(150, 200, 12, wallRed)
        ..disc(100, 120, 10, wallBlue);
      const red = HoldColor(hue: 0, saturation: 0.82, value: 0.86);

      final holds = await const SegmentingHoldDetector().detect(
        wall.frame,
        targetColor: red,
      );

      expect(holds, hasLength(2));
      expect(holds.every((h) => h.source == HoldSource.auto), isTrue);
      expect(holds.map((h) => h.id).toSet(), hasLength(2));
      // Sorted top to bottom, centered on the discs.
      expect(holds[0].center.dx, closeTo(40.5 / 200, 0.01));
      expect(holds[0].center.dy, closeTo(50.5 / 300, 0.01));
      expect(holds[1].center.dx, closeTo(150.5 / 200, 0.01));
      // Radius covers the disc: ~10px of a 200px shorter side.
      expect(holds[0].radius, closeTo(10.5 / 200, 0.01));
    });

    test('finds nothing without a target color', () async {
      final wall = SyntheticWall(50, 50)..disc(25, 25, 8, wallRed);
      expect(await const SegmentingHoldDetector().detect(wall.frame), isEmpty);
    });
  });

  group('conversion', () {
    const frameSize = Size(200, 400);

    test('a hold becomes a box around its circle and back', () {
      final hold = _hold('a', 0.5, 0.25, radius: 0.1);
      final detected = detectedFromHold(hold, frameSize);
      // 0.1 of the 200px shorter side = 20px: 0.1 across, 0.05 down.
      expect(detected.left, closeTo(0.4, 1e-9));
      expect(detected.right, closeTo(0.6, 1e-9));
      expect(detected.top, closeTo(0.2, 1e-9));
      expect(detected.bottom, closeTo(0.3, 1e-9));
      expect(detected.centerX, 0.5);
      expect(detected.centerY, 0.25);

      final back = holdFromDetected(detected, id: 'a', frameSize: frameSize);
      expect(back.center, hold.center);
      expect(back.radius, closeTo(hold.radius, 1e-9));
      expect(back.source, HoldSource.auto);
    });

    test('a detected hold gets a circle covering its larger side', () {
      const detected = DetectedHold(
        left: 0.1,
        top: 0.1,
        right: 0.3, // 40px wide
        bottom: 0.125, // 10px tall
        centerX: 0.2,
        centerY: 0.11,
        pixelArea: 300,
        areaFraction: 300 / 80000,
        fillRatio: 0.75,
      );
      final hold = holdFromDetected(detected, id: 'x', frameSize: frameSize);
      expect(hold.center, const Offset(0.2, 0.11));
      expect(hold.radius, closeTo(20 / 200, 1e-9));
    });

    test('problemFromDetected keeps order, color and frame size', () {
      const blue = HoldColor(hue: 230, saturation: 0.8, value: 0.85);
      final problem = problemFromDetected(
        DetectedProblem(
          color: blue,
          holds: [
            detectedFromHold(_hold('a', 0.5, 0.2), frameSize),
            detectedFromHold(_hold('b', 0.4, 0.7), frameSize),
          ],
          startHoldIndices: const [1],
        ),
        frameSize,
      );
      expect(problem.holds.map((h) => h.id), ['auto-0', 'auto-1']);
      expect(problem.holds.map((h) => h.center.dy), [0.2, 0.7]);
      expect(problem.frameSize, frameSize);
      expect(problem.color, isNotNull);
      expect(problem.holds.every((h) => h.color == problem.color), isTrue);
    });

    test('colors convert between display and HSV', () {
      for (final color in const [
        Color(0xFFDC2828),
        Color(0xFF283CDC),
        Color(0xFFE6D228),
        Color(0xFF30A050),
      ]) {
        final hsv = holdColorFromColor(color);
        expect(hsv.achromatic, isFalse);
        final back = colorFromHoldColor(hsv).toARGB32();
        for (final shift in [16, 8, 0]) {
          expect(
            (back >> shift) & 0xff,
            closeTo((color.toARGB32() >> shift) & 0xff, 1),
          );
        }
      }
    });

    test('grays and dark colors are achromatic', () {
      expect(holdColorFromColor(const Color(0xFF808080)).achromatic, isTrue);
      expect(holdColorFromColor(const Color(0xFFF0F0F0)).achromatic, isTrue);
      expect(holdColorFromColor(const Color(0xFF100505)).achromatic, isTrue);
    });
  });
}
