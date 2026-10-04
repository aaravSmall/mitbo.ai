import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../beta/beta_narration.dart';
import '../beta/beta_planner.dart';
import '../services/beta_narrator.dart';
import '../services/frame_grabber.dart';
import '../services/pose_service.dart';
import '../state/problem_session.dart';
import '../state/profile_controller.dart';
import '../vision/hold_segmenter.dart';
import '../widgets/hold_overlay.dart';
import '../widgets/pose_debug_chip.dart';
import '../widgets/pose_debug_sheet.dart';
import '../widgets/pose_overlay.dart';
import '../widgets/problem_debug_panel.dart';
import '../widgets/problem_status_pill.dart';

enum _CameraStatus {
  checking,
  needsRationale,
  requesting,
  permanentlyDenied,
  restricted,
  starting,
  ready,
  error,
}

/// Shows a live back-camera preview once camera permission is granted, and
/// runs pose tracking and automatic problem detection on the camera's image
/// stream.
///
/// Draws the detected skeleton and the locked problem's holds (numbered
/// in beta order) over the preview, with a status pill for detection
/// progress. Once a problem locks, the beta is read aloud with on-device
/// text-to-speech. Debug builds add a bug icon in the app bar for a
/// pose/holds readout and live tuning.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, this.profileController, this.narrator});

  /// Source of the climber's height and wingspan for the beta.
  final ProfileController? profileController;

  /// Speaks the beta; defaults to the device's TTS. Injectable for tests.
  final BetaNarrator? narrator;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  _CameraStatus _status = _CameraStatus.checking;
  CameraController? _controller;
  String? _errorMessage;
  final PoseService _poseService = PoseService();
  final FrameGrabber _frameGrabber = FrameGrabber();
  late final ProblemSession _problemSession;
  late final BetaNarrator _narrator = widget.narrator ?? BetaNarrator();

  // The beta most recently read aloud, so each one is narrated once.
  BetaPlan? _narratedBeta;

  // Bumped whenever the camera is stopped, so an in-flight _startCamera can
  // tell it's been superseded and dispose what it created instead.
  int _cameraGeneration = 0;

  // True when the camera was torn down because the app was backgrounded,
  // so it should be restarted on resume.
  bool _suspended = false;

  // Debug builds only (the toggle is hidden otherwise).
  bool _showPoseDebug = false;
  PoseDebugSettings _debugSettings = const PoseDebugSettings();

  @override
  void initState() {
    super.initState();
    _problemSession = ProblemSession(
      frames: _poseService.latest,
      grabFrame: _frameGrabber.grabNext,
      profile: () => widget.profileController?.profile,
    )..addListener(_onProblemChanged);
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Stop listening to poses before the pose service (and its notifier)
    // goes away below.
    _problemSession
      ..removeListener(_onProblemChanged)
      ..dispose();
    _frameGrabber.dispose();
    // Only dispose a narrator this screen created.
    if (widget.narrator == null) {
      _narrator.dispose();
    } else {
      _narrator.stop();
    }
    // Stop the stream before closing the detector so no frame reaches it
    // after it's closed.
    _stopCamera().whenComplete(_poseService.dispose);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Release the camera while backgrounded; it's restarted on resume.
      // Only once it's starting or running — pausing mid permission request
      // (Android shows the dialog as its own activity) must not interrupt it.
      if (_status != _CameraStatus.starting && _status != _CameraStatus.ready) {
        return;
      }
      _suspended = true;
      _narrator.stop();
      _stopCamera();
      setState(() => _status = _CameraStatus.checking);
      return;
    }
    // Coming back from Settings after granting permission there shouldn't
    // leave the user stuck looking at the denied message.
    if (state == AppLifecycleState.resumed &&
        (_suspended || _status == _CameraStatus.permanentlyDenied)) {
      _suspended = false;
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    try {
      final status = await Permission.camera.status;
      if (!mounted) return;
      if (status.isGranted) {
        await _startCamera();
        return;
      }
      if (status.isPermanentlyDenied) {
        setState(() => _status = _CameraStatus.permanentlyDenied);
        return;
      }
      if (status.isRestricted) {
        setState(() => _status = _CameraStatus.restricted);
        return;
      }
      setState(() => _status = _CameraStatus.needsRationale);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _CameraStatus.error;
        _errorMessage = '$e';
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _status = _CameraStatus.requesting);
    try {
      final result = await Permission.camera.request();
      if (!mounted) return;
      if (result.isGranted) {
        await _startCamera();
      } else if (result.isPermanentlyDenied) {
        setState(() => _status = _CameraStatus.permanentlyDenied);
      } else if (result.isRestricted) {
        setState(() => _status = _CameraStatus.restricted);
      } else {
        setState(() => _status = _CameraStatus.needsRationale);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = _CameraStatus.error;
        _errorMessage = '$e';
      });
    }
  }

  /// Stops the image stream and releases the camera, if one is running.
  ///
  /// Clears [_controller] synchronously; callers that stay mounted must
  /// rebuild so the preview isn't left pointing at a disposed controller.
  Future<void> _stopCamera() async {
    _cameraGeneration++;
    // A wall snapshot requested from this camera will never arrive.
    _frameGrabber.cancel();
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (e) {
      debugPrint('Failed to stop image stream: $e');
    }
    try {
      await controller.dispose();
    } catch (e) {
      debugPrint('Failed to dispose camera: $e');
    }
  }

  Future<void> _startCamera() async {
    // The retry flow can land here with a camera still running.
    await _stopCamera();
    if (!mounted) return;
    // Don't let the last pose or its smoothing carry over into a new session.
    _poseService.reset();
    // The phone may have moved: rescan the wall.
    _problemSession.restart();
    final generation = _cameraGeneration;
    bool superseded() => !mounted || generation != _cameraGeneration;

    setState(() => _status = _CameraStatus.starting);
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (superseded()) return;
      if (cameras.isEmpty) {
        setState(() {
          _status = _CameraStatus.error;
          _errorMessage = 'No camera found on this device.';
        });
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final newController = controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: PoseService.imageFormatGroup,
      );
      await newController.initialize();
      if (superseded()) {
        await newController.dispose();
        return;
      }
      await newController.startImageStream((image) {
        final deviceOrientation = newController.value.deviceOrientation;
        _poseService.processCameraImage(
          image,
          camera: backCamera,
          deviceOrientation: deviceOrientation,
        );
        _frameGrabber.onCameraImage(
          image,
          camera: backCamera,
          deviceOrientation: deviceOrientation,
        );
      });
      if (superseded()) {
        await newController.stopImageStream();
        await newController.dispose();
        return;
      }
      setState(() {
        _controller = newController;
        _status = _CameraStatus.ready;
      });
    } catch (e) {
      // Don't leak a controller that failed partway through starting.
      if (controller != null && controller != _controller) {
        await controller.dispose();
      }
      if (superseded()) return;
      setState(() {
        _status = _CameraStatus.error;
        _errorMessage = '$e';
      });
    }
  }

  /// Reads a newly planned beta aloud, and stops talking when the problem
  /// is reset or lost.
  void _onProblemChanged() {
    final beta = _problemSession.beta;
    if (beta == null) {
      if (_narratedBeta != null) {
        _narratedBeta = null;
        _narrator.stop();
      }
      return;
    }
    if (identical(beta, _narratedBeta)) return;
    _narratedBeta = beta;
    _narrator.narrate(betaCues(beta));
  }

  void _replayBeta() {
    final beta = _problemSession.beta;
    if (beta != null) _narrator.narrate(betaCues(beta));
  }

  void _applyDebugSettings(PoseDebugSettings settings) {
    if (!mounted) return;
    if (settings.model != _poseService.model) {
      _poseService.setModel(settings.model);
    }
    _poseService
      ..alpha = settings.alpha
      ..handNudge = settings.handNudge;
    final tolerance = _problemSession.params.tolerance;
    if (settings.hueTolerance != tolerance.hueTolerance ||
        settings.minSaturation != tolerance.minSaturation) {
      _problemSession.params = SegmentationParams(
        tolerance: tolerance.copyWith(
          hueTolerance: settings.hueTolerance,
          minSaturation: settings.minSaturation,
        ),
      );
    }
    setState(() => _debugSettings = settings);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera'),
        actions: [
          if (kDebugMode)
            IconButton(
              icon: Icon(
                _showPoseDebug ? Icons.bug_report : Icons.bug_report_outlined,
              ),
              tooltip: _showPoseDebug ? 'Hide pose debug' : 'Show pose debug',
              onPressed: () => setState(() => _showPoseDebug = !_showPoseDebug),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Edit profile',
            onPressed: () => context.push('/edit-profile'),
          ),
        ],
      ),
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_status) {
      case _CameraStatus.checking:
      case _CameraStatus.requesting:
      case _CameraStatus.starting:
        return const Center(child: CircularProgressIndicator());
      case _CameraStatus.needsRationale:
        return _PermissionMessage(
          icon: Icons.camera_alt_outlined,
          title: 'Camera access needed',
          message:
              'mitbo watches the climbing wall through your camera to '
              'track your movement and call out beta live. Grant camera '
              'access to continue.',
          actionLabel: 'Allow camera access',
          onAction: _requestPermission,
        );
      case _CameraStatus.permanentlyDenied:
        return _PermissionMessage(
          icon: Icons.no_photography_outlined,
          title: 'Camera access is off',
          message:
              'Camera access was denied. Enable it for mitbo in your '
              'device Settings to use live tracking.',
          actionLabel: 'Open Settings',
          onAction: openAppSettings,
        );
      case _CameraStatus.restricted:
        return const _PermissionMessage(
          icon: Icons.block,
          title: 'Camera unavailable',
          message:
              'Camera access is restricted on this device (for example '
              'by parental controls) and cannot be enabled from here.',
        );
      case _CameraStatus.error:
        return _PermissionMessage(
          icon: Icons.error_outline,
          title: 'Camera error',
          message: _errorMessage ?? 'Something went wrong starting the camera.',
          actionLabel: 'Try again',
          onAction: _bootstrap,
        );
      case _CameraStatus.ready:
        final controller = _controller;
        if (controller == null || !controller.value.isInitialized) {
          return const Center(child: CircularProgressIndicator());
        }
        return Stack(
          children: [
            // CameraPreview sizes itself to the preview's aspect ratio for
            // the current orientation; the overlay is its child so it covers
            // exactly the same area.
            Center(
              child: CameraPreview(
                controller,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    HoldOverlay(session: _problemSession),
                    PoseOverlay(
                      frames: _poseService.latest,
                      showKeypoints:
                          kDebugMode &&
                          _showPoseDebug &&
                          _debugSettings.showKeypoints,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Center(
                child: ListenableBuilder(
                  listenable: Listenable.merge([_problemSession, _narrator]),
                  builder: (context, _) => ProblemStatusPill(
                    phase: _problemSession.phase,
                    problem: _problemSession.problem,
                    beta: _problemSession.beta,
                    failureReason: _problemSession.failureReason,
                    speaking: _narrator.speaking,
                    onReset: _problemSession.resetProblem,
                    onReplay: _replayBeta,
                    onStopSpeaking: _narrator.stop,
                  ),
                ),
              ),
            ),
            // kDebugMode first so release builds compile the chip out.
            if (kDebugMode && _showPoseDebug)
              Positioned(
                left: 12,
                top: 12,
                child: PoseDebugChip(
                  frames: _poseService.latest,
                  modelName: _poseService.model.name,
                  onTap: () => showPoseDebugSheet(
                    context,
                    settings: _debugSettings,
                    onChanged: _applyDebugSettings,
                  ),
                ),
              ),
            if (kDebugMode && _showPoseDebug)
              Positioned(
                right: 12,
                top: 12,
                child: ProblemDebugPanel(
                  session: _problemSession,
                  refresh: _poseService.latest,
                  showReference: _debugSettings.showWallReference,
                ),
              ),
          ],
        );
    }
  }
}

class _PermissionMessage extends StatelessWidget {
  const _PermissionMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}
