import 'package:flutter/foundation.dart';

import '../beta/beta_narration.dart';
import '../beta/beta_planner.dart';
import '../beta/beta_tracker.dart';
import '../models/climber_keypoints.dart';
import '../models/climber_profile.dart';
import '../services/beta_narrator.dart';
import '../services/pose_service.dart';
import '../vision/problem_detector.dart';
import '../vision/start_detector.dart';
import 'problem_session.dart';

/// How the beta is spoken.
enum CueMode {
  /// One move at a time, as the climber climbs: the next cue fires when
  /// the previous move is done (v2).
  live,

  /// The whole beta read out once when the problem locks (v1).
  upfront,
}

/// Used when no profile is available (shouldn't happen past onboarding).
const _fallbackProfile = ClimberProfile(heightCm: 170, wingspanCm: 170);

/// Coaches the climber through the locked problem's beta.
///
/// Once [ProblemSession] locks a problem and plans a beta, follows the
/// climber with a [BetaTracker] on the live pose stream and, in
/// [CueMode.live], speaks each step as the previous one is done. When the
/// climber goes off-beta it replans from the holds they're on; when they
/// come off the wall it waits for them to get back on the start.
class ClimbCoach extends ChangeNotifier {
  ClimbCoach({
    required ProblemSession session,
    required ValueListenable<PoseFrame?> frames,
    required BetaNarrator narrator,
    ClimberProfile? Function()? profile,
    Duration Function()? clock,
    TrackerParams trackerParams = const TrackerParams(),
    CueMode mode = CueMode.live,
  }) : _session = session,
       _frames = frames,
       _narrator = narrator,
       _profile = profile ?? (() => null),
       _clock = clock ?? _stopwatchClock(),
       _trackerParams = trackerParams,
       _mode = mode {
    _session.addListener(_onSession);
    _frames.addListener(_onFrame);
    _onSession();
  }

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final ProblemSession _session;
  final ValueListenable<PoseFrame?> _frames;
  final BetaNarrator _narrator;
  final ClimberProfile? Function() _profile;
  final Duration Function() _clock;
  final TrackerParams _trackerParams;
  CueMode _mode;

  BetaTracker? _tracker;
  BetaPlan? _sessionBeta;
  List<String> _lastCues = const [];
  bool _disposed = false;

  CueMode get mode => _mode;

  /// Switches how cues are spoken; cuts off anything being said.
  set mode(CueMode value) {
    if (_disposed || value == _mode) return;
    _mode = value;
    _narrator.stop();
    notifyListeners();
  }

  /// The beta being followed: the session's plan, or a replan after the
  /// climber went off-beta. Null when no problem is locked.
  BetaPlan? get plan => _tracker?.plan ?? _session.beta;

  /// Where the climber is in the climb, or null when no problem is locked.
  ClimbState? get state => _tracker?.state;

  /// The step the climber is on, or null.
  BetaStep? get currentStep => _tracker?.currentStep;

  /// The hold the climber's next hand move goes to (index into the
  /// problem's holds), or null.
  int? get nextTargetHold {
    final tracker = _tracker;
    if (tracker == null || tracker.state != ClimbState.climbing) return null;
    return tracker.nextTargetHold;
  }

  /// Hand moves done and in total, in the beta being followed.
  int get movesDone => _tracker?.nextStep ?? 0;
  int get totalMoves => _tracker?.steps.length ?? 0;

  /// True while following a replan rather than the original beta.
  bool get replanned {
    final tracker = _tracker;
    return tracker != null && !identical(tracker.plan, tracker.originalPlan);
  }

  /// The last thing said (for display), or empty.
  List<String> get lastCues => _lastCues;

  /// Repeats the current cue (live), or the whole beta (upfront).
  void replay() {
    final tracker = _tracker;
    if (_disposed || tracker == null) return;
    switch (_mode) {
      case CueMode.upfront:
        _say(betaCues(tracker.plan));
      case CueMode.live:
        final step = _currentStepCue(tracker);
        _say(
          tracker.state == ClimbState.climbing && step.isNotEmpty
              ? step
              : _lastCues,
        );
    }
  }

