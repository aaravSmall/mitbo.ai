import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/holds/hold.dart';
import 'package:mitbo/holds/hold_detector.dart';
import 'package:mitbo/holds/problem.dart';
import 'package:mitbo/models/captured_frame.dart';
import 'package:mitbo/screens/hold_marking_screen.dart';

const _wallColor = Color(0xFFC81E28);

/// A 60x80 frame of solid [_wallColor].
CapturedFrame _solidFrame() {
  const width = 60, height = 80;
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < rgba.length; i += 4) {
    rgba
      ..[i] = 0xC8
      ..[i + 1] = 0x1E
      ..[i + 2] = 0x28
      ..[i + 3] = 255;
  }
  return CapturedFrame(width: width, height: height, rgba: rgba);
}

class _FakeDetector implements HoldDetector {
  _FakeDetector(this.result);

  final List<Hold> result;
  final calls = <Color?>[];

  @override
  Future<List<Hold>> detect(CapturedFrame image, {Color? targetColor}) async {
    calls.add(targetColor);
    return result;
  }
}

/// Opens the marking screen from a host page and records what it pops.
Future<List<Object?>> _open(WidgetTester tester, HoldDetector detector) async {
  final results = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final result = await Navigator.of(context).push<Problem>(
              MaterialPageRoute(
                builder: (_) => HoldMarkingScreen(
                  args: HoldMarkingArgs(
                    frame: _solidFrame(),
                    previewAspectRatio: 60 / 80,
                  ),
                  detector: detector,
                ),
              ),
            );
            results.add(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

final _canvas = find.byKey(const Key('hold-canvas'));

void main() {
  testWidgets('add and delete a hold, then pick a color and get detected '
      'holds', (tester) async {
    final detector = _FakeDetector(const [
      Hold(
        id: 'auto-1',
        center: Offset(0.2, 0.2),
        radius: 0.05,
        source: HoldSource.auto,
      ),
      Hold(
        id: 'auto-2',
        center: Offset(0.8, 0.8),
        radius: 0.05,
        source: HoldSource.auto,
      ),
    ]);
    final results = await _open(tester, detector);
    expect(find.text('0 holds'), findsOneWidget);
    expect(find.text('Tap a hold on the wall to mark it.'), findsOneWidget);

    // Tap empty space: a manual hold is added and selected.
    await tester.tap(_canvas);
    await tester.pump();
    expect(find.text('1 hold'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete hold'));
    await tester.pump();
    expect(find.text('0 holds'), findsOneWidget);

    // Add it again, deselect, and pick the problem color from it.
    await tester.tap(_canvas);
    await tester.pump();
    await tester.tap(find.byTooltip('Deselect hold'));
    await tester.pump();
    await tester.tap(find.text('Pick problem color'));
    await tester.pump();
    await tester.tap(_canvas);
    await tester.pumpAndSettle();

    expect(detector.calls, hasLength(1));
    expect(detector.calls.single?.toARGB32(), _wallColor.toARGB32());
    expect(find.text('3 holds'), findsOneWidget);
    expect(find.text('Added 2 holds.'), findsOneWidget);
    expect(find.byTooltip('Problem color'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final problem = results.single! as Problem;
    expect(problem.holds, hasLength(3));
    expect(problem.color?.toARGB32(), _wallColor.toARGB32());
    expect(problem.frameSize, const Size(60, 80));
    final manual = problem.holds.first;
    expect(manual.source, HoldSource.manual);
    expect(manual.center.dx, closeTo(0.5, 0.01));
    expect(manual.center.dy, closeTo(0.5, 0.01));
    expect(manual.color?.toARGB32(), _wallColor.toARGB32());
    expect(problem.holds.skip(1).map((h) => h.id), ['auto-1', 'auto-2']);
  });

  testWidgets('an empty detection result is handled gracefully', (
    tester,
  ) async {
    await _open(tester, const NoopHoldDetector());
    await tester.tap(_canvas);
    await tester.pump();
    await tester.tap(find.byTooltip('Deselect hold'));
    await tester.pump();
    await tester.tap(find.text('Pick problem color'));
    await tester.pump();
    await tester.tap(_canvas);
    await tester.pumpAndSettle();

    expect(find.text('1 hold'), findsOneWidget);
    expect(
      find.text(
        'No other holds found for this color yet. Tap to add them by hand.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Problem color'), findsOneWidget);
  });

  testWidgets('tapping a hold selects it and tapping again deselects', (
    tester,
  ) async {
    await _open(tester, const NoopHoldDetector());
    await tester.tap(_canvas);
    await tester.pump();
    expect(find.byTooltip('Delete hold'), findsOneWidget);

    await tester.tap(_canvas);
    await tester.pump();
    expect(find.byTooltip('Delete hold'), findsNothing);
    expect(find.text('1 hold'), findsOneWidget);

    await tester.tap(_canvas);
    await tester.pump();
    expect(find.byTooltip('Delete hold'), findsOneWidget);
  });

  testWidgets('cancel returns nothing', (tester) async {
    final results = await _open(tester, const NoopHoldDetector());
    await tester.tap(_canvas);
    await tester.pump();
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });
}
