import 'dart:math' as math;

import '../../companion/domain/models.dart';
export '../../companion/domain/models.dart' show Json, rows;

class LiveSnapshot {
  LiveSnapshot(this.data);
  final Json data;
  Json get session => Map<String, dynamic>.from(data['session'] as Map);
  List<Json> get members => rows(data['members']);
  List<Json> get locations => rows(data['locations']);
  List<Json> get trails => rows(data['trails']);
  Json? get destination => data['destination'] == null
      ? null
      : Map<String, dynamic>.from(data['destination'] as Map);
  DateTime get serverTime => DateTime.parse(data['server_time'] as String);
  String name(String id) =>
      members.where((m) => m['user_id'] == id).firstOrNull?['display_name']
          as String? ??
      'Traveler';
}

double distanceMetres(Json a, Json b) {
  double radians(num v) => v * math.pi / 180;
  final lat1 = radians(a['latitude'] as num),
      lat2 = radians(b['latitude'] as num);
  final dlat = lat2 - lat1,
      dlon = radians((b['longitude'] as num) - (a['longitude'] as num));
  final h =
      math.pow(math.sin(dlat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dlon / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(h.clamp(0, 1)));
}

String freshness(Json location, DateTime serverTime) {
  final age = serverTime
      .difference(DateTime.parse(location['received_at'] as String))
      .inSeconds
      .clamp(0, 9999);
  return '${age >= 15 ? 'Stale' : 'Updated'} · ${age}s ago${(location['accuracy_m'] as num) > 100 ? ' · Approximate GPS' : ''}';
}
