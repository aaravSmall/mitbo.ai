import 'dart:isolate';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../beta/beta_planner.dart';
import '../holds/hold_conversion.dart';
import '../holds/problem.dart';
import '../models/climber_profile.dart';
import '../services/pose_service.dart';
import '../vision/hold_color.dart';
import '../vision/hold_segmenter.dart';
import '../vision/problem_detector.dart';
import '../vision/start_detector.dart';
import '../vision/wall_frame.dart';
import '../vision/wall_reference.dart';

/// Where the live problem detection is at.
enum ProblemPhase {
  /// No clean wall snapshot yet: the climber needs to step out of frame.
  scanningWall,

  /// Wall scanned; waiting for the climber to settle on the start holds.
  ready,

  /// Start detected; working out the problem.
  detecting,

  /// Problem found automatically; waiting for the user to confirm the
  /// holds ([ProblemSession.confirmProblem]) or fix them by hand
  /// ([ProblemSession.applyManualProblem]). No beta yet.
  confirming,

  /// Problem confirmed (or marked by hand) and locked in, with a beta.
  locked,

  /// Detection failed. Moving the hands to a new start retries, or the
  /// holds can be marked by hand.
  failed,
}

/// Runs [detectProblem]; injectable for tests.
typedef ProblemDetectionRunner =
    Future<ProblemResult> Function(
      WallFrame reference,
      StartPosition start,
      SegmentationParams params,
    );

Future<ProblemResult> _detectInIsolate(
  WallFrame reference,
  StartPosition start,
  SegmentationParams params,
) => Isolate.run(() => detectProblem(reference, start, params: params));

/// Used when no profile is available (shouldn't happen past onboarding).
const _defaultProfile = ClimberProfile(heightCm: 170, wingspanCm: 170);

/// Drives problem detection from the live pose stream: keeps a clean wall
/// reference, waits for the climber to settle on the start holds, finds the
/// problem's holds by color, has the user confirm them, then plans a beta
/// for the climber's reach.
///
/// Holds marked by hand ([applyManualProblem]) replace automatic detection:
/// for fixing a wrong detection, or as a fallback when it fails.
class ProblemSession extends ChangeNotifier {
  ProblemSession({
    required ValueListenable<PoseFrame?> frames,
    required Future<WallFrame?> Function() grabFrame,
    ProblemDetectionRunner detect = _detectInIsolate,
    ClimberProfile? Function()? profile,
    Duration Function()? clock,
    WallReferenceTracker? referenceTracker,
    StartDetector? startDetector,
  }) : _frames = frames,
       _grabFrame = grabFrame,
       _detect = detect,
       _profile = profile ?? (() => null),
       _clock = clock ?? _stopwatchClock(),
       _tracker = referenceTracker ?? WallReferenceTracker(),
       _startDetector = startDetector ?? StartDetector() {
    _frames.addListener(_onFrame);
  }

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final ValueListenable<PoseFrame?> _frames;
  final Future<WallFrame?> Function() _grabFrame;
  final ProblemDetectionRunner _detect;
  final ClimberProfile? Function() _profile;
  final Duration Function() _clock;
  final WallReferenceTracker _tracker;
  final StartDetector _startDetector;

  ProblemPhase _phase = ProblemPhase.scanningWall;
  DetectedProblem? _problem;
  BetaPlan? _beta;
  String? _failureReason;
  SegmentationParams _params = const SegmentationParams();
  bool _grabbing = false;
  bool _disposed = false;

  // What the last detection ran on, so a params change can re-run it.
  WallFrame? _detectionReference;
  StartPosition? _detectionStart;

  // Upright size of the frame the current problem's holds are normalized
  // against (the detection reference, or the frame holds were marked on).
  Size? _problemFrameSize;

  // True when the current problem's holds were marked by hand.
  bool _manual = false;

  // Bumped whenever in-flight async work (grabs, detections) should be
  // discarded: restart, reset, a newer detection.
  int _generation = 0;

  ProblemPhase get phase => _phase;

