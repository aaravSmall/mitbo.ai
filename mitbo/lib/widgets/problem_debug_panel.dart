import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../state/problem_session.dart';
import '../vision/wall_frame.dart';

/// Debug-only readout of problem detection: phase, wall reference age,
/// sampled color, hold count and warnings, plus (optionally) the wall
/// reference snapshot itself.
class ProblemDebugPanel extends StatelessWidget {
  const ProblemDebugPanel({
    super.key,
    required this.session,
    this.refresh,
    this.showReference = false,
  });

  final ProblemSession session;

  /// Extra trigger to rebuild on (e.g. the pose stream), so the reference
  /// age and snapshot stay current between session changes.
  final Listenable? refresh;
  final bool showReference;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([session, ?refresh]),
      builder: (context, _) {
        final problem = session.problem;
        final age = session.referenceAge;
        final reference = session.reference;
        final lines = [
          'phase: ${session.phase.name}',
          'wall ref: ${age == null ? 'none' : '${(age.inMilliseconds / 1000).toStringAsFixed(1)} s old'}',
          if (problem != null) ...[
            '${problem.color}',
            '${problem.holds.length} holds, start ${problem.startHoldIndices}',
            ...problem.warnings,
          ],
          if (session.failureReason != null) session.failureReason!,
        ];
        return DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showReference && reference != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: WallFrameThumbnail(frame: reference, width: 120),
                  ),
                for (final line in lines)
                  Text(
                    line,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shows a [WallFrame] as an image [width] logical pixels wide.
class WallFrameThumbnail extends StatefulWidget {
  const WallFrameThumbnail({
    super.key,
    required this.frame,
    required this.width,
  });

  final WallFrame frame;
  final double width;

  @override
  State<WallFrameThumbnail> createState() => _WallFrameThumbnailState();
}

class _WallFrameThumbnailState extends State<WallFrameThumbnail> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(WallFrameThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.frame, widget.frame)) _decode();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  void _decode() {
    final frame = widget.frame;
    final pixels = frame.width * frame.height;
    final rgba = Uint8List(pixels * 4);
    for (var i = 0, p = 0, q = 0; i < pixels; i++, p += 3, q += 4) {
      rgba[q] = frame.rgb[p];
      rgba[q + 1] = frame.rgb[p + 1];
      rgba[q + 2] = frame.rgb[p + 2];
      rgba[q + 3] = 255;
    }
    ui.decodeImageFromPixels(
      rgba,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted || !identical(frame, widget.frame)) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final height = widget.width * frame.height / frame.width;
    final image = _image;
    if (image == null) {
      return SizedBox(width: widget.width, height: height);
    }
    return RawImage(image: image, width: widget.width, height: height);
  }
}
