import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

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

/// Shows a live back-camera preview once camera permission is granted.
///
/// No pose tracking, overlays, or recording here — just a stable preview.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  _CameraStatus _status = _CameraStatus.checking;
  CameraController? _controller;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from Settings after granting permission there shouldn't
    // leave the user stuck looking at the denied message.
    if (state == AppLifecycleState.resumed && _status == _CameraStatus.permanentlyDenied) {
      _bootstrap();
    }
  }

  Future<void> _bootstrap() async {
    final status = await Permission.camera.status;
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
  }

  Future<void> _requestPermission() async {
    setState(() => _status = _CameraStatus.requesting);
    final result = await Permission.camera.request();
    if (result.isGranted) {
      await _startCamera();
    } else if (result.isPermanentlyDenied) {
      setState(() => _status = _CameraStatus.permanentlyDenied);
    } else if (result.isRestricted) {
      setState(() => _status = _CameraStatus.restricted);
    } else {
      setState(() => _status = _CameraStatus.needsRationale);
    }
  }

  Future<void> _startCamera() async {
    setState(() => _status = _CameraStatus.starting);
    try {
      final cameras = await availableCameras();
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
      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _status = _CameraStatus.ready;
      });
    } catch (e) {
      setState(() {
        _status = _CameraStatus.error;
        _errorMessage = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Camera')),
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
          message: 'mitbo watches the climbing wall through your camera to '
              'track your movement and call out beta live. Grant camera '
              'access to continue.',
          actionLabel: 'Allow camera access',
          onAction: _requestPermission,
        );
      case _CameraStatus.permanentlyDenied:
        return _PermissionMessage(
          icon: Icons.no_photography_outlined,
          title: 'Camera access is off',
          message: 'Camera access was denied. Enable it for mitbo in your '
              'device Settings to use live tracking.',
          actionLabel: 'Open Settings',
          onAction: openAppSettings,
        );
      case _CameraStatus.restricted:
        return const _PermissionMessage(
          icon: Icons.block,
          title: 'Camera unavailable',
          message: 'Camera access is restricted on this device (for example '
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
        return Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: CameraPreview(controller),
          ),
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
