import 'package:flutter_test/flutter_test.dart';

import 'package:mitbo/models/climber_keypoints.dart';
import 'package:mitbo/vision/problem_detector.dart';
import 'package:mitbo/vision/start_detector.dart';
import 'package:mitbo/vision/wall_frame.dart';

import 'support/synthetic_wall.dart';

const _w = 320;
const _h = 400;

/// Red problem, plus a couple of blue holds from another problem.
const _redHolds = [(150, 40), (200, 120), (140, 200), (100, 300), (180, 310)];
const _blueHolds = [(60, 300), (250, 200)];

WallFrame _wall() {
  final wall = SyntheticWall(_w, _h);
  for (final (x, y) in _redHolds) {
    wall.disc(x, y, 8, wallRed);
  }
  for (final (x, y) in _blueHolds) {
    wall.disc(x, y, 8, wallBlue);
  }
  return wall.frame;
}

Keypoint _at(int x, int y) => Keypoint((x + 0.5) / _w, (y + 0.5) / _h, 0.9);

StartPosition _start((int, int) left, (int, int) right) => StartPosition(
  leftHand: _at(left.$1, left.$2),
  rightHand: _at(right.$1, right.$2),
);

void main() {
  test('finds the red problem from hands on two red start holds', () {
    final result = detectProblem(_wall(), _start((100, 300), (180, 310)));
    expect(result, isA<ProblemFound>());
    final problem = (result as ProblemFound).problem;
    expect(problem.color.name, 'red');
    expect(problem.holds, hasLength(_redHolds.length));
    // Holds are sorted top to bottom, so the start holds are the last two.
    expect(problem.startHoldIndices, [3, 4]);
    expect(problem.topHold!.centerY, closeTo((40 + 0.5) / _h, 0.01));
    expect(problem.warnings, isEmpty);
  });

  test('a hand just off the edge of a hold still finds it', () {
    final result = detectProblem(_wall(), _start((110, 300), (180, 310)));
    final problem = (result as ProblemFound).problem;
    expect(problem.startHoldIndices, [3, 4]);
  });

  test('matched hands on one start hold give one start hold', () {
    final result = detectProblem(_wall(), _start((138, 200), (142, 200)));
    final problem = (result as ProblemFound).problem;
    expect(problem.holds, hasLength(_redHolds.length));
    expect(problem.startHoldIndices, [2]);
  });

  test('hands on two different colors pick one and warn', () {
    final result = detectProblem(_wall(), _start((100, 300), (60, 300)));
    final problem = (result as ProblemFound).problem;
    expect(problem.warnings, isNotEmpty);
    expect(problem.warnings.first, contains('different colors'));
    expect(problem.startHoldIndices, hasLength(1));
    final name = problem.color.name;
    expect(name, anyOf('red', 'blue'));
    expect(
      problem.holds,
      hasLength(name == 'red' ? _redHolds.length : _blueHolds.length),
    );
  });

  test('prefers a real color over a hand reading bare wall', () {
    final result = detectProblem(_wall(), _start((290, 350), (180, 310)));
    final problem = (result as ProblemFound).problem;
    expect(problem.color.name, 'red');
    expect(problem.startHoldIndices, [4]);
    expect(problem.warnings, isNotEmpty);
  });

  test('fails with a reason when the hands are over bare wall', () {
    final result = detectProblem(_wall(), _start((250, 350), (290, 350)));
    expect(result, isA<ProblemFailed>());
    expect((result as ProblemFailed).reason, contains('gray'));
  });

  test('fails when no color can be read under the hands', () {
    final wall = SyntheticWall(_w, _h);
    for (var y = 0; y < _h; y++) {
      for (var x = 0; x < _w; x++) {
        // A different saturated hue on every pixel: no coherent color.
        wall.set(x, y, saturatedHue(((x * 37 + y * 101) % 360).toDouble()));
      }
    }
    final result = detectProblem(wall.frame, _start((100, 100), (200, 100)));
    expect(result, isA<ProblemFailed>());
    expect(
      (result as ProblemFailed).reason,
      contains("Couldn't read a hold color"),
    );
  });
}
