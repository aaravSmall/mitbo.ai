import 'dart:ui';

/// How a hold was marked.
enum HoldSource { auto, manual }

/// A climbing hold marked on a captured frame.
///
/// Coordinates are normalized to the upright frame, the same convention as
/// [ClimberKeypoints]: [center] is (0–1 across, 0–1 down). Because x and y
/// are normalized separately, [radius] is a fraction of the frame's
/// *shorter side*, so circles stay round whatever the aspect ratio.
class Hold {
  const Hold({
    required this.id,
    required this.center,
    required this.radius,
    required this.source,
    this.color,
  });

  factory Hold.fromJson(Map<String, Object?> json) {
    final center = json['center']! as Map<String, Object?>;
    final color = json['color'] as int?;
    return Hold(
      id: json['id']! as String,
      center: Offset(
        (center['x']! as num).toDouble(),
        (center['y']! as num).toDouble(),
      ),
      radius: (json['radius']! as num).toDouble(),
      source: HoldSource.values.byName(json['source']! as String),
      color: color == null ? null : Color(color),
    );
  }

  final String id;
  final Offset center;
  final double radius;
  final HoldSource source;

  /// Average color sampled inside the hold's circle, if it has been.
  final Color? color;

  Hold copyWith({
    Offset? center,
    double? radius,
    HoldSource? source,
    Color? color,
  }) => Hold(
    id: id,
    center: center ?? this.center,
    radius: radius ?? this.radius,
    source: source ?? this.source,
    color: color ?? this.color,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'center': {'x': center.dx, 'y': center.dy},
    'radius': radius,
    'source': source.name,
    if (color != null) 'color': color!.toARGB32(),
  };

  @override
  bool operator ==(Object other) =>
      other is Hold &&
      other.id == id &&
      other.center == center &&
      other.radius == radius &&
      other.source == source &&
      other.color?.toARGB32() == color?.toARGB32();

  @override
  int get hashCode =>
      Object.hash(id, center, radius, source, color?.toARGB32());

  @override
  String toString() =>
      'Hold($id, center: $center, radius: $radius, ${source.name}'
      '${color == null ? '' : ', color: 0x${color!.toARGB32().toRadixString(16)}'})';
}
