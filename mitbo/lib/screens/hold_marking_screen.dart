import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../holds/hold.dart';
import '../holds/hold_conversion.dart';
import '../holds/hold_detector.dart';
import '../holds/hold_geometry.dart';
import '../holds/problem.dart';
import '../vision/hold_color.dart';
import '../vision/hold_segmenter.dart';
import '../vision/wall_frame.dart';
import '../widgets/pose_mapping.dart';

/// What the camera screen hands the hold marking screen.
class HoldMarkingArgs {
  const HoldMarkingArgs({
    required this.frame,
    required this.previewAspectRatio,
    this.initialProblem,
    this.segmentationParams = const SegmentationParams(),
  });

  /// The captured frame, upright (the same space pose keypoints use).
  final WallFrame frame;

  /// Width / height of the live preview, so the frozen frame is fitted
  /// exactly the way the preview was.
  final double previewAspectRatio;

  /// Holds to start from (e.g. the automatically detected ones, to fix
  /// up), if any.
  final Problem? initialProblem;

  /// Color thresholds for "Pick problem color" and the hold detection it
  /// runs — the automatic detector's current settings.
  final SegmentationParams segmentationParams;
}

/// Lets the user mark a problem's holds on a frozen camera frame.
///
/// Pops with the [Problem] on Done, or null on Cancel.
class HoldMarkingScreen extends StatefulWidget {
  const HoldMarkingScreen({super.key, required this.args, this.detector});

  final HoldMarkingArgs args;

  /// Finds more holds once a problem color is picked. Defaults to color
  /// segmentation with [HoldMarkingArgs.segmentationParams].
  final HoldDetector? detector;

  @override
  State<HoldMarkingScreen> createState() => _HoldMarkingScreenState();
}

enum _ResizeGesture { none, drag, pinch }

class _HoldMarkingScreenState extends State<HoldMarkingScreen> {
  static const _defaultRadius = 0.04;
  static const _minRadius = 0.01;
  static const _maxRadius = 0.25;

  late final WallFrame _frame = widget.args.frame;
  late final Size _frameSize = Size(
    _frame.width.toDouble(),
    _frame.height.toDouble(),
  );

  List<Hold> _holds = const [];
  Color? _problemColor;
  String? _selectedId;
  bool _pickingColor = false;
  bool _detecting = false;
  ui.Image? _image;
  int _nextId = 0;

  // Size of the frame area, captured during layout for gesture mapping.
  Size _canvasSize = Size.zero;

