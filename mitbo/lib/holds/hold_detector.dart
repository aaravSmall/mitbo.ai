import 'dart:ui';

import '../models/captured_frame.dart';
import 'hold.dart';

/// Finds holds in a captured frame — the seam where automatic detection
/// plugs in. Implementations return holds with [HoldSource.auto].
abstract interface class HoldDetector {
  /// Detects holds in [image]. With [targetColor], only holds of roughly
  /// that color (the problem's color) should be returned.
  Future<List<Hold>> detect(CapturedFrame image, {Color? targetColor});
}

/// Placeholder until real detection exists: never finds anything.
class NoopHoldDetector implements HoldDetector {
  const NoopHoldDetector();

  @override
  Future<List<Hold>> detect(CapturedFrame image, {Color? targetColor}) async =>
      const [];
}