  /// The problem: awaiting confirmation in [ProblemPhase.confirming],
  /// locked in [ProblemPhase.locked]. Holds marked by hand also show here
  /// in [ProblemPhase.ready] while waiting for the climber's start.
  DetectedProblem? get problem => _problem;

  /// Whether [problem]'s holds were marked by hand.
  bool get isManual => _manual && _problem != null;

  /// The planned beta for [problem], when [phase] is [ProblemPhase.locked].
  BetaPlan? get beta => _beta;

  /// Why detection failed, when [phase] is [ProblemPhase.failed].
  String? get failureReason => _failureReason;

  /// The latest clean wall snapshot (for debug display).
  WallFrame? get reference => _tracker.reference;

  /// How old [reference] is.
  Duration? get referenceAge => _tracker.referenceAge;

  /// Size of the snapshot the problem was detected on: the space the
  /// problem's normalized hold coordinates should be mapped from.
  Size? get problemImageSize => _problem == null ? null : _problemFrameSize;

  SegmentationParams get params => _params;

  /// Changes segmentation thresholds (debug tuning). Re-runs the last
  /// detection, if any, so the effect is visible immediately.
  set params(SegmentationParams value) {
    _params = value;
    final reference = _detectionReference;
    final start = _detectionStart;
    // Never re-detect over holds the user marked by hand.
    if (reference != null &&
        start != null &&
        !_manual &&
        (_phase == ProblemPhase.confirming ||
            _phase == ProblemPhase.locked ||
            _phase == ProblemPhase.failed)) {
      _runDetection(reference, start);
    }
  }

  void _onFrame() {
    if (_disposed) return;
    final frame = _frames.value;
    if (frame == null) return;
    final now = _clock();
    final keypoints = frame.keypoints;

    _tracker.onPose(keypoints, now);
    if (_tracker.wantsCapture && !_grabbing) _grabReference();

    if (_phase == ProblemPhase.ready || _phase == ProblemPhase.failed) {
      if (_manual && _problem != null) {
        // Holds marked by hand: just wait for the start to plan from.
        final start = _startDetector.onPose(keypoints, now);
        if (start != null) _lockManual(start);
      } else if (_tracker.reference != null) {
        final start = _startDetector.onPose(keypoints, now);
        if (start != null) _runDetection(_tracker.reference!, start);
      }
    }
  }

  Future<void> _grabReference() async {
    _grabbing = true;
    final generation = _generation;
    WallFrame? frame;
    try {
      frame = await _grabFrame();
    } catch (e) {
      debugPrint('Wall reference grab failed: $e');
    }
    if (_disposed || generation != _generation) return;
    _grabbing = false;
    if (frame == null || !_tracker.setReference(frame, _clock())) return;
    if (_phase == ProblemPhase.scanningWall) {
      _phase = ProblemPhase.ready;
      notifyListeners();
    }
  }

  Future<void> _runDetection(WallFrame reference, StartPosition start) async {
    final generation = ++_generation;
    // A grab in flight is discarded by the generation bump; let a new one
    // start when the wall is next clear.
    _grabbing = false;
    _detectionReference = reference;
    _detectionStart = start;
    _phase = ProblemPhase.detecting;
    _problem = null;
    _beta = null;
    _failureReason = null;
    _manual = false;
    notifyListeners();

    ProblemResult result;
    try {
      result = await _detect(reference, start, _params);
    } catch (e) {
      debugPrint('Problem detection failed: $e');
      result = const ProblemFailed('Something went wrong reading the problem');
    }
    if (_disposed || generation != _generation) return;

    switch (result) {
      case ProblemFound(:final problem):
        // Shown for the user to confirm; the beta waits for that.
        _phase = ProblemPhase.confirming;
        _problem = problem;
        _problemFrameSize = Size(
          reference.width.toDouble(),
          reference.height.toDouble(),
        );
      case ProblemFailed(:final reason):
        _phase = ProblemPhase.failed;
        _failureReason = reason;
        // Retry once the climber moves to a (new) start.
        _startDetector.reset(requireMove: true);
    }
    notifyListeners();
  }

