import 'dart:ui';

import 'hold.dart';

/// A boulder problem: the holds marked on one captured frame.
class Problem {
  Problem({required List<Hold> holds, this.color, required this.frameSize})
    : holds = List.unmodifiable(holds);

  factory Problem.fromJson(Map<String, Object?> json) {
    final version = json['version'];
    if (version != _jsonVersion) {
      throw FormatException('Unsupported problem version: $version');
    }
    final frame = json['frameSize']! as Map<String, Object?>;
    final color = json['color'] as int?;
    return Problem(
      holds: [
        for (final hold in json['holds']! as List<Object?>)
          Hold.fromJson(hold! as Map<String, Object?>),
      ],
      color: color == null ? null : Color(color),
      frameSize: Size(
        (frame['width']! as num).toDouble(),
        (frame['height']! as num).toDouble(),
      ),
    );
  }

  static const _jsonVersion = 1;

  final List<Hold> holds;

  /// The problem's hold color, once the user has picked it.
  final Color? color;

  /// Upright size, in pixels, of the frame the holds were marked on.
  final Size frameSize;

  Problem copyWith({List<Hold>? holds, Color? color}) => Problem(
    holds: holds ?? this.holds,
    color: color ?? this.color,
    frameSize: frameSize,
  );

  Map<String, Object?> toJson() => {
    'version': _jsonVersion,
    'holds': [for (final hold in holds) hold.toJson()],
    if (color != null) 'color': color!.toARGB32(),
    'frameSize': {'width': frameSize.width, 'height': frameSize.height},
  };

  @override
  bool operator ==(Object other) {
    if (other is! Problem ||
        other.frameSize != frameSize ||
        other.color?.toARGB32() != color?.toARGB32() ||
        other.holds.length != holds.length) {
      return false;
    }
    for (var i = 0; i < holds.length; i++) {
      if (other.holds[i] != holds[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(holds), color?.toARGB32(), frameSize);

  @override
  String toString() =>
      'Problem(${holds.length} holds, frame: $frameSize'
      '${color == null ? '' : ', color: 0x${color!.toARGB32().toRadixString(16)}'})';
}
