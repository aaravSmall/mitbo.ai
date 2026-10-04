import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/pose_service.dart';
import 'pose_overlay.dart';

/// Small readout of pose detection rate and visible landmark count.
class PoseDebugChip extends StatefulWidget {
  const PoseDebugChip({super.key, required this.frames});

  final ValueListenable<PoseFrame?> frames;

  @override
  State<PoseDebugChip> createState() => _PoseDebugChipState();
}

class _PoseDebugChipState extends State<PoseDebugChip> {
  // Completion times of detections in the last second.
  final _recent = <Duration>[];
  final _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    widget.frames.addListener(_onFrame);
  }

  @override
  void didUpdateWidget(PoseDebugChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frames != widget.frames) {
      oldWidget.frames.removeListener(_onFrame);
      widget.frames.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    widget.frames.removeListener(_onFrame);
    super.dispose();
  }

  void _onFrame() {
    final now = _clock.elapsed;
    _recent
      ..add(now)
      ..removeWhere((t) => now - t > const Duration(seconds: 1));
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final landmarks = widget.frames.value?.pose?.landmarks.values ?? const [];
    final visible = landmarks
        .where((l) => l.likelihood >= minLandmarkLikelihood)
        .length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          '${_recent.length} fps · $visible/${landmarks.length} landmarks',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}