  _ResizeGesture _gesture = _ResizeGesture.none;
  double _gestureStartRadius = 0;
  Offset _gestureStartPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    final initial = widget.args.initialProblem;
    // Normalized holds carry over between frames from the same camera
    // position, as long as the aspect ratio matches.
    if (initial != null &&
        (initial.frameSize.aspectRatio - _frameSize.aspectRatio).abs() < 0.01) {
      _holds = initial.holds;
      _problemColor = initial.color;
    }
    ui.decodeImageFromPixels(
      _rgbaOf(_frame),
      _frame.width,
      _frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() => _image = image);
      },
    );
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  /// [frame]'s pixels with an opaque alpha channel added, for display.
  static Uint8List _rgbaOf(WallFrame frame) {
    final rgb = frame.rgb;
    final rgba = Uint8List(frame.width * frame.height * 4);
    for (var i = 0, o = 0; i < rgb.length; i += 3, o += 4) {
      rgba[o] = rgb[i];
      rgba[o + 1] = rgb[i + 1];
      rgba[o + 2] = rgb[i + 2];
      rgba[o + 3] = 255;
    }
    return rgba;
  }

  Hold? get _selected {
    for (final hold in _holds) {
      if (hold.id == _selectedId) return hold;
    }
    return null;
  }

  String _newId() =>
      'manual-${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';

  PreviewTransform get _transform =>
      PreviewTransform(uprightSize: _frameSize, previewSize: _canvasSize);

  Offset? _toNormalized(Offset local) => previewToNormalized(
    local,
    imageSize: _frameSize,
    rotation: InputImageRotation.rotation0deg,
    previewSize: _canvasSize,
  );

  void _replaceHold(Hold hold) {
    _holds = [for (final h in _holds) h.id == hold.id ? hold : h];
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _onTapUp(TapUpDetails details) {
    if (_detecting) return;
    final point = _toNormalized(details.localPosition);
    if (point == null) return;
    final hit = hitTestHolds(_holds, point, frameSize: _frameSize);

    if (_pickingColor) {
      if (hit == null) {
        _showMessage('Tap a hold to pick its color.');
      } else {
        _pickColor(hit);
      }
      return;
    }
    if (hit != null) {
      // Tapping the selected hold again deselects it.
      setState(() => _selectedId = hit.id == _selectedId ? null : hit.id);
      return;
    }
    final hold = Hold(
      id: _newId(),
      center: point,
      radius: _defaultRadius,
      source: HoldSource.manual,
    );
    setState(() {
      _holds = [..._holds, hold];
      _selectedId = hold.id;
    });
  }

  void _onScaleStart(ScaleStartDetails details) {
    final selected = _selected;
    _gesture = _ResizeGesture.none;
    if (selected == null || _pickingColor || _detecting) return;
    if (details.pointerCount > 1) {
      _gesture = _ResizeGesture.pinch;
    } else {
      // A one-finger drag resizes only if it starts on the selected hold.
      final point = _toNormalized(details.localFocalPoint);
      final onHold =
          point != null &&
          hitTestHolds([selected], point, frameSize: _frameSize, slop: 0.05) !=
              null;
      if (onHold) _gesture = _ResizeGesture.drag;
    }
    _gestureStartRadius = selected.radius;
    _gestureStartPoint = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final selected = _selected;
    if (selected == null || _gesture == _ResizeGesture.none) return;
    double radius;
    if (_gesture == _ResizeGesture.pinch) {
      radius = _gestureStartRadius * details.scale;
    } else {
      // Dragging away from the center grows the hold; toward it shrinks.
      final transform = _transform;
      final center = transform.toPreview(
        Offset(
          selected.center.dx * _frameSize.width,
          selected.center.dy * _frameSize.height,
        ),
      );
      final delta =
          (details.localFocalPoint - center).distance -
          (_gestureStartPoint - center).distance;
      radius =
          _gestureStartRadius +
          delta / (transform.scale * _frameSize.shortestSide);
    }
    _setRadius(selected, radius);
  }

  void _setRadius(Hold hold, double radius) {
    setState(
      () => _replaceHold(
        hold.copyWith(radius: radius.clamp(_minRadius, _maxRadius)),
      ),
    );
  }

  void _deleteSelected() {
    setState(() {
      _holds = [
        for (final h in _holds)
          if (h.id != _selectedId) h,
      ];
      _selectedId = null;
    });
  }

  Future<void> _pickColor(Hold hold) async {
    final holdColor = _readHoldColor(hold);
    if (holdColor == null) {
      _showMessage("Couldn't read a color there. Try a bigger circle.");
      return;
    }
    final color = colorFromHoldColor(holdColor);
    setState(() {
      _replaceHold(hold.copyWith(color: color));
      _problemColor = color;
      _pickingColor = false;
      _detecting = true;
    });

    List<Hold> found;
    try {
      final detector =
          widget.detector ??
          SegmentingHoldDetector(params: widget.args.segmentationParams);
      found = await detector.detect(_frame, targetColor: holdColor);
    } catch (e) {
      if (!mounted) return;
      setState(() => _detecting = false);
      _showMessage('Hold detection failed: $e');
      return;
    }
    if (!mounted) return;

    // Skip anything already marked: same id, or centered on an existing hold.
    final ids = {for (final h in _holds) h.id};
    final added = [
      for (final h in found)
        if (!ids.contains(h.id) &&
            hitTestHolds(_holds, h.center, frameSize: _frameSize, slop: 0) ==
                null)
          h,
    ];
    setState(() {
      _holds = [..._holds, ...added];
      _detecting = false;
    });
    _showMessage(
      added.isEmpty
          ? 'No other holds found for this color yet. Tap to add them by hand.'
          : 'Added ${added.length} ${added.length == 1 ? 'hold' : 'holds'}.',
    );
  }

  /// The hold color inside [hold]'s circle. The automatic detector's
  /// sampler weighs the dominant hue, which copes with wall showing around
  /// the hold; a plain average is the fallback.
  HoldColor? _readHoldColor(Hold hold) {
    final shortSide = _frameSize.shortestSide;
    final sampled = sampleHoldColor(
      _frame,
      hold.center.dx,
      hold.center.dy,
      radius: hold.radius * shortSide / _frameSize.width,
      tolerance: widget.args.segmentationParams.tolerance,
    );
    if (sampled != null) return sampled;
    final average = averageColorInCircle(_frame, hold.center, hold.radius);
    return average == null
        ? null
        : holdColorFromColor(
            average,
            tolerance: widget.args.segmentationParams.tolerance,
          );
  }

  void _done() {
    Navigator.of(
      context,
    ).pop(Problem(holds: _holds, color: _problemColor, frameSize: _frameSize));
  }

  String get _hint {
    if (_detecting) return 'Looking for holds of that color…';
    if (_pickingColor) return "Tap a hold in the problem's color.";
    if (_selected != null) {
      return 'Pinch, or drag from the hold, to resize. Tap it to deselect.';
    }
    if (_holds.isEmpty) return 'Tap a hold on the wall to mark it.';
    return 'Tap to add holds, or tap one to select it.';
  }

  @override
  Widget build(BuildContext context) {
    final count = _holds.length;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Mark holds'),
            Text(
              '$count ${count == 1 ? 'hold' : 'holds'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _detecting ? null : _done,
            child: const Text('Done'),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 4,
              child: _detecting ? const LinearProgressIndicator() : null,
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_hint, textAlign: TextAlign.center),
            ),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.args.previewAspectRatio,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      _canvasSize = constraints.biggest;
                      return GestureDetector(
                        key: const Key('hold-canvas'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: _onTapUp,
                        onScaleStart: _onScaleStart,
                        onScaleUpdate: _onScaleUpdate,
                        child: ClipRect(
                          child: CustomPaint(
                            painter: _FramePainter(_image, _frameSize),
                            foregroundPainter: _MarkedHoldsPainter(
                              holds: _holds,
                              frameSize: _frameSize,
                              color: _problemColor,
                              selectedId: _selectedId,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            _buildToolbar(),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    final selected = _selected;
    if (selected != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.radio_button_unchecked, size: 20),
            Expanded(
              child: Slider(
                value: selected.radius.clamp(_minRadius, _maxRadius),
                min: _minRadius,
                max: _maxRadius,
                onChanged: (value) => _setRadius(selected, value),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete hold',
              onPressed: _deleteSelected,
            ),
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Deselect hold',
              onPressed: () => setState(() => _selectedId = null),
            ),
          ],
        ),
      );
    }
    final color = _problemColor;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.tonalIcon(
            icon: const Icon(Icons.colorize),
            label: Text(
              _pickingColor ? 'Cancel color pick' : 'Pick problem color',
            ),
            onPressed: _holds.isEmpty || _detecting
                ? null
                : () => setState(() => _pickingColor = !_pickingColor),
          ),
          if (color != null) ...[
            const SizedBox(width: 12),
            Tooltip(
              message: 'Problem color',
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Draws the frozen frame fitted (cover) the same way the live preview is.
class _FramePainter extends CustomPainter {
  _FramePainter(this.image, this.frameSize);

  final ui.Image? image;
  final Size frameSize;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final image = this.image;
    if (image == null) return;
    final transform = PreviewTransform(
      uprightSize: frameSize,
      previewSize: size,
    );
    canvas.drawImageRect(
      image,
      Offset.zero & frameSize,
      transform.imageRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.frameSize != frameSize;
}

/// Paints the holds being marked, on a frame of [frameSize] (upright
/// pixels), using the same mapping as the pose and hold overlays.
class _MarkedHoldsPainter extends CustomPainter {
  _MarkedHoldsPainter({
    required this.holds,
    required this.frameSize,
    this.color,
    this.selectedId,
  });

  final List<Hold> holds;
  final Size frameSize;

  /// The problem color; holds are outlined in white until one is picked.
  final Color? color;

  /// Highlighted hold (on the marking screen).
  final String? selectedId;

  @override
  void paint(Canvas canvas, Size size) {
    if (holds.isEmpty || size.isEmpty) return;
    // Holds marked in one orientation don't match a preview in the other.
    if ((frameSize.width > frameSize.height) != (size.width > size.height)) {
      return;
    }
    final transform = PreviewTransform(
      uprightSize: frameSize,
      previewSize: size,
    );
    final shadow = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5;

    for (final hold in holds) {
      final center = normalizedToPreview(
        hold.center,
        imageSize: frameSize,
        rotation: InputImageRotation.rotation0deg,
        previewSize: size,
      );
      final radius = holdRadiusPixels(hold.radius, frameSize) * transform.scale;
      final selected = hold.id == selectedId;
      final outline = Paint()
        ..color = color ?? Colors.white
        ..style = PaintingStyle.stroke
        // Auto-detected holds are drawn lighter than ones the user marked.
        ..strokeWidth = hold.source == HoldSource.manual ? 2.5 : 1.5;

      if (selected) {
        canvas.drawCircle(
          center,
          radius,
          Paint()..color = (color ?? Colors.white).withValues(alpha: 0.25),
        );
        outline.strokeWidth = 3.5;
      }
      canvas.drawCircle(center, radius, shadow);
      canvas.drawCircle(center, radius, outline);
    }
  }

  @override
  bool shouldRepaint(_MarkedHoldsPainter oldDelegate) =>
      oldDelegate.holds != holds ||
      oldDelegate.frameSize != frameSize ||
      oldDelegate.color != color ||
      oldDelegate.selectedId != selectedId;
}
