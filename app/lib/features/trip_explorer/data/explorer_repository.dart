import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../companion/data/trip_store.dart';
import '../domain/explorer.dart';

class ExplorerRepository {
  ExplorerRepository(this.trip, this.tripId)
    : userId = trip.userId,
      demo = trip.demo;
  final TripStore trip;
  final String tripId, userId;
  final bool demo;
  static final Expando<List<Json>> _memory = Expando<List<Json>>();
  final Map<String, (DateTime, Json)> _cache = {};
  bool _closed = false;
  void close() {
    _closed = true;
    _cache.clear();
  }

  bool get accessible =>
      !_closed &&
      trip.userId == userId &&
      trip.demo == demo &&
      trip.signedIn &&
      trip.snapshot.members(tripId).any((m) => m.id == userId && m.active);
  bool get editable =>
      accessible &&
      !trip.offline &&
      trip.snapshot.trips.any(
        (t) => t.id == tripId && t.organizer == userId && !t.archived,
      );
  void check({bool write = false}) {
    if (!accessible || (write && !editable)) {
      throw const FormatException('Trip organizer access is required to edit.');
    }
  }

  Future<Json> provider(Json input) async {
    check(write: true);
    final key = jsonEncode(input), cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.$1).inMinutes < 5) {
      return copyJson(cached.$2);
    }
    Json result;
    try {
      final response = await trip.client!.functions
          .invoke('trip-explorer', body: {...input, 'trip_id': tripId})
          .timeout(const Duration(seconds: 20));
      result = Map<String, dynamic>.from(response.data as Map);
      if (result['error'] != null) throw FormatException('${result['error']}');
    } on FunctionException catch (e) {
      throw FormatException(
        e.details is Map
            ? '${e.details['error'] ?? 'Provider unavailable'}'
            : 'Provider unavailable. Try again later.',
      );
    }
    check(write: true);
    if (_cache.length >= 60) _cache.remove(_cache.keys.first);
    _cache[key] = (DateTime.now(), copyJson(result));
    return result;
  }

  Future<List<Json>> discover(
    Zone zone,
    String category,
    String currency,
  ) async {
    check(write: true);
    final result = demo
        ? _demoPlaces(zone)
        : rows(
            (await provider({
              'action': 'places',
              'zone': zone.data,
              'category': category,
            }))['places'],
          );
    return result
        .where((p) => zone.contains(coordinate(p['point'])))
        .map(
          (p) => {
            ...p,
            'cost': costItem(
              'admission:${p['id']}',
              'admission',
              'Admission · ${p['name']}',
              currency,
              basis: 'per_person',
            ),
          },
        )
        .toList();
  }

  Future<List<Json>> routes(List<List<double>> points, String mode) async {
    check(write: true);
    if (demo) return [_demoRoute(points, mode)];
    final main = rows(
      (await provider({
        'action': 'route',
        'points': points,
        'mode': mode,
        'path_kind': 'balanced',
      }))['routes'],
    );
    // A second provider optimization is a path comparison, never an extra attraction.
    try {
      return [
        ...main,
        ...rows(
          (await provider({
            'action': 'route',
            'points': points,
            'mode': mode,
            'path_kind': 'short',
          }))['routes'],
        ),
      ];
    } catch (_) {
      check(write: true);
      return main.map((r) => {...r, 'alternative_unavailable': true}).toList();
    }
  }

  Future<List<Json>> versions() async {
    check();
    List<Json> result;
    if (demo) {
      if (trip.persistence) {
        final prefs = await SharedPreferences.getInstance();
        _memory[trip] = rows(
          jsonDecode(prefs.getString('layover.explorer.demo.v1') ?? '[]'),
        );
      }
      result = (_memory[trip] ?? [])
          .where(
            (p) =>
                p['trip_id'] == tripId &&
                (trip.snapshot.trips.any(
                      (t) => t.id == tripId && t.organizer == userId,
                    ) ||
                    p['status'] == 'shared'),
          )
          .map(copyJson)
          .toList();
    } else {
      result = rows(
        await trip.client!
            .from('exploration_plans')
            .select()
            .eq('trip_id', tripId)
            .order('created_at', ascending: false)
            .limit(100),
      );
    }
    check();
    result.sort(
      (a, b) =>
          (b['created_at'] as String).compareTo(a['created_at'] as String),
    );
    return result;
  }

  Future<void> _persistDemo() async {
    if (trip.persistence) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'layover.explorer.demo.v1',
        jsonEncode(_memory[trip] ?? []),
      );
    }
  }

  Future<Json> save(
    String id,
    String title,
    Json snapshot,
    String? parent,
  ) async {
    check(write: true);
    validateSettings(Map<String, dynamic>.from(snapshot['settings'] as Map));
    if (!demo) {
      final result = await trip.client!
          .rpc(
            'explorer_save',
            params: {
              'p_id': id,
              'p_trip_id': tripId,
              'p_parent_id': parent,
              'p_title': title,
              'p_snapshot': snapshot,
            },
          )
          .timeout(const Duration(seconds: 20));
      check(write: true);
      return Map<String, dynamic>.from(result as Map);
    }
    await versions();
    final all = _memory[trip] ??= [];
    final existing = all.where((p) => p['id'] == id).firstOrNull;
    if (existing != null) {
      if (jsonEncode(existing['snapshot']) != jsonEncode(snapshot) ||
          existing['title'] != title ||
          existing['parent_id'] != parent) {
        throw const FormatException(
          'Save identifier already used. Reload versions.',
        );
      }
      return copyJson(existing);
    }
    final previous = all
        .where((p) => p['id'] == parent && p['trip_id'] == tripId)
        .firstOrNull;
    if (parent != null && previous == null) {
      throw const FormatException('Parent version unavailable.');
    }
    final lineage = previous?['plan_id'] ?? id;
    final version =
        all
            .where((p) => p['plan_id'] == lineage)
            .fold<int>(
              0,
              (v, p) => v > (p['version'] as int) ? v : p['version'],
            ) +
        1;
    final result = <String, dynamic>{
      'id': id,
      'plan_id': lineage,
      'parent_id': parent,
      'trip_id': tripId,
      'created_by': userId,
      'title': title,
      'snapshot': copyJson(snapshot),
      'version': version,
      'status': rows(snapshot['itineraries']).isEmpty ? 'draft' : 'ready',
      'created_at': checkedNow(),
    };
    all.add(result);
    await _persistDemo();
    return copyJson(result);
  }

  Future<void> share(String id) async {
    check(write: true);
    if (!demo) {
      await trip.client!.rpc('explorer_share', params: {'p_id': id});
      check(write: true);
      return;
    }
    final item = (_memory[trip] ?? [])
        .where((p) => p['id'] == id && p['trip_id'] == tripId)
        .firstOrNull;
    if (item == null || item['status'] == 'draft') {
      throw const FormatException('Generate and save a plan first.');
    }
    item['status'] = 'shared';
    item['shared_at'] = checkedNow();
    await _persistDemo();
  }

  String newId() => const Uuid().v4();
  List<Json> _demoPlaces(Zone zone) {
    // Synthetic positions around the chosen center, never real-world place claims.
    final center = zone.circle ? zone.center : zone.vertices.first;
    final names = [
      'Demo heritage courtyard',
      'Demo coastal garden',
      'Demo local museum',
      'Demo market square',
    ];
    return List.generate(
      4,
      (i) => {
        'id': 'demo-place-$i',
        'provider': 'demo',
        'provider_place_id': 'demo-place-$i',
        'name': names[i],
        'category': ['culture', 'nature', 'culture', 'food'][i],
        'point': [center[0] + (i + 1) * 0.001, center[1] + (i % 2) * 0.002],
        'selection_type': 'excluded',
        'priority': 1,
        'dwell_minutes': 30,
        'source': 'Synthetic demo fixture',
        'source_checked_at': checkedNow(),
      },
    );
  }

  Json _demoRoute(List<List<double>> points, String mode) => {
    'provider': 'demo',
    'checked_at': checkedNow(),
    'path_kind': 'synthetic demo',
    'geometry': {'type': 'LineString', 'coordinates': points},
    'legs': List.generate(points.length - 1, (i) {
      final distance = metres(points[i], points[i + 1]) * 1.3;
      return {
        'leg_order': i,
        'origin': points[i],
        'destination': points[i + 1],
        'transport_mode': mode,
        'distance_m': distance,
        'duration_seconds':
            (distance /
                    (mode == 'walk'
                        ? 1.3
                        : mode == 'bicycle'
                        ? 4
                        : 8))
                .ceil(),
        'source': 'Synthetic demo fixture',
        'checked_at': checkedNow(),
      };
    }),
  };
}
