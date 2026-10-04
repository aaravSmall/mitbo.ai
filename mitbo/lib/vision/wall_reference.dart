import '../models/climber_keypoints.dart';
import 'wall_frame.dart';

/// Keeps a clean snapshot of the wall, taken while nobody is in frame.
///
/// Hold colors are sampled from this rather than the live frame, because
/// when the climber is touching a hold, their hand is covering it.
///
/// Time is passed in (as the camera session's elapsed time) so the logic
/// is deterministic and testable.
class WallReferenceTracker {
  WallReferenceTracker({
    this.clearFor = const Duration(seconds: 1),
    this.refreshEvery = const Duration(seconds: 5),
  });

  /// How long the frame must be empty before a reference is taken.
  final Duration clearFor;

  /// While the wall stays empty, retake the reference this often, so a
  /// lighting change or a nudged phone doesn't leave it stale.
  final Duration refreshEvery;

  Duration _now = Duration.zero;
  Duration? _clearSince;
  WallFrame? _reference;
  Duration? _referenceTime;

  /// The latest clean wall snapshot, if one has been taken.
  WallFrame? get reference => _reference;

  /// How old [reference] is, or null if there isn't one.
  Duration? get referenceAge =>
      _referenceTime == null ? null : _now - _referenceTime!;

  /// True when nobody has been in frame for at least [clearFor].
  bool get isClear => _clearSince != null && _now - _clearSince! >= clearFor;

  /// True when a new snapshot should be grabbed and passed to
  /// [setReference].
  bool get wantsCapture =>
      isClear &&
      (_referenceTime == null || _now - _referenceTime! >= refreshEvery);

  /// Feeds one pose result. Any confidently detected body point means
  /// someone is in frame.
  void onPose(ClimberKeypoints keypoints, Duration time) {
    _now = time;
    final occupied = ClimberPoint.values.any((p) => keypoints[p] != null);
    if (occupied) {
      _clearSince = null;
    } else {
      _clearSince ??= time;
    }
  }

  /// Stores [frame] as the reference if the wall is still clear (someone
  /// may have walked in while it was being grabbed). Returns whether it
  /// was kept.
  bool setReference(WallFrame frame, Duration time) {
    if (time > _now) _now = time;
    if (!isClear) return false;
    _reference = frame;
    _referenceTime = time;
    return true;
  }

  /// Forgets everything, e.g. when the camera restarts (the phone may
  /// have moved).
  void reset() {
    _now = Duration.zero;
    _clearSince = null;
    _reference = null;
    _referenceTime = null;
  }
}
