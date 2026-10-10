import 'dart:math' as math;

import '../domain/models.dart';
import 'live_map_api.dart';

/// Synthetic devices only. This adapter has no Supabase client or GPS access.
class CampusSimulation extends LiveMapApi {
  CampusSimulation({required this.adminId, DateTime Function()? clock})
    : clock = clock ?? DateTime.now,
      super(null) {
    reset();
  }
  static const sessionId = 'cusat-local-test';
  static const center = {'latitude': 10.0448, 'longitude': 76.3260};
  // A UI test loop around the main campus, not a verified walking route.
  static const route = [
    {'latitude': 10.044361, 'longitude': 76.324421},
    {'latitude': 10.04418, 'longitude': 76.32518},
    {'latitude': 10.04392, 'longitude': 76.32606},
    {'latitude': 10.04412, 'longitude': 76.32695},
    {'latitude': 10.04512, 'longitude': 76.32755},
    {'latitude': 10.04614, 'longitude': 76.32712},
    {'latitude': 10.04652, 'longitude': 76.32612},
    {'latitude': 10.04585, 'longitude': 76.32518},
    {'latitude': 10.04520, 'longitude': 76.32465},
    {'latitude': 10.044361, 'longitude': 76.324421},
  ];
  final String adminId;
  final DateTime Function() clock;
  final runners = <String, Json>{};
  final distances = <String, double>{};
  final _fixes = <String, Json>{};
  bool running = true, ended = false, adminSharing = false;
  double speed = 1;
  int generation = 0;
  late DateTime expiresAt;
  Json? destination;
  @override
  bool get simulated => true;
  double get routeLength => _lengths.reduce((a, b) => a + b);
  static final _lengths = [
    for (var i = 1; i < route.length; i++)
      distanceMetres(route[i - 1], route[i]),
  ];

  void reset() {
    runners.clear();
    distances.clear();
    _fixes.clear();
    ended = false;
    running = true;
    adminSharing = false;
    speed = 1;
    generation++;
    expiresAt = clock().toUtc().add(const Duration(hours: 2));
    destination = {
      ...route.first,
      'name': 'Campus meetup',
      'set_by_user_id': adminId,
      'updated_at': clock().toUtc().toIso8601String(),
    };
    for (final (i, name) in ['Asha', 'Rahul', 'Meera'].indexed) {
      final id = 'sim-runner-$i';
      runners[id] = {
        'user_id': id,
        'display_name': '$name · test phone ${i + 1}',
        'role': 'member',
        'membership_status': 'joined',
        'sharing_status': 'sharing',
        'mode': 'running',
        'speed_mps': 2.4 + i * .35,
      };
      distances[id] = i * routeLength / 3;
    }
    tick(Duration.zero);
  }

  Json position(double distance) {
    var remaining = distance % routeLength;
    for (var i = 0; i < _lengths.length; i++) {
      if (remaining <= _lengths[i] || i == _lengths.length - 1) {
        final t = remaining / _lengths[i];
        final a = route[i], b = route[i + 1];
        return {
          'latitude': a['latitude']! + (b['latitude']! - a['latitude']!) * t,
          'longitude':
              a['longitude']! + (b['longitude']! - a['longitude']!) * t,
        };
      }
      remaining -= _lengths[i];
    }
    return {...route.first};
  }

  void setMode(String id, String mode) {
    if (!['running', 'paused', 'offline'].contains(mode) ||
        !runners.containsKey(id)) {
      throw const FormatException('Unknown simulated device state.');
    }
    runners[id]!['mode'] = mode;
    tick(Duration.zero);
  }

  void tick(Duration elapsed) {
    if (ended) return;
    final seconds = math.max(0, elapsed.inMicroseconds / 1000000);
    for (final entry in runners.entries) {
      final runner = entry.value;
      if (runner['membership_status'] != 'joined' ||
          runner['mode'] == 'offline') {
        continue;
      }
      if (running && runner['mode'] == 'running') {
        distances[entry.key] =
            distances[entry.key]! +
            seconds * speed * (runner['speed_mps'] as num);
      }
      _fixes[entry.key] = {
        ...position(distances[entry.key]!),
        'user_id': entry.key,
        'accuracy_m': 8,
        'received_at': clock().toUtc().toIso8601String(),
        'speed_mps': running && runner['mode'] == 'running'
            ? runner['speed_mps']
            : 0,
      };
    }
    if (adminSharing) {
      _fixes[adminId] = {
        ...route.first,
        'user_id': adminId,
        'accuracy_m': 5,
        'received_at': clock().toUtc().toIso8601String(),
      };
    }
  }

  Json get _session => {
    'id': sessionId,
    'name': 'CUSAT · campus test run',
    'created_by': adminId,
    'status': ended ? 'ended' : 'active',
    'expires_at': expiresAt.toIso8601String(),
    'membership_status': 'joined',
  };
  @override
  Future<Json> sessions() async => {
    'sessions': ended ? [] : [_session],
    'contacts': [],
  };
  @override
  Future<Json> snapshot(String id) async {
    if (id != sessionId || ended || !expiresAt.isAfter(clock())) {
      throw const FormatException('Test session ended. Reset to run again.');
    }
    return {
      'session': _session,
      'server_time': clock().toUtc().toIso8601String(),
      'members': [
        {
          'user_id': adminId,
          'display_name': 'You · admin (this phone)',
          'role': 'organizer',
          'membership_status': 'joined',
          'sharing_status': adminSharing ? 'sharing' : 'stopped',
          'generation': generation,
        },
        for (final runner in runners.values) {...runner},
      ],
      'locations': [
        for (final fix in _fixes.values)
          if (clock()
                  .difference(DateTime.parse(fix['received_at'] as String))
                  .inSeconds <
              30)
            {...fix},
      ],
      'destination': destination == null ? null : {...destination!},
    };
  }

  @override
  Future<Json> command(String action, Json data) async {
    if (data['session_id'] != sessionId || ended) {
      throw const FormatException('Test session unavailable.');
    }
    switch (action) {
      case 'consent':
        adminSharing = true;
        generation++;
        tick(Duration.zero);
      case 'stop':
      case 'pause':
        adminSharing = false;
        generation++;
        _fixes.remove(adminId);
      case 'remove':
      case 'revoke':
        final id = data['target_id'];
        if (id == adminId) {
          throw const FormatException('The admin stays on this phone.');
        }
        runners[id]?['membership_status'] = 'removed';
        _fixes.remove(id);
      case 'destination':
        final lat = data['latitude'] as num?, lon = data['longitude'] as num?;
        if (lat == null ||
            lon == null ||
            !lat.isFinite ||
            !lon.isFinite ||
            lat.abs() > 90 ||
            lon.abs() > 180) {
          throw const FormatException('Choose a valid map point.');
        }
        destination = {
          ...data,
          'set_by_user_id': adminId,
          'updated_at': clock().toUtc().toIso8601String(),
        };
      case 'end':
      case 'cancel':
        ended = true;
        running = false;
        adminSharing = false;
        _fixes.clear();
        destination = null;
      default:
        throw const FormatException(
          'Use Reset run to restore the simulated phones.',
        );
    }
    return {'session_id': sessionId, 'generation': generation};
  }

  @override
  Future<Json> publish(
    String id,
    int generation,
    int sequence,
    Json fix,
  ) async => throw const FormatException(
    'Real location publishing is disabled in this test.',
  );
}
