import 'dart:math' as math;

import 'explorer.dart';

// Reduce a finger stroke to the same bounded polygon accepted by saved plans.
// Douglas–Peucker retains corners and concave boundaries; Zone rejects crossings.
Json drawnZone(String mode, List<List<double>> points) {
  if (points.length < 2) {
    throw const FormatException('Drag on the map to draw an area.');
  }
  if (mode == 'circle') {
    final radius = metres(points.first, points.last);
    if (radius < 100 || radius > 30000) {
      throw const FormatException(
        'Draw a circle between 100 m and 30 km across its radius. Zoom the map to adjust.',
      );
    }
    final data = <String, dynamic>{
      'type': 'circle',
      'center': points.first,
      'radius_m': radius.round(),
    };
    Zone(data);
    return data;
  }
  double distance(List<double> p, List<double> a, List<double> b) {
    final dx = b[0] - a[0], dy = b[1] - a[1];
    final length = dx * dx + dy * dy;
    final t = length == 0
        ? 0.0
        : (((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length).clamp(0.0, 1.0);
    return math.sqrt(
      math.pow(p[0] - a[0] - t * dx, 2) + math.pow(p[1] - a[1] - t * dy, 2),
    );
  }

  List<List<double>> simplify(List<List<double>> line, double tolerance) {
    var farthest = 0.0, index = 0;
    for (var i = 1; i < line.length - 1; i++) {
      final d = distance(line[i], line.first, line.last);
      if (d > farthest) {
        farthest = d;
        index = i;
      }
    }
    if (farthest <= tolerance) return [line.first, line.last];
    return [
      ...simplify(line.sublist(0, index + 1), tolerance)..removeLast(),
      ...simplify(line.sublist(index), tolerance),
    ];
  }

  final closed = [...points, points.first];
  var tolerance = .00002;
  var vertices = simplify(closed, tolerance)..removeLast();
  while (vertices.length > 20) {
    tolerance *= 1.5;
    vertices = simplify(closed, tolerance)..removeLast();
  }
  final data = <String, dynamic>{'type': 'polygon', 'vertices': vertices};
  try {
    Zone(data);
  } on FormatException {
    throw const FormatException(
      'Draw a larger closed outline without crossing over itself.',
    );
  }
  return data;
}
