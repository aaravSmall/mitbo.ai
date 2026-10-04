import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/holds/hold.dart';
import 'package:mitbo/holds/hold_detector.dart';
import 'package:mitbo/holds/hold_geometry.dart';
import 'package:mitbo/holds/problem.dart';
import 'package:mitbo/models/captured_frame.dart';

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
CapturedFrame _frame(
  int width,
  int height,
  Color Function(int x, int y) colorAt,
) {
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final c = colorAt(x, y).toARGB32();
      final i = (y * width + x) * 4;
      rgba[i] = (c >> 16) & 0xff;
      rgba[i + 1] = (c >> 8) & 0xff;
      rgba[i + 2] = c & 0xff;
      rgba[i + 3] = 255;
    }
  }
  return CapturedFrame(width: width, height: height, rgba: rgba);
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
        targetColor: const Color(0xFFFF0000),
      ),
      isEmpty,
    );
  });
}
