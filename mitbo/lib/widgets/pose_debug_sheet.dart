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
    this.showWallReference = false,
    this.hueTolerance = 18,
    this.minSaturation = 0.25,
  });

  /// Draw the smoothed climber keypoints over the raw skeleton.
  final bool showKeypoints;
  final PoseDetectionModel model;

  /// Keypoint smoothing weight; see [KeypointSmoother.alpha].
  final double alpha;

  /// See [ClimberKeypoints.fromPose].
  final double handNudge;

  /// Show the clean wall snapshot holds are detected on.
  final bool showWallReference;

  /// Hold color matching; see [ColorTolerance].
  final double hueTolerance;
  final double minSaturation;

  PoseDebugSettings copyWith({
    bool? showKeypoints,
    PoseDetectionModel? model,
    double? alpha,
    double? handNudge,
    bool? showWallReference,
    double? hueTolerance,
    double? minSaturation,
  }) => PoseDebugSettings(
    showKeypoints: showKeypoints ?? this.showKeypoints,
    model: model ?? this.model,
    alpha: alpha ?? this.alpha,
    handNudge: handNudge ?? this.handNudge,
    showWallReference: showWallReference ?? this.showWallReference,
    hueTolerance: hueTolerance ?? this.hueTolerance,
    minSaturation: minSaturation ?? this.minSaturation,
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
        // Scrolls once the sheet is taller than the bottom sheet allows.
        child: SingleChildScrollView(
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
              const Divider(height: 24),
              Text('Holds', style: Theme.of(context).textTheme.titleSmall),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show wall reference'),
                value: _settings.showWallReference,
                onChanged: (value) =>
                    _update(_settings.copyWith(showWallReference: value)),
              ),
              Text(
                'Hue tolerance: ${_settings.hueTolerance.toStringAsFixed(0)}°',
              ),
              Slider(
                value: _settings.hueTolerance,
                min: 4,
                max: 40,
                divisions: 18,
                label: _settings.hueTolerance.toStringAsFixed(0),
                onChanged: (value) =>
                    _update(_settings.copyWith(hueTolerance: value)),
              ),
              Text(
                'Min saturation: ${_settings.minSaturation.toStringAsFixed(2)}',
              ),
              Slider(
                value: _settings.minSaturation,
                min: 0.05,
                max: 0.6,
                divisions: 11,
                label: _settings.minSaturation.toStringAsFixed(2),
                onChanged: (value) =>
                    _update(_settings.copyWith(minSaturation: value)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