  BetaPlan? _plan(
    DetectedProblem problem,
    Size frameSize,
    StartPosition start,
  ) {
    try {
      return planBeta(
        problem,
        start,
        profile: _profile() ?? _defaultProfile,
        aspect: frameSize.width / frameSize.height,
      );
    } catch (e) {
      debugPrint('Beta planning failed: $e');
      return null;
    }
  }

  /// Accepts the automatically detected holds and plans the beta.
  void confirmProblem() {
    final problem = _problem;
    final size = _problemFrameSize;
    final start = _detectionStart;
    if (_disposed || _phase != ProblemPhase.confirming) return;
    if (problem == null || size == null || start == null) return;
    _phase = ProblemPhase.locked;
    _beta = _plan(problem, size, start);
    notifyListeners();
  }

  /// Uses holds the user marked by hand ([marked]) as the problem,
  /// replacing any automatic detection.
  ///
  /// If the climber's start is already known (the user is fixing a
  /// detection, or detection failed after they got on the wall), the
  /// problem locks and the beta is planned right away. Otherwise it waits
  /// in [ProblemPhase.ready] for them to settle on the start holds. Marking
  /// no holds is the same as [resetProblem].
  void applyManualProblem(Problem marked) {
    if (_disposed) return;
    if (marked.holds.isEmpty) {
      resetProblem();
      return;
    }
    _generation++; // Discards a detection or grab in flight.
    _grabbing = false;
    final holds = [
      for (final hold in marked.holds) detectedFromHold(hold, marked.frameSize),
    ]..sort((a, b) => a.centerY.compareTo(b.centerY)); // Top to bottom.
    final markedColor = marked.color;
    final color = markedColor != null
        ? holdColorFromColor(markedColor, tolerance: _params.tolerance)
        : _problem?.color ?? HoldColor.unknown;

    _manual = true;
    _problem = DetectedProblem(
      color: color,
      holds: holds,
      startHoldIndices: const [],
    );
    _problemFrameSize = marked.frameSize;
    _beta = null;
    _failureReason = null;

    final start = _detectionStart;
    if (start != null) {
      _lockManual(start);
      return;
    }
    _startDetector.reset();
    _phase = ProblemPhase.ready;
    notifyListeners();
  }

  /// Locks hand-marked holds once the climber's [start] is known.
  void _lockManual(StartPosition start) {
    final problem = _problem;
    final size = _problemFrameSize;
    if (problem == null || size == null) return;
    final startIndices = startHoldIndicesFor(problem.holds, start);
    final locked = DetectedProblem(
      color: problem.color,
      holds: problem.holds,
      startHoldIndices: startIndices,
      warnings: [
        if (startIndices.isEmpty) 'No marked hold is under your start hands',
      ],
    );
    _detectionStart = start;
    _problem = locked;
    _phase = ProblemPhase.locked;
    _beta = _plan(locked, size, start);
    notifyListeners();
  }

  /// Drops the current problem and waits for a new start, keeping the
  /// wall reference.
  void resetProblem() {
    if (_disposed) return;
    _generation++;
    _grabbing = false;
    _clearProblem();
    _startDetector.reset();
    _phase = _tracker.reference == null
        ? ProblemPhase.scanningWall
        : ProblemPhase.ready;
    notifyListeners();
  }

  /// Starts over from scratch, e.g. when the camera restarts (the phone
  /// may have moved, so the wall reference is stale too).
  void restart() {
    if (_disposed) return;
    _generation++;
    _grabbing = false;
    _clearProblem();
    _tracker.reset();
    _startDetector.reset();
    _phase = ProblemPhase.scanningWall;
    notifyListeners();
  }

  void _clearProblem() {
    _problem = null;
    _beta = null;
    _failureReason = null;
    _detectionReference = null;
    _detectionStart = null;
    _problemFrameSize = null;
    _manual = false;
  }

  @override
  void dispose() {
    _disposed = true;
    _frames.removeListener(_onFrame);
    super.dispose();
  }
}
