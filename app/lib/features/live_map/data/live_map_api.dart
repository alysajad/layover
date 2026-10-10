import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../companion/data/trip_store.dart';
import '../domain/models.dart';

// All requests are memory-only. No companion command, retry queue, or preferences.
class LiveMapApi {
  LiveMapApi(this.client);
  final SupabaseClient? client;
  bool get simulated => false;
  Future<Json> call(String name, [Json params = const {}]) async =>
      Map<String, dynamic>.from(
        await client!
                .rpc(name, params: params)
                .timeout(const Duration(seconds: 10))
            as Map,
      );
  Future<Json> sessions() => call('live_map_sessions');
  Future<Json> snapshot(String id) =>
      call('live_map_snapshot', {'p_session_id': id});
  Future<Json> command(String action, Json data) => call('live_map_command', {
    'p_action': action,
    'p_data': data,
    'p_request_id': const Uuid().v4(),
  });
  Future<Json> publish(String id, int generation, int sequence, Json fix) =>
      call('live_map_publish_location', {
        'p_session_id': id,
        'p_generation': generation,
        'p_sequence': sequence,
        for (final field in [
          'latitude',
          'longitude',
          'accuracy_m',
          'client_timestamp',
          'heading',
          'speed_mps',
        ])
          'p_$field': fix[field],
      });
}

// Synthetic coordinates only, isolated from the trip demo's persistent storage.
class DemoLiveMapApi extends LiveMapApi {
  DemoLiveMapApi(this.trip) : super(null);
  final TripStore trip;
  @override
  bool get simulated => true;
  final Map<String, Json> _sessions = {};
  final Map<String, List<Json>> _members = {};
  final Map<String, Json> _destinations = {};
  final Map<String, List<Json>> _locations = {};
  final Map<String, int> _generations = {};
  String get now => DateTime.now().toUtc().toIso8601String();
  @override
  Future<Json> sessions() async => {
    'sessions': _sessions.values
        .where((s) => ['created', 'active'].contains(s['status']))
        .map((s) => {...s, 'membership_status': 'joined'})
        .toList(),
    'contacts': trip.members
        .where((m) => m.active && m.id != trip.userId)
        .map((m) => m.data)
        .toList(),
  };
  @override
  Future<Json> snapshot(String id) async {
    final s = _sessions[id];
    if (s == null ||
        !['created', 'active'].contains(s['status']) ||
        DateTime.parse(s['expires_at'] as String).isBefore(DateTime.now())) {
      throw const FormatException('Session ended or expired.');
    }
    return {
      'server_time': now,
      'session': {...s},
      'members': _members[id]!.map((m) => {...m}).toList(),
      'locations': (_locations[id] ?? [])
          .map((l) => {...l, 'received_at': now})
          .toList(),
      'destination': _destinations[id],
    };
  }

  @override
  Future<Json> command(String action, Json data) async {
    final id = data['session_id'] as String? ?? const Uuid().v4();
    if (action == 'create') {
      _sessions[id] = {
        'id': id,
        'name': data['name'],
        'created_by': trip.userId,
        'linked_trip_id': data['linked_trip_id'],
        'status': 'created',
        'expires_at': DateTime.now()
            .toUtc()
            .add(Duration(hours: data['duration_hours'] as int? ?? 2))
            .toIso8601String(),
      };
      _members[id] = [
        {
          'user_id': trip.userId,
          'display_name': 'You (demo)',
          'role': 'organizer',
          'membership_status': 'joined',
          'sharing_status': 'stopped',
        },
      ];
    } else if (action == 'start') {
      _sessions[id]!['status'] = 'active';
    } else if (action == 'end' || action == 'cancel' || action == 'leave') {
      _sessions[id]!['status'] = 'ended';
      _locations.remove(id);
      _destinations.remove(id);
    } else if (action == 'invite') {
      final target = data['target_id'];
      if (!_members[id]!.any((m) => m['user_id'] == target)) {
        _members[id]!.add({
          'user_id': target,
          'display_name':
              trip.members.where((m) => m.id == target).firstOrNull?.name ??
              'Demo friend',
          'role': 'member',
          'membership_status': 'joined',
          'sharing_status': 'sharing',
        });
        (_locations[id] ??= []).add({
          'user_id': target,
          'latitude': 15.4989,
          'longitude': 73.8278,
          'accuracy_m': 20,
          'received_at': now,
        });
      }
    } else if (action == 'remove' || action == 'revoke') {
      _members[id]!.removeWhere((m) => m['user_id'] == data['target_id']);
      _locations[id]?.removeWhere((m) => m['user_id'] == data['target_id']);
    } else if (action == 'destination') {
      _destinations[id] = {
        ...data,
        'set_by_user_id': trip.userId,
        'updated_at': now,
      };
    } else if (['consent', 'stop', 'pause'].contains(action)) {
      final generation = (_generations[id] ?? 0) + 1;
      _generations[id] = generation;
      final me = _members[id]!.firstWhere((m) => m['user_id'] == trip.userId);
      me['sharing_status'] = action == 'consent'
          ? 'sharing'
          : action == 'pause'
          ? 'paused'
          : 'stopped';
      me['generation'] = generation;
      _locations[id]?.removeWhere((l) => l['user_id'] == trip.userId);
      if (action == 'consent') {
        (_locations[id] ??= []).add({
          'user_id': trip.userId,
          'latitude': 15.498,
          'longitude': 73.828,
          'accuracy_m': 12,
          'received_at': now,
        });
      }
      return {'session_id': id, 'generation': generation};
    }
    return {'session_id': id};
  }

  @override
  Future<Json> publish(
    String id,
    int generation,
    int sequence,
    Json fix,
  ) async => {'accepted': true};
}
