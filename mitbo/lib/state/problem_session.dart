import 'dart:isolate';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../beta/beta_planner.dart';
import '../models/climber_profile.dart';
import '../services/pose_service.dart';
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

  /// Problem found and locked in.
  locked,

  /// Detection failed. Moving the hands to a new start retries.
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

/// Drives automatic problem detection from the live pose stream: keeps a
/// clean wall reference, waits for the climber to settle on the start
/// holds, finds the problem's holds by color, then plans a beta for the
/// climber's reach.
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

  // Bumped whenever in-flight async work (grabs, detections) should be
  // discarded: restart, reset, a newer detection.
  int _generation = 0;

  ProblemPhase get phase => _phase;

  /// The locked problem, when [phase] is [ProblemPhase.locked].
  DetectedProblem? get problem => _problem;

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
  Size? get problemImageSize {
    final frame = _detectionReference;
    if (frame == null || _problem == null) return null;
    return Size(frame.width.toDouble(), frame.height.toDouble());
  }

  SegmentationParams get params => _params;

  /// Changes segmentation thresholds (debug tuning). Re-runs the last
  /// detection, if any, so the effect is visible immediately.
  set params(SegmentationParams value) {
    _params = value;
    final reference = _detectionReference;
    final start = _detectionStart;
    if (reference != null &&
        start != null &&
        (_phase == ProblemPhase.locked || _phase == ProblemPhase.failed)) {
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

    if ((_phase == ProblemPhase.ready || _phase == ProblemPhase.failed) &&
        _tracker.reference != null) {
      final start = _startDetector.onPose(keypoints, now);
      if (start != null) _runDetection(_tracker.reference!, start);
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
        _phase = ProblemPhase.locked;
        _problem = problem;
        _beta = _plan(problem, reference, start);
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
    WallFrame reference,
    StartPosition start,
  ) {
    try {
      return planBeta(
        problem,
        start,
        profile: _profile() ?? _defaultProfile,
        aspect: reference.width / reference.height,
      );
    } catch (e) {
      debugPrint('Beta planning failed: $e');
      return null;
    }
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
  }

  @override
  void dispose() {
    _disposed = true;
    _frames.removeListener(_onFrame);
    super.dispose();
  }
}
