import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/climber_keypoints.dart';
import '../services/pose_service.dart';

/// Small readout of pose detection rate and visible landmark count.
class PoseDebugChip extends StatefulWidget {
  const PoseDebugChip({
    super.key,
    required this.frames,
    required this.modelName,
    this.onTap,
  });

  final ValueListenable<PoseFrame?> frames;

  /// Pose model in use, shown first (e.g. "base").
  final String modelName;

  /// Opens the debug settings.
  final VoidCallback? onTap;

  @override
  State<PoseDebugChip> createState() => _PoseDebugChipState();
}

class _PoseDebugChipState extends State<PoseDebugChip> {
  // Completion times of detections in the last second.
  final _recent = <Duration>[];
  final _clock = Stopwatch()..start();

  // Ages out old detections even when no new ones arrive, so the rate
  // falls to 0 about a second after detection stops.
  late final Timer _pruneTimer;

  @override
  void initState() {
    super.initState();
    widget.frames.addListener(_onFrame);
    _pruneTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final before = _recent.length;
      _prune();
      if (_recent.length != before) setState(() {});
    });
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
    _pruneTimer.cancel();
    widget.frames.removeListener(_onFrame);
    super.dispose();
  }

  void _onFrame() {
    _recent.add(_clock.elapsed);
    _prune();
    setState(() {});
  }

  void _prune() {
    final now = _clock.elapsed;
    _recent.removeWhere((t) => now - t > const Duration(seconds: 1));
  }

  @override
  Widget build(BuildContext context) {
    final landmarks = widget.frames.value?.pose?.landmarks.values ?? const [];
    final visible = landmarks
        .where((l) => l.likelihood >= minLandmarkLikelihood)
        .length;
    return Material(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.modelName} · ${_recent.length} fps · '
                '$visible/${landmarks.length}',
                style: const TextStyle(color: Colors.white),
              ),
              if (widget.onTap != null) ...[
                const SizedBox(width: 6),
                const Icon(Icons.tune, size: 16, color: Colors.white),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