  void _onSession() {
    if (_disposed) return;
    final beta = _session.beta;
    final problem = _session.problem;
    if (identical(beta, _sessionBeta)) return;
    _sessionBeta = beta;
    if (beta == null || problem == null) {
      if (_tracker != null) {
        _tracker = null;
        _lastCues = const [];
        _narrator.stop();
        notifyListeners();
      }
      return;
    }
    final tracker = _tracker = BetaTracker(
      problem: problem,
      plan: beta,
      params: _trackerParams,
    );
    switch (_mode) {
      case CueMode.upfront:
        _say(betaCues(beta));
      case CueMode.live:
        _say([
          liveIntro(beta, colorName: problem.color.name),
          ..._currentStepCue(tracker),
        ]);
    }
    notifyListeners();
  }

  void _onFrame() {
    final tracker = _tracker;
    final frame = _frames.value;
    if (_disposed || tracker == null || frame == null) return;
    final event = tracker.onPose(frame.keypoints, _clock());
    if (event == null) return;
    final live = _mode == CueMode.live;
    switch (event) {
      case StepCompleted():
        if (live) _say(_currentStepCue(tracker));
      case ClimbSent():
        if (live) _say(const [sentCue]);
      case OffBeta(:final leftHold, :final rightHold):
        final replan = _replan(tracker, leftHold, rightHold, frame.keypoints);
        tracker.replan(replan);
        if (live && replan != null && replan.moves.isNotEmpty) {
          _say([newBetaCue, ..._currentStepCue(tracker)]);
        }
      case OffWall(:final afterSend):
        if (live && !afterSend) _say(const [offWallCue]);
      case BackOnStart():
        if (live) _say([fromStartCue, ..._currentStepCue(tracker)]);
    }
    notifyListeners();
  }

  List<String> _currentStepCue(BetaTracker tracker) {
    final step = tracker.currentStep;
    return step == null ? const [] : [stepCue(tracker.plan, step)];
  }

  /// Plans a new beta from the climber's hands on [leftHold] and
  /// [rightHold], keeping the wall scale of the current plan. Null if it
  /// can't be planned.
  BetaPlan? _replan(
    BetaTracker tracker,
    int leftHold,
    int rightHold,
    ClimberKeypoints keypoints,
  ) {
    final size = _session.problemImageSize;
    if (size == null || size.height == 0) return null;
    final problem = tracker.problem;
    Keypoint on(int hold) =>
        Keypoint(problem.holds[hold].centerX, problem.holds[hold].centerY, 1);
    try {
      return planBeta(
        DetectedProblem(
          color: problem.color,
          holds: problem.holds,
          startHoldIndices: {leftHold, rightHold}.toList(),
          warnings: problem.warnings,
        ),
        StartPosition(
          leftHand: on(leftHold),
          rightHand: on(rightHold),
          leftFoot: keypoints.leftFoot,
          rightFoot: keypoints.rightFoot,
          hipCenter: keypoints.hipCenter,
          shoulderCenter: keypoints.shoulderCenter,
          // Hands on hold centers: matched exactly when on one hold.
          matchedDistance: 0,
        ),
        profile: _profile() ?? _fallbackProfile,
        aspect: size.width / size.height,
        scale: (
          cmPerUnit: tracker.plan.cmPerUnit,
          fromBody: tracker.plan.scaleFromBody,
        ),
      );
    } catch (e) {
      debugPrint('Replanning failed: $e');
      return null;
    }
  }

  void _say(List<String> cues) {
    if (cues.isEmpty) return;
    _lastCues = List.unmodifiable(cues);
    _narrator.narrate(cues);
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_onSession);
    _frames.removeListener(_onFrame);
    super.dispose();
  }
}
