import 'dart:isolate';
import 'dart:ui';

import '../vision/hold_color.dart';
import '../vision/hold_segmenter.dart';
import '../vision/wall_frame.dart';
import 'hold.dart';
import 'hold_conversion.dart';

/// Finds holds in a frame — the seam where automatic detection plugs into
/// manual marking. Implementations return holds with [HoldSource.auto].
abstract interface class HoldDetector {
  /// Detects holds in [image]. With [targetColor], only holds of that color
  /// (the problem's color) should be returned.
  Future<List<Hold>> detect(WallFrame image, {HoldColor? targetColor});
}

/// Never finds anything; for when detection isn't wanted.
class NoopHoldDetector implements HoldDetector {
  const NoopHoldDetector();

  @override
  Future<List<Hold>> detect(WallFrame image, {HoldColor? targetColor}) async =>
      const [];
}

/// Color segmentation ([segmentHolds]), the same detection the automatic
/// problem finder uses. Needs a [targetColor]; finds nothing without one.
class SegmentingHoldDetector implements HoldDetector {
  const SegmentingHoldDetector({this.params = const SegmentationParams()});

  final SegmentationParams params;

  @override
  Future<List<Hold>> detect(WallFrame image, {HoldColor? targetColor}) async {
    if (targetColor == null) return const [];
    final params = this.params;
    // Segmenting a full-size frame takes long enough to drop UI frames.
    final detected = await Isolate.run(
      () => segmentHolds(image, targetColor, params: params),
    );
    final frameSize = Size(image.width.toDouble(), image.height.toDouble());
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return [
      for (var i = 0; i < detected.length; i++)
        holdFromDetected(
          detected[i],
          id: 'auto-$stamp-$i',
          frameSize: frameSize,
        ),
    ];
  }
}
