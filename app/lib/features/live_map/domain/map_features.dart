import 'models.dart';

String travelerColor(String id) {
  const colors = ['#EC4963', '#4A8DAB', '#9A68AE', '#43836B'];
  return colors[id.codeUnits.fold<int>(0, (sum, c) => sum + c) % colors.length];
}

Json trailFeatures(List<Json> trail, List<Json> visible, DateTime now) {
  final features = <Json>[];
  for (final person in visible) {
    final points =
        trail
            .where(
              (p) =>
                  p['user_id'] == person['user_id'] &&
                  now.difference(DateTime.parse(p['received_at'])).inSeconds <
                      900,
            )
            .toList()
          ..sort(
            (a, b) =>
                DateTime.parse(a['received_at'])
                    .compareTo(DateTime.parse(b['received_at'])),
          );
    final segments = <List<List<num>>>[];
    var segment = <List<num>>[];
    Json? last;
    void flush() {
      if (segment.length > 1) segments.add(segment);
      segment = [];
      last = null;
    }

    for (final p in points) {
      if ((p['accuracy_m'] as num? ?? 5000) > 100) {
        flush();
        continue;
      }
      if (last != null) {
        final seconds =
            DateTime.parse(p['received_at'])
                .difference(DateTime.parse(last!['received_at']))
                .inMilliseconds /
            1000;
        if (seconds <= 0 ||
            seconds > 20 ||
            distanceMetres(last!, p) > seconds * 100 + 100) {
          flush();
        }
      }
      segment.add([p['longitude'] as num, p['latitude'] as num]);
      last = p;
    }
    flush();
    if (segments.isNotEmpty) {
      features.add({
        'type': 'Feature',
        'properties': {
          'user_id': person['user_id'],
          'color': travelerColor(person['user_id']),
        },
        'geometry': {'type': 'MultiLineString', 'coordinates': segments},
      });
    }
  }
  return {'type': 'FeatureCollection', 'features': features};
}
