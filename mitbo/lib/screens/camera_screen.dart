import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/pose_service.dart';
import '../widgets/pose_debug_chip.dart';
import '../widgets/pose_overlay.dart';

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
/// runs pose tracking on the camera's image stream.
///
/// Draws the detected skeleton over the preview, with an optional debug
/// readout toggled from the app bar.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  _CameraStatus _status = _CameraStatus.checking;
  CameraController? _controller;
  String? _errorMessage;
  final PoseService _poseService = PoseService();

  // Bumped whenever the camera is stopped, so an in-flight _startCamera can
  // tell it's been superseded and dispose what it created instead.
  int _cameraGeneration = 0;

  // True when the camera was torn down because the app was backgrounded,
  // so it should be restarted on resume.
  bool _suspended = false;

  bool _showPoseDebug = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      await newController.startImageStream(
        (image) => _poseService.processCameraImage(
          image,
          camera: backCamera,
          deviceOrientation: newController.value.deviceOrientation,
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera'),
        actions: [
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
                child: PoseOverlay(frames: _poseService.latest),
              ),
            ),
            if (_showPoseDebug)
              Positioned(
                left: 12,
                top: 12,
                child: PoseDebugChip(frames: _poseService.latest),
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
