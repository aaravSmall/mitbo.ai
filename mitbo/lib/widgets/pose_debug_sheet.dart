import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// Live-tunable pose tracking options, for debug builds only.
@immutable
class PoseDebugSettings {
  const PoseDebugSettings({
    this.showKeypoints = false,
    this.model = PoseDetectionModel.base,
    this.alpha = 0.5,
    this.handNudge = 0.5,
  });

  /// Draw the smoothed climber keypoints over the raw skeleton.
  final bool showKeypoints;
  final PoseDetectionModel model;

  /// Keypoint smoothing weight; see [KeypointSmoother.alpha].
  final double alpha;

  /// See [ClimberKeypoints.fromPose].
  final double handNudge;

  PoseDebugSettings copyWith({
    bool? showKeypoints,
    PoseDetectionModel? model,
    double? alpha,
    double? handNudge,
  }) => PoseDebugSettings(
    showKeypoints: showKeypoints ?? this.showKeypoints,
    model: model ?? this.model,
    alpha: alpha ?? this.alpha,
    handNudge: handNudge ?? this.handNudge,
  );
}

/// Opens the debug sheet. [onChanged] fires on every change, so the camera
/// view (left visible behind a light barrier) updates live.
Future<void> showPoseDebugSheet(
  BuildContext context, {
  required PoseDebugSettings settings,
  required ValueChanged<PoseDebugSettings> onChanged,
}) => showModalBottomSheet<void>(
  context: context,
  barrierColor: Colors.black12,
  builder: (context) => PoseDebugSheet(initial: settings, onChanged: onChanged),
);

class PoseDebugSheet extends StatefulWidget {
  const PoseDebugSheet({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final PoseDebugSettings initial;
  final ValueChanged<PoseDebugSettings> onChanged;

  @override
  State<PoseDebugSheet> createState() => _PoseDebugSheetState();
}

class _PoseDebugSheetState extends State<PoseDebugSheet> {
  late PoseDebugSettings _settings = widget.initial;

  void _update(PoseDebugSettings settings) {
    setState(() => _settings = settings);
    widget.onChanged(settings);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show smoothed keypoints'),
              value: _settings.showKeypoints,
              onChanged: (value) =>
                  _update(_settings.copyWith(showKeypoints: value)),
            ),
            const SizedBox(height: 8),
            SegmentedButton<PoseDetectionModel>(
              segments: const [
                ButtonSegment(
                  value: PoseDetectionModel.base,
                  label: Text('Base'),
                ),
                ButtonSegment(
                  value: PoseDetectionModel.accurate,
                  label: Text('Accurate'),
                ),
              ],
              selected: {_settings.model},
              onSelectionChanged: (selection) =>
                  _update(_settings.copyWith(model: selection.single)),
            ),
            const SizedBox(height: 16),
            Text('Smoothing alpha: ${_settings.alpha.toStringAsFixed(2)}'),
            Slider(
              value: _settings.alpha,
              min: 0.05,
              max: 1,
              divisions: 19,
              label: _settings.alpha.toStringAsFixed(2),
              onChanged: (value) => _update(_settings.copyWith(alpha: value)),
            ),
            Text('Hand nudge: ${_settings.handNudge.toStringAsFixed(2)}'),
            Slider(
              value: _settings.handNudge,
              divisions: 20,
              label: _settings.handNudge.toStringAsFixed(2),
              onChanged: (value) =>
                  _update(_settings.copyWith(handNudge: value)),
            ),
          ],
        ),
      ),
    );
  }
}
