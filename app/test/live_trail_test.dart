import 'package:flutter_test/flutter_test.dart';
import 'package:layover/features/live_map/domain/map_features.dart';
import 'package:layover/features/live_map/domain/models.dart';

void main() {
  final now = DateTime.utc(2026, 10, 11, 12);
  Json point(int age, {String user = 'a', double accuracy = 10, double? lon}) =>
      {
        'user_id': user,
        'latitude': 15.0,
        'longitude': lon ?? 73 + age / 100000,
        'accuracy_m': accuracy,
        'received_at': now.subtract(Duration(seconds: age)).toIso8601String(),
      };
  test('trail shows only currently visible members and recent fixes', () {
    final result = trailFeatures(
      [point(1000), point(20), point(15), point(10, user: 'b')],
      [point(0)],
      now,
    );
    final features = rows(result['features']);
    expect(features, hasLength(1));
    expect(features.first['geometry']['coordinates'][0], hasLength(2));
    expect(trailFeatures([point(10), point(5)], [], now)['features'], isEmpty);
  });
  test('low accuracy, long gaps and implausible jumps break the trail', () {
    final trail = [
      point(120),
      point(115),
      point(110, accuracy: 235),
      point(105),
      point(100),
      point(50),
      point(45),
      point(40, lon: 80),
      point(35),
      point(30),
    ];
    final feature = rows(trailFeatures(trail, [point(0)], now)['features'])
        .single;
    expect(feature['geometry']['coordinates'], hasLength(4));
    for (final segment in feature['geometry']['coordinates']) {
      expect(segment, hasLength(2));
    }
  });
}
